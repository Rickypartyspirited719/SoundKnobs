import CoreAudio
import Foundation

/// One process that Core Audio knows about and that is currently producing output.
struct AudioProcessInfo: Hashable {
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
}

/// Watches Core Audio's process list and publishes the set of processes
/// that are actively playing sound right now.
final class AudioProcessMonitor: ObservableObject {

    @Published private(set) var playing: [AudioProcessInfo] = []

    private let listenerQueue = DispatchQueue(label: "soundknobs.monitor")
    private var observedProcesses = Set<AudioObjectID>()
    private var pendingRefresh: DispatchWorkItem?

    private lazy var changeListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        self?.scheduleRefresh()
    }

    init() {
        installProcessListListener()
        refresh()
    }

    /// Every process object Core Audio currently tracks (playing or not).
    func allProcessObjectIDs() -> [AudioObjectID] {
        (try? readObjectIDList(.system, kAudioHardwarePropertyProcessObjectList)) ?? []
    }

    func refresh() {
        let ids = allProcessObjectIDs()
        var result: [AudioProcessInfo] = []

        for id in ids {
            observeIsRunningOutput(id)

            let isRunning = (try? readPOD(id, kAudioProcessPropertyIsRunningOutput, UInt32(0))) ?? 0
            guard isRunning != 0 else { continue }

            let pid = (try? readPOD(id, kAudioProcessPropertyPID, pid_t(0))) ?? -1
            let bundleID = (try? readString(id, kAudioProcessPropertyBundleID)) ?? ""

            // Never list ourselves — tapping our own output would mute the
            // audio we're re-rendering for every other app.
            if pid == pid_t(ProcessInfo.processInfo.processIdentifier) { continue }
            if !bundleID.isEmpty, bundleID == Bundle.main.bundleIdentifier { continue }

            result.append(AudioProcessInfo(objectID: id, pid: pid, bundleID: bundleID))
        }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.playing != result { self.playing = result }
        }
    }

    // MARK: - Listeners

    private func installProcessListListener() {
        var address = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(.system, &address, listenerQueue, changeListener)
    }

    private func observeIsRunningOutput(_ processObjectID: AudioObjectID) {
        guard !observedProcesses.contains(processObjectID) else { return }
        observedProcesses.insert(processObjectID)
        var address = propertyAddress(kAudioProcessPropertyIsRunningOutput)
        AudioObjectAddPropertyListenerBlock(processObjectID, &address, listenerQueue, changeListener)
    }

    /// Coalesce bursts of property notifications into one refresh.
    private func scheduleRefresh() {
        pendingRefresh?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        pendingRefresh = work
        listenerQueue.asyncAfter(deadline: .now() + 0.15, execute: work)
    }
}