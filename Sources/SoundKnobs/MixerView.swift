import AppKit
import SwiftUI

struct MixerView: View {
    @ObservedObject var mixer: Mixer

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("NOW PLAYING")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)

            if mixer.apps.isEmpty {
                HStack {
                    Spacer()
                    Text("Nothing is playing audio")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.vertical, 22)
            } else {
                ForEach(mixer.apps) { app in
                    AppVolumeRow(app: app, mixer: mixer)
                        .padding(.horizontal, 14)
                }
                .padding(.bottom, 2)
            }

            if let error = mixer.lastError {
                VStack(alignment: .leading, spacing: 4) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Open Privacy Settings") { openPrivacySettings() }
                        .font(.caption)
                }
                .padding(.horizontal, 14)
                .padding(.top, 4)
            }

            Divider()
                .padding(.top, 6)

            Button {
                mixer.shutdown()
                NSApp.terminate(nil)
            } label: {
                Text("Quit SoundKnobs")
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut("q")
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
        }
        .frame(width: 300)
        .onAppear { mixer.monitor.refresh() }
    }

    private func openPrivacySettings() {
        let url = URL(
            string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture"
        )!
        NSWorkspace.shared.open(url)
    }
}

struct AppVolumeRow: View {
    let app: MixerApp
    @ObservedObject var mixer: Mixer

    private var volumeBinding: Binding<Float> {
        Binding(
            get: { mixer.volume(for: app) },
            set: { mixer.setVolume($0, for: app) }
        )
    }

    var body: some View {
        VStack(spacing: 3) {
            HStack(spacing: 7) {
                Group {
                    if let icon = app.icon {
                        Image(nsImage: icon).resizable()
                    } else {
                        Image(systemName: "app.fill").resizable().foregroundStyle(.secondary)
                    }
                }
                .frame(width: 18, height: 18)

                Text(app.name)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer(minLength: 8)

                Text("\(Int(round(displayedVolume * 100)))%")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 7) {
                Button { mixer.toggleMute(app) } label: {
                    Image(
                        systemName: mixer.isMuted(app)
                            ? "speaker.slash.fill" : "speaker.wave.2.fill"
                    )
                    .frame(width: 16)
                }
                .buttonStyle(.plain)
                .foregroundStyle(mixer.isMuted(app) ? .orange : .secondary)
                .help(mixer.isMuted(app) ? "Unmute" : "Mute")

                Slider(value: volumeBinding, in: 0...1)
                    .controlSize(.small)
                    .disabled(mixer.isMuted(app))
            }
        }
        .padding(.vertical, 5)
    }

    private var displayedVolume: Float {
        mixer.isMuted(app) ? 0 : mixer.volume(for: app)
    }
}
