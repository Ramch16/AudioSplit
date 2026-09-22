import Foundation

/// A Core Audio process object identifier, in a form the reconciler can use
/// without importing Core Audio. Matches `AudioObjectID`.
public typealias ProcessObjectID = UInt32

/// One app's desired destination. This is declarative state: a route exists
/// because the user asked for it, not because the app is running.
///
/// Keyed by bundle ID, never by PID. PIDs are runtime-only and must never reach
/// disk — the whole point is that a route survives the app quitting, relaunching
/// and getting a new PID, and survives a reboot.
public struct Route: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    /// The *resolved* bundle ID, as `ProcessIdentityResolver` reports it — the
    /// owning app, not the helper process that happens to emit the audio.
    public var appBundleID: String
    /// Cached for display when the app is not running and we cannot look it up.
    public var appDisplayName: String
    /// Destination device UID. Stable across reboots and reconnects, unlike the
    /// device's AudioObjectID.
    public var destinationDeviceUID: String
    public var isEnabled: Bool
    /// Linear gain applied to this route alone, 0...1.
    ///
    /// Per-route volume is only possible because each route gets its own tap.
    /// A tap mixes the processes it covers down to stereo, so two apps sharing a
    /// tap would be summed before we could touch either of them.
    public var volume: Float
    public var isMuted: Bool
    /// Extra delay for this route, in milliseconds, 0...500.
    ///
    /// Capturing and re-rendering audio costs latency, so a routed app can drift
    /// out of sync with its own video. This only ever adds delay — it cannot pull
    /// audio earlier — so it corrects audio that is *ahead* of picture.
    public var delayMilliseconds: Double

    public static let maximumVolume: Float = 1

    public init(
        id: UUID = UUID(),
        appBundleID: String,
        appDisplayName: String,
        destinationDeviceUID: String,
        isEnabled: Bool = true,
        volume: Float = 1,
        isMuted: Bool = false,
        delayMilliseconds: Double = 0
    ) {
        self.id = id
        self.appBundleID = appBundleID
        self.appDisplayName = appDisplayName
        self.destinationDeviceUID = destinationDeviceUID
        self.isEnabled = isEnabled
        self.volume = volume
        self.isMuted = isMuted
        self.delayMilliseconds = delayMilliseconds
    }

    /// Gain actually handed to the IOProc.
    public var effectiveGain: Float {
        isMuted ? 0 : min(max(volume, 0), Self.maximumVolume)
    }

    // Older files predate volume and mute; default them rather than failing to
    // load and silently losing the user's routes.
    private enum CodingKeys: String, CodingKey {
        case id, appBundleID, appDisplayName, destinationDeviceUID, isEnabled, volume, isMuted
        case delayMilliseconds
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        appBundleID = try container.decode(String.self, forKey: .appBundleID)
        appDisplayName = try container.decode(String.self, forKey: .appDisplayName)
        destinationDeviceUID = try container.decode(String.self, forKey: .destinationDeviceUID)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? true
        volume = try container.decodeIfPresent(Float.self, forKey: .volume) ?? 1
        isMuted = try container.decodeIfPresent(Bool.self, forKey: .isMuted) ?? false
        delayMilliseconds = try container
            .decodeIfPresent(Double.self, forKey: .delayMilliseconds) ?? 0
    }
}

/// Why a route is or is not currently moving audio.
public enum RouteStatus: Hashable, Codable, Sendable {
    /// Audio is being captured and sent to the destination.
    case active
    /// Configured and valid, but the app is not producing any audio processes.
    case waitingForApp
    /// Configured and valid, but the destination device is not connected.
    case waitingForDevice
    /// Another enabled route already claims this app; this one is ignored.
    case conflicting(withRouteID: Route.ID)
    /// Turned off by the user.
    case disabled

    /// Whether the route should be contributing to a live aggregate.
    public var isActive: Bool { self == .active }

    public var summary: String {
        switch self {
        case .active: "active"
        case .waitingForApp: "waiting for app"
        case .waitingForDevice: "waiting for device"
        case .conflicting: "conflicts with another route"
        case .disabled: "disabled"
        }
    }
}
