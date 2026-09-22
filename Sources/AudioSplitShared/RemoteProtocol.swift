import Foundation

// The contract between the Mac, which owns the audio hardware, and a phone or
// iPad acting as a remote control.
//
// Nothing here touches Core Audio, because nothing on iOS can. Routing happens
// entirely on the Mac; the remote sends intent and renders state. That split is
// not a compromise, it is forced: iOS has no HAL, no process taps and no
// aggregate devices, and the sandbox exists precisely to stop one app capturing
// another's audio.

/// A device as described to a remote. Flattened from the Mac's
/// `AudioDeviceInfo`, which cannot cross the wire because it is built on
/// Core Audio types.
public struct RemoteDevice: Identifiable, Codable, Hashable, Sendable {
    public var uid: String
    public var name: String
    public var transport: String
    public var canOutput: Bool
    public var canInput: Bool
    public var isDefaultOutput: Bool
    public var isDefaultInput: Bool
    /// Nil when the device exposes no software volume control of its own.
    public var volume: Float?
    public var isMuted: Bool
    public var canSetVolume: Bool
    public var canMute: Bool

    public var id: String { uid }

    public init(
        uid: String,
        name: String,
        transport: String,
        canOutput: Bool,
        canInput: Bool,
        isDefaultOutput: Bool,
        isDefaultInput: Bool,
        volume: Float?,
        isMuted: Bool,
        canSetVolume: Bool,
        canMute: Bool
    ) {
        self.uid = uid
        self.name = name
        self.transport = transport
        self.canOutput = canOutput
        self.canInput = canInput
        self.isDefaultOutput = isDefaultOutput
        self.isDefaultInput = isDefaultInput
        self.volume = volume
        self.isMuted = isMuted
        self.canSetVolume = canSetVolume
        self.canMute = canMute
    }
}

/// Everything a remote needs to draw the whole UI, sent whenever it changes.
///
/// Deliberately a whole snapshot rather than deltas: the state is small, and a
/// remote that reconnects after a dropout must not have to replay a history it
/// missed. The Mac is the single source of truth.
public struct RemoteSnapshot: Codable, Hashable, Sendable {
    /// Protocol version, so an old remote meeting a new Mac fails loudly rather
    /// than misinterpreting fields.
    public static let currentVersion = 1

    public var version: Int
    public var hostName: String
    public var routes: [Route]
    public var statuses: [UUID: RouteStatus]
    /// Peak level per route, 0...1. Sent frequently; everything else changes rarely.
    public var levels: [UUID: Float]
    public var devices: [RemoteDevice]
    public var audibleApps: [AudibleApp]
    public var preferences: Preferences
    /// Set when the Mac believes capture is failing, so the remote can say so
    /// instead of showing a silent meter with no explanation.
    public var captureLooksBroken: Bool

    public init(
        version: Int = RemoteSnapshot.currentVersion,
        hostName: String,
        routes: [Route],
        statuses: [UUID: RouteStatus],
        levels: [UUID: Float],
        devices: [RemoteDevice],
        audibleApps: [AudibleApp],
        preferences: Preferences,
        captureLooksBroken: Bool
    ) {
        self.version = version
        self.hostName = hostName
        self.routes = routes
        self.statuses = statuses
        self.levels = levels
        self.devices = devices
        self.audibleApps = audibleApps
        self.preferences = preferences
        self.captureLooksBroken = captureLooksBroken
    }
}

/// An instruction from a remote. Every case names an existing action on the
/// Mac's model, so the remote can never ask for something the local UI cannot.
public enum RemoteCommand: Codable, Hashable, Sendable {
    case addRoute(bundleID: String, displayName: String, destinationUID: String)
    case removeRoute(id: UUID)
    case setDestination(id: UUID, deviceUID: String)
    case setVolume(id: UUID, volume: Float)
    case setMuted(id: UUID, muted: Bool)
    case setDelay(id: UUID, milliseconds: Double)
    case setEnabled(id: UUID, enabled: Bool)
    case setDefaultOutput(deviceUID: String)
    case setDefaultInput(deviceUID: String)
    case setDeviceVolume(deviceUID: String, volume: Float)
    case setDeviceMuted(deviceUID: String, muted: Bool)
    case toggleInput
    /// Destroys every tap and aggregate the Mac owns. The one command that
    /// always works, even when everything else is wedged.
    case restoreAllAudio
}

/// Frames on the wire, in both directions.
public enum RemoteMessage: Codable, Hashable, Sendable {
    case snapshot(RemoteSnapshot)
    case command(RemoteCommand)
    /// Rejected command, with a reason the remote can show verbatim.
    case failure(String)

    public func encoded() throws -> Data {
        try JSONEncoder().encode(self)
    }

    public static func decode(_ data: Data) throws -> RemoteMessage {
        try JSONDecoder().decode(RemoteMessage.self, from: data)
    }
}

/// Bonjour service type the Mac advertises and remotes browse for.
public enum RemoteService {
    public static let bonjourType = "_audiosplit._tcp"
    public static let defaultPort: UInt16 = 51_637
}
