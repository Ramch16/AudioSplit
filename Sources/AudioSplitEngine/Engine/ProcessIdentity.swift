import AppKit
import Darwin
import Foundation

/// The user-facing app a Core Audio process object belongs to.
///
/// This matters because the process that actually emits audio is very often *not*
/// the app the user thinks of. Chromium-family browsers play through a helper
/// process; WebKit plays through an XPC service. Routes are keyed by the
/// resolved app's bundle ID, so getting this mapping right is load-bearing.
public struct AppIdentity: Sendable, Hashable {
    /// How the identity was worked out. Surfaced in diagnostics because the
    /// weaker sources are the ones that will misbehave in the field.
    public enum Source: String, Sendable {
        /// The process is itself a dock-visible application.
        case application
        /// macOS named a different process as responsible for this one.
        case responsibleProcess
        /// The HAL's own bundle ID matched a running application.
        case halBundleID
        /// The executable lives inside an enclosing .app (helper processes).
        case enclosingAppBundle
        /// A running application owns this PID directly.
        case runningApplication
        /// An ancestor process is a running application.
        case parentProcess
        /// Nothing resolved; we fell back to the raw HAL bundle ID or exec name.
        case unresolved
    }

    public let bundleID: String
    public let displayName: String
    public let bundleURL: URL?
    public let source: Source

    public init(bundleID: String, displayName: String, bundleURL: URL?, source: Source) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.bundleURL = bundleURL
        self.source = source
    }

    /// True when we could not tie the process to a real application bundle.
    public var isResolved: Bool { source != .unresolved }

    /// Whether this is something a user could sensibly route.
    ///
    /// Resolving is not enough. `com.apple.WebKit.GPU` registers as a running
    /// application in its own right, so the ladder "resolves" it — but it lives
    /// in a `.xpc` bundle and belongs to whichever app is responsible for it.
    /// Daemons like `avconferenced` are the same story. Offering either as a
    /// routable app produces a route that can never work, so the test is whether
    /// the identity actually points at an `.app`.
    public var isRoutable: Bool {
        guard isResolved, let bundleURL else { return false }
        return bundleURL.pathExtension == "app"
    }
}

/// Raw per-PID facts, kept separate from the resolved identity so diagnostics can
/// show what we saw before we made a judgement call.
public struct ProcessFacts: Sendable, Hashable {
    public let pid: pid_t
    public let executablePath: String?
    public let enclosingAppBundleURL: URL?
    public let runningApplicationBundleID: String?
    public let responsiblePID: pid_t?
    public let ancestors: [(pid_t, String)]

    public static func == (lhs: ProcessFacts, rhs: ProcessFacts) -> Bool {
        lhs.pid == rhs.pid
            && lhs.executablePath == rhs.executablePath
            && lhs.enclosingAppBundleURL == rhs.enclosingAppBundleURL
            && lhs.runningApplicationBundleID == rhs.runningApplicationBundleID
            && lhs.responsiblePID == rhs.responsiblePID
            && lhs.ancestors.map(\.0) == rhs.ancestors.map(\.0)
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(pid)
        hasher.combine(executablePath)
    }
}

@MainActor
public enum ProcessIdentityResolver {
    /// Longest ancestry we will walk before giving up.
    private static let maxAncestorDepth = 8

    public static func facts(for pid: pid_t) -> ProcessFacts {
        let path = executablePath(of: pid)
        return ProcessFacts(
            pid: pid,
            executablePath: path,
            enclosingAppBundleURL: path.flatMap(outermostAppBundle(inPathOf:)),
            runningApplicationBundleID: NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
            responsiblePID: ResponsibleProcess.responsiblePID(of: pid),
            ancestors: ancestry(of: pid)
        )
    }

    /// Resolve the app a given audio process should be routed as.
    ///
    /// Order matters. A helper process usually reports a bundle ID that *does*
    /// match a registered application (Brave Browser Helper, Claude Helper,
    /// "Safari Graphics and Media"), so trusting the HAL's bundle ID first would
    /// route every helper as its own app. We therefore work outside-in: who owns
    /// this process, not what does this process call itself.
    ///
    /// `halBundleID` is whatever `kAudioProcessPropertyBundleID` reported.
    public static func resolve(pid: pid_t, halBundleID: String?) -> AppIdentity {
        // 0. A dock-visible application speaks for itself. Checked first so an app
        //    launched from a terminal is not attributed to the terminal, which is
        //    what macOS's own responsibility chain would say.
        if let app = NSRunningApplication(processIdentifier: pid),
           app.activationPolicy == .regular,
           let bundleID = app.bundleIdentifier {
            return identity(for: app, bundleID: bundleID, source: .application)
        }

        let facts = facts(for: pid)

        // 1. macOS knows which app is responsible for a helper or XPC service.
        //    This is the only thing that can separate Safari's audio from another
        //    WebKit app's — both play through identical com.apple.WebKit.GPU
        //    processes parented to launchd.
        if let responsible = facts.responsiblePID,
           let identity = identityOfApplication(pid: responsible, source: .responsibleProcess) {
            return identity
        }

        // 2. The executable sits inside an app bundle. Take the *outermost* one so
        //    "Chrome.app/.../Chrome Helper.app" resolves to Chrome, not the helper.
        //    This is the fallback that keeps Chromium-family browsers working if
        //    responsibility lookup is unavailable.
        if let url = facts.enclosingAppBundleURL,
           let bundle = Bundle(url: url),
           let bundleID = bundle.bundleIdentifier {
            return AppIdentity(
                bundleID: bundleID,
                displayName: displayName(of: bundle, fallbackURL: url),
                bundleURL: url,
                source: .enclosingAppBundle
            )
        }

        // 3. The HAL's bundle ID names a running application.
        if let halBundleID, let app = runningApplication(withBundleID: halBundleID) {
            return identity(for: app, bundleID: halBundleID, source: .halBundleID)
        }

        // 4. The PID itself belongs to some running application (agent, accessory).
        if let app = NSRunningApplication(processIdentifier: pid),
           let bundleID = app.bundleIdentifier {
            return identity(for: app, bundleID: bundleID, source: .runningApplication)
        }

        // 5. Walk up the process tree. Rarely fires on modern macOS because XPC
        //    services are re-parented to launchd, but costs nothing.
        for (ancestorPID, _) in facts.ancestors {
            guard let app = NSRunningApplication(processIdentifier: ancestorPID),
                  let bundleID = app.bundleIdentifier,
                  app.activationPolicy != .prohibited
            else { continue }
            return identity(for: app, bundleID: bundleID, source: .parentProcess)
        }

        // 6. Give up, but keep something stable and human-readable. Daemons like
        //    coreaudiod's clients land here and are not routable.
        let fallbackID = halBundleID
            ?? facts.executablePath.map { URL(fileURLWithPath: $0).lastPathComponent }
            ?? "pid.\(pid)"
        return AppIdentity(
            bundleID: fallbackID,
            displayName: halBundleID ?? fallbackID,
            bundleURL: nil,
            source: .unresolved
        )
    }

    // MARK: - Pieces

    /// Identity of `pid` when it is a real application, by whatever route.
    private static func identityOfApplication(
        pid: pid_t,
        source: AppIdentity.Source
    ) -> AppIdentity? {
        if let app = NSRunningApplication(processIdentifier: pid),
           let bundleID = app.bundleIdentifier {
            return identity(for: app, bundleID: bundleID, source: source)
        }
        // Responsible processes are not always registered with NSWorkspace
        // (Safari lives in a cryptex, some agents never register). Read the
        // bundle off disk instead.
        guard let path = executablePath(of: pid),
              let url = outermostAppBundle(inPathOf: path),
              let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier
        else { return nil }
        return AppIdentity(
            bundleID: bundleID,
            displayName: displayName(of: bundle, fallbackURL: url),
            bundleURL: url,
            source: source
        )
    }

    private static func identity(
        for app: NSRunningApplication,
        bundleID: String,
        source: AppIdentity.Source
    ) -> AppIdentity {
        AppIdentity(
            bundleID: bundleID,
            displayName: app.localizedName ?? bundleID,
            bundleURL: app.bundleURL,
            source: source
        )
    }

    private static func displayName(of bundle: Bundle, fallbackURL: URL) -> String {
        let info = bundle.infoDictionary
        return (info?["CFBundleDisplayName"] as? String)
            ?? (info?["CFBundleName"] as? String)
            ?? fallbackURL.deletingPathExtension().lastPathComponent
    }

    private static func runningApplication(withBundleID bundleID: String) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
    }

    public static func executablePath(of pid: pid_t) -> String? {
        // PROC_PIDPATHINFO_MAXSIZE is a macro Swift cannot import; it is 4*MAXPATHLEN.
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer[0 ..< Int(length)], as: UTF8.self)
    }

    /// The outermost `.app` directory containing `path`, if any.
    public static func outermostAppBundle(inPathOf path: String) -> URL? {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        var accumulated = ""
        for component in components where !component.isEmpty {
            accumulated += "/" + component
            if component.hasSuffix(".app") {
                return URL(fileURLWithPath: accumulated)
            }
        }
        return nil
    }

    public static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { pointer in
            sysctl(pointer.baseAddress, UInt32(pointer.count), &info, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 && parent != pid ? parent : nil
    }

    /// Ancestor PIDs with their executable names, nearest first.
    public static func ancestry(of pid: pid_t) -> [(pid_t, String)] {
        var result: [(pid_t, String)] = []
        var current = pid
        for _ in 0 ..< maxAncestorDepth {
            guard let parent = parentPID(of: current), parent != 1 else { break }
            let name = executablePath(of: parent).map { URL(fileURLWithPath: $0).lastPathComponent }
                ?? "pid \(parent)"
            result.append((parent, name))
            current = parent
        }
        return result
    }
}
