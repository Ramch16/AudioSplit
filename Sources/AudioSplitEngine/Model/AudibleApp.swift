import Foundation

/// An app the user could route, as seen right now.
public struct AudibleApp: Identifiable, Hashable, Sendable {
    /// The routing key — the resolved owning app, not a helper process.
    public let bundleID: String
    public let displayName: String
    /// True when at least one of its processes is producing output this instant.
    public let isProducingOutput: Bool
    /// How many audio processes it owns. Usually more than one for browsers.
    public let processCount: Int
    /// Whether a route to this makes sense. False for XPC services and daemons
    /// that resolve to something other than an application bundle.
    public let isRoutable: Bool

    public var id: String { bundleID }
}

extension AudioProcessController {
    /// Apps that currently have audio processes, newest-relevant first.
    ///
    /// Grouped by resolved bundle ID, so a browser's helpers collapse into the
    /// browser. Apps that are merely alive are included alongside those actually
    /// making noise — the user routes Safari before pressing play, not after.
    public static func audibleApps(
        excludingBundleIDs excluded: Set<String> = [],
        excludingPrefixes prefixes: [String] = []
    ) throws -> [AudibleApp] {
        var namesByBundleID: [String: String] = [:]
        var producingOutput: Set<String> = []
        var counts: [String: Int] = [:]
        var routable: Set<String> = []

        for process in try allProcesses() {
            let identity = ProcessIdentityResolver.resolve(
                pid: process.pid,
                halBundleID: process.halBundleID
            )
            guard identity.isResolved,
                  !excluded.contains(identity.bundleID),
                  !prefixes.contains(where: identity.bundleID.hasPrefix)
            else { continue }

            namesByBundleID[identity.bundleID] = identity.displayName
            counts[identity.bundleID, default: 0] += 1
            if identity.isRoutable { routable.insert(identity.bundleID) }
            if process.isRunningOutput { producingOutput.insert(identity.bundleID) }
        }

        return namesByBundleID.map { bundleID, name in
            AudibleApp(
                bundleID: bundleID,
                displayName: name,
                isProducingOutput: producingOutput.contains(bundleID),
                processCount: counts[bundleID] ?? 0,
                isRoutable: routable.contains(bundleID)
            )
        }
        .sorted {
            // Apps making noise float to the top; then alphabetical.
            if $0.isProducingOutput != $1.isProducingOutput { return $0.isProducingOutput }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}
