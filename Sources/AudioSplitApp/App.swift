import AppKit
import AudioSplitEngine
import SwiftUI

@main
struct AudioSplitApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("AudioSplit", id: "main") {
            MainWindowView(model: model)
                .frame(minWidth: 700, minHeight: 460)
        }
        .defaultSize(width: 820, height: 560)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .appInfo) {
                Button("Restore All Audio") { model.restoreAllAudio() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            // Filled while audio is actually moving, so the menu bar itself
            // answers "is this doing anything right now?".
            Image(systemName: model.routes.contains(where: { model.level(for: $0) > 0 })
                ? "speaker.wave.2.fill"
                : "speaker.wave.2")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Tears routing down on quit, so quitting always restores normal audio.
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Closing the window leaves routing running and the menu bar item live.
        false
    }
}
