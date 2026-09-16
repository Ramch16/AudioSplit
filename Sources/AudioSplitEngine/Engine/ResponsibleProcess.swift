import Darwin
import Foundation

/// Maps a helper/XPC process to the application that is *responsible* for it.
///
/// This exists because of a hard fact discovered in the M1 spike: the process
/// that actually emits audio is frequently not the app the user sees.
///
///     pid  1190  com.apple.WebKit.GPU   -> responsible 1181  Safari
///     pid 19603  Brave Browser Helper   -> responsible 7859  Brave Browser
///     pid 76348  Claude Helper          -> responsible 76282 Claude
///
/// All WebKit media playback happens in `com.apple.WebKit.GPU`, one instance per
/// host app, all re-parented to launchd (ppid 1) and all reporting the same
/// bundle ID. Without responsibility information, "route Safari to the speakers"
/// is not expressible — every WebKit-based app collapses into one routing key.
///
/// `responsibility_get_pid_responsible_for_pid` is macOS SPI: it is exported by
/// libsystem but not declared in any public header. It is therefore resolved at
/// runtime with `dlsym` and never linked against, so its absence degrades the
/// app rather than breaking it. `ProcessIdentityResolver` has a complete
/// fallback path that works without it — see `AppIdentity.Source`.
///
/// This is the only SPI in AudioSplit. If it has to go, delete this file and the
/// `.responsibleProcess` case; nothing else changes.
public enum ResponsibleProcess {
    private typealias ResponsibleForPID = @convention(c) (pid_t) -> pid_t

    private static let symbol: ResponsibleForPID? = {
        guard let handle = dlopen(nil, RTLD_NOW) else { return nil }
        guard let pointer = dlsym(handle, "responsibility_get_pid_responsible_for_pid") else {
            return nil
        }
        return unsafeBitCast(pointer, to: ResponsibleForPID.self)
    }()

    /// Whether responsibility lookup is available on this system.
    public static var isAvailable: Bool { symbol != nil }

    /// The PID responsible for `pid`, or nil when it is responsible for itself,
    /// the lookup fails, or the SPI is unavailable.
    public static func responsiblePID(of pid: pid_t) -> pid_t? {
        guard let symbol else { return nil }
        let responsible = symbol(pid)
        guard responsible > 0, responsible != pid else { return nil }
        return responsible
    }
}
