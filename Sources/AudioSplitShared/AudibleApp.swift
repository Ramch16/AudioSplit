import Foundation

/// An app the user could route, as seen right now.
public struct AudibleApp: Identifiable, Hashable, Codable, Sendable {
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

    public init(
        bundleID: String,
        displayName: String,
        isProducingOutput: Bool,
        processCount: Int,
        isRoutable: Bool
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.isProducingOutput = isProducingOutput
        self.processCount = processCount
        self.isRoutable = isRoutable
    }
}
