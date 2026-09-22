import AppKit
import Foundation

/// Refuses to run a second copy of AudioSplit.
///
/// Two instances each hold their own taps with `muteBehavior = .mutedWhenTapped`.
/// When both tap the same app, its audio is pulled out of its original path
/// twice and neither instance can tell: each sees a healthy route, a live
/// aggregate and a running IOProc, while the user hears nothing or hears audio
/// arriving somewhere they did not ask for. There is no error anywhere in that
/// picture, which makes it close to undiagnosable from inside the app.
///
/// This happened during development — a leftover milestone harness held a tap on
/// Safari, and the main app's Safari route looked perfect while doing nothing.
@MainActor
enum SingleInstance {
    /// True when this process is the only AudioSplit running.
    ///
    /// Matches on bundle identifier rather than process name, so a copy launched
    /// from a build directory still counts as the same app.
    static func claim() -> Bool {
        guard let bundleID = Bundle.main.bundleIdentifier else { return true }
        let others = NSRunningApplication
            .runningApplications(withBundleIdentifier: bundleID)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        return others.isEmpty
    }

    /// Other AudioSplit-family processes that are running — the milestone
    /// harnesses, or a build from another directory.
    ///
    /// These have their own bundle IDs, so the single-instance check above does
    /// not catch them, and they are legitimate during development. But any of
    /// them can hold a `mutedWhenTapped` tap on an app this instance is also
    /// routing, producing exactly the silent-but-healthy-looking route that is
    /// impossible to diagnose from inside. Surfacing them by name turns a
    /// mystery into a one-line explanation.
    static func conflictingProcesses() -> [String] {
        let ownID = Bundle.main.bundleIdentifier ?? ""
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications
            .filter { app in
                guard let id = app.bundleIdentifier else { return false }
                return id.hasPrefix("com.audiosplit.")
                    && id != ownID
                    && app.processIdentifier != ownPID
            }
            .compactMap { $0.localizedName ?? $0.bundleIdentifier }
            .sorted()
    }

    /// Tell the user why we are quitting, and bring the copy they already have
    /// to the front so the app appears to respond rather than silently die.
    static func surrenderToExistingInstance() {
        // Logged as well as shown: this runs before the app is fully up, so if
        // the alert cannot be presented the reason is still recoverable.
        Diagnostics.log("another copy of AudioSplit is already running — quitting")

        if let bundleID = Bundle.main.bundleIdentifier,
           let existing = NSRunningApplication
               .runningApplications(withBundleIdentifier: bundleID)
               .first(where: {
                   $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
               }) {
            existing.activate()
        }

        let alert = NSAlert()
        alert.messageText = "AudioSplit is already running"
        alert.informativeText = """
        Only one copy can run at a time. Two copies would each capture the same \
        apps, and audio would go missing in ways neither copy could detect.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
        NSApplication.shared.terminate(nil)
    }
}
