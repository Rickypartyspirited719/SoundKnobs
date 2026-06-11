import AppKit
import Combine
import CoreAudio
import Foundation

/// One row in the mixer UI. May be backed by several audio processes
/// (e.g. multiple Chrome helper processes are grouped into one "Google Chrome").
struct MixerApp: Identifiable, Equatable {
    let id: String // normalized bundle identifier (group key)
    let name: String
    let icon: NSImage?
    var processObjectIDs: [AudioObjectID]

    static func == (lhs: MixerApp, rhs: MixerApp) -> Bool {
        lhs.id == rhs.id && lhs.processObjectIDs == rhs.processObjectIDs && lhs.name == rhs.name
    }
}

@MainActor
final class Mixer: ObservableObject {

    static let shared = Mixer()

    @Published private(set) var apps: [MixerApp] = []
    @Published private(set) var volumes: [String: Float] = [:] // group key -> 0...1
    @Published private(set) var muted: Set<String> = []
    @Published var lastError: String?

    let monitor = AudioProcessMonitor()

    private var taps: [AudioObjectID: ProcessTap] = [:]
    private var cancellables = Set<AnyCancellable>()

    private init() {
        monitor.$playing
            .receive(on: DispatchQueue.main)
            .sink { [weak self] infos in self?.rebuild(with: infos) }
            .store(in: &cancellables)

        installDefaultOutputListener()
    }

    // MARK: - Public API used by the UI

    func volume(for app: MixerApp) -> Float {
        volumes[app.id] ?? 1.0
    }

    func isMuted(_ app: MixerApp) -> Bool {
        muted.contains(app.id)
    }

    func setVolume(_ value: Float, for app: MixerApp) {
        volumes[app.id] = value
        if value > 0 { muted.remove(app.id) }
        applyGain(for: app)
    }

    func toggleMute(_ app: MixerApp) {
        if muted.contains(app.id) { muted.remove(app.id) } else { muted.insert(app.id) }
        applyGain(for: app)
    }

    func shutdown() {
        for tap in taps.values { tap.invalidate() }
        taps.removeAll()
    }

    // MARK: - Internals

    private func rebuild(with infos: [AudioProcessInfo]) {
        var groups: [String: MixerApp] = [:]

        for info in infos {
            let display = AppResolver.resolve(pid: info.pid, bundleID: info.bundleID)
            if var existing = groups[display.key] {
                existing.processObjectIDs.append(info.objectID)
                groups[display.key] = existing
            } else {
                groups[display.key] = MixerApp(
                    id: display.key,
                    name: display.name,
                    icon: display.icon,
                    processObjectIDs: [info.objectID]
                )
            }
        }

        apps = groups.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        // Drop taps whose process disappeared entirely.
        let alive = Set(monitor.allProcessObjectIDs())
        for (objectID, tap) in taps where !alive.contains(objectID) {
            tap.invalidate()
            taps[objectID] = nil
        }

        // If the user already adjusted a group, make sure newly appeared
        // member processes (e.g. a fresh browser tab process) get tapped too.
        for app in apps where volumes[app.id] != nil || muted.contains(app.id) {
            applyGain(for: app)
        }
    }

    private func effectiveGain(for app: MixerApp) -> Float {
        muted.contains(app.id) ? 0 : (volumes[app.id] ?? 1.0)
    }

    private func applyGain(for app: MixerApp) {
        let gain = effectiveGain(for: app)
        for objectID in app.processObjectIDs {
            do {
                let tap: ProcessTap
                if let existing = taps[objectID] {
                    tap = existing
                } else {
                    let created = ProcessTap(processObjectID: objectID, initialGain: gain)
                    try created.activate()
                    taps[objectID] = created
                    tap = created
                }
                tap.gain = gain
                lastError = nil
            } catch {
                lastError = "Couldn't take control of this app's audio. "
                    + "Grant SoundKnobs the \u{201C}System Audio Recording\u{201D} permission "
                    + "in System Settings \u{2192} Privacy & Security, then move the slider again."
            }
        }
    }

    /// If the user switches output device (headphones <-> speakers),
    /// rebuild active taps so audio follows the new default output.
    private func installDefaultOutputListener() {
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        AudioObjectAddPropertyListenerBlock(.system, &address, .main) { [weak self] _, _ in
            Task { @MainActor in self?.handleDefaultOutputChange() }
        }
    }

    private func handleDefaultOutputChange() {
        guard !taps.isEmpty else { return }
        for tap in taps.values { tap.invalidate() }
        taps.removeAll()
        for app in apps where volumes[app.id] != nil || muted.contains(app.id) {
            applyGain(for: app)
        }
    }
}

// MARK: - Process -> display app resolution

enum AppResolver {

    /// Maps an audio process (pid + bundle id) to a user-facing app:
    /// a stable group key, a display name, and an icon. Helper processes
    /// like "com.google.Chrome.helper" collapse into their parent app.
    static func resolve(pid: pid_t, bundleID: String) -> (key: String, name: String, icon: NSImage?) {
        let running = NSRunningApplication(processIdentifier: pid)
        let rawKey = running?.bundleIdentifier
            ?? (bundleID.isEmpty ? "pid.\(pid)" : bundleID)
        let key = normalized(rawKey)

        if key != rawKey,
            let parent = NSRunningApplication
                .runningApplications(withBundleIdentifier: key).first
        {
            return (key, parent.localizedName ?? key, parent.icon)
        }

        if let running {
            return (key, running.localizedName ?? key, running.icon)
        }

        let fallbackName = key.split(separator: ".").last.map(String.init) ?? "PID \(pid)"
        return (key, fallbackName, nil)
    }

    private static func normalized(_ bundleID: String) -> String {
        if let range = bundleID.range(of: ".helper", options: [.caseInsensitive]) {
            return String(bundleID[..<range.lowerBound])
        }
        return bundleID
    }
}
