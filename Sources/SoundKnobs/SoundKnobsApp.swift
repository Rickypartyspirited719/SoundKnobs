import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillTerminate(_ notification: Notification) {
        // Destroying the taps un-mutes every app we were controlling.
        Mixer.shared.shutdown()
    }
}

@main
struct SoundKnobsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var mixer = Mixer.shared

    var body: some Scene {
        MenuBarExtra("SoundKnobs", systemImage: "slider.horizontal.3") {
            MixerView(mixer: mixer)
        }
        .menuBarExtraStyle(.window)
    }
}
