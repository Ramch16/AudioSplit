import Foundation

/// A global hotkey, stored as the Carbon key code and modifier mask so it can be
/// registered without the app being frontmost and without Accessibility access.
public struct HotKeyBinding: Codable, Hashable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public var isEnabled: Bool

    public init(keyCode: UInt32, modifiers: UInt32, isEnabled: Bool = true) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.isEnabled = isEnabled
    }

    /// Control-Option-Command-I. Chosen because three modifiers plus a letter is
    /// very unlikely to collide with an app shortcut.
    public static let `default` = HotKeyBinding(
        keyCode: 34, // kVK_ANSI_I
        modifiers: 0x1000 | 0x0800 | 0x0100, // control | option | command
        isEnabled: false
    )

    public var displayString: String {
        var text = ""
        if modifiers & 0x1000 != 0 { text += "⌃" }
        if modifiers & 0x0800 != 0 { text += "⌥" }
        if modifiers & 0x0200 != 0 { text += "⇧" }
        if modifiers & 0x0100 != 0 { text += "⌘" }
        return text + "I"
    }
}

/// Settings that are not routes.
public struct Preferences: Codable, Hashable, Sendable {
    /// The two input devices the hotkey flips between, by UID.
    ///
    /// Stored as UIDs, like destinations, so a disconnected device is remembered
    /// rather than forgotten.
    public var inputToggleDeviceUIDs: [String]
    public var inputToggleHotKey: HotKeyBinding
    /// Whether this Mac accepts connections from the iPhone/iPad remote.
    /// Off by default — a listener that can re-route every app's audio is not
    /// something to switch on without the user asking for it.
    public var isRemoteEnabled: Bool
    /// The code a remote must present to complete the TLS handshake.
    public var pairingCode: String

    public init(
        inputToggleDeviceUIDs: [String] = [],
        inputToggleHotKey: HotKeyBinding = .default,
        isRemoteEnabled: Bool = false,
        pairingCode: String = ""
    ) {
        self.inputToggleDeviceUIDs = inputToggleDeviceUIDs
        self.inputToggleHotKey = inputToggleHotKey
        self.isRemoteEnabled = isRemoteEnabled
        self.pairingCode = pairingCode
    }

    // Files written before the remote existed decode with it switched off.
    private enum CodingKeys: String, CodingKey {
        case inputToggleDeviceUIDs, inputToggleHotKey, isRemoteEnabled, pairingCode
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        inputToggleDeviceUIDs = try container
            .decodeIfPresent([String].self, forKey: .inputToggleDeviceUIDs) ?? []
        inputToggleHotKey = try container
            .decodeIfPresent(HotKeyBinding.self, forKey: .inputToggleHotKey) ?? .default
        isRemoteEnabled = try container
            .decodeIfPresent(Bool.self, forKey: .isRemoteEnabled) ?? false
        pairingCode = try container
            .decodeIfPresent(String.self, forKey: .pairingCode) ?? ""
    }

    /// Whether the pair can actually be toggled between.
    ///
    /// Two slots holding the same device is a configuration that looks valid and
    /// silently does nothing, so it does not count as configured.
    public var hasValidTogglePair: Bool {
        inputToggleDeviceUIDs.count == 2
            && inputToggleDeviceUIDs[0] != inputToggleDeviceUIDs[1]
            && !inputToggleDeviceUIDs.contains(where: \.isEmpty)
    }

    /// Given the current default input, the device the hotkey should switch to.
    ///
    /// Anything other than the second device goes to the second device, so the
    /// hotkey still does something useful when the current input is neither of
    /// the configured pair.
    public func nextInputUID(currentUID: String?) -> String? {
        guard hasValidTogglePair else { return nil }
        return currentUID == inputToggleDeviceUIDs[1]
            ? inputToggleDeviceUIDs[0]
            : inputToggleDeviceUIDs[1]
    }
}
