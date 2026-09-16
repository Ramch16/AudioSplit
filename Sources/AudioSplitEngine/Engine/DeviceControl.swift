import CoreAudio
import Foundation

/// Reading and writing a device's own volume and mute, and the system's default
/// output and input.
///
/// This is ordinary system audio control — the same settings the Sound pane
/// exposes. It has nothing to do with taps or routing, and it works on devices
/// AudioSplit is not touching at all.
public extension DeviceStore {
    // MARK: - System defaults

    static func setDefaultOutputDevice(_ objectID: AudioObjectID) throws {
        try AudioObjects.setValue(
            AudioObjects.system,
            AudioObjects.address(kAudioHardwarePropertyDefaultOutputDevice),
            to: objectID,
            operation: "set default output device"
        )
    }

    static func setDefaultOutputDevice(uid: String) throws {
        guard let device = try device(withUID: uid), device.canOutput else {
            throw CoreAudioError(
                status: kAudioHardwareBadDeviceError,
                operation: "find output device \(uid)"
            )
        }
        try setDefaultOutputDevice(device.objectID)
    }

    // MARK: - Device volume

    /// A device's output volume, 0...1, or nil when the device has no volume
    /// control of its own.
    ///
    /// Devices vary: some expose a single main-element control, others only
    /// per-channel controls. Both are handled, because a device that only has
    /// per-channel volume would otherwise look like it has none.
    static func volume(
        of objectID: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
    ) -> Float? {
        let main = AudioObjects.address(
            kAudioDevicePropertyVolumeScalar,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        )
        if AudioObjects.hasProperty(objectID, main),
           let value = try? AudioObjects.value(
               objectID,
               main,
               default: Float(0),
               operation: "read device volume"
           ) {
            return value
        }

        let channels = volumeChannels(objectID, scope: scope)
        guard !channels.isEmpty else { return nil }
        let values = channels.compactMap { element -> Float? in
            try? AudioObjects.value(
                objectID,
                AudioObjects.address(
                    kAudioDevicePropertyVolumeScalar,
                    scope: scope,
                    element: element
                ),
                default: Float(0),
                operation: "read channel volume"
            )
        }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Float(values.count)
    }

    static func setVolume(
        _ volume: Float,
        of objectID: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
    ) throws {
        let clamped = min(max(volume, 0), 1)
        let main = AudioObjects.address(
            kAudioDevicePropertyVolumeScalar,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        )
        if AudioObjects.isSettable(objectID, main) {
            try AudioObjects.setValue(
                objectID,
                main,
                to: clamped,
                operation: "set device volume"
            )
            return
        }

        let channels = volumeChannels(objectID, scope: scope)
        guard !channels.isEmpty else {
            throw CoreAudioError(
                status: kAudioHardwareUnknownPropertyError,
                operation: "set volume on a device with no volume control"
            )
        }
        for element in channels {
            let address = AudioObjects.address(
                kAudioDevicePropertyVolumeScalar,
                scope: scope,
                element: element
            )
            guard AudioObjects.isSettable(objectID, address) else { continue }
            try AudioObjects.setValue(
                objectID,
                address,
                to: clamped,
                operation: "set channel volume"
            )
        }
    }

    static func canSetVolume(
        of objectID: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
    ) -> Bool {
        let main = AudioObjects.address(
            kAudioDevicePropertyVolumeScalar,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        )
        if AudioObjects.isSettable(objectID, main) { return true }
        return volumeChannels(objectID, scope: scope).contains { element in
            AudioObjects.isSettable(
                objectID,
                AudioObjects.address(
                    kAudioDevicePropertyVolumeScalar,
                    scope: scope,
                    element: element
                )
            )
        }
    }

    // MARK: - Device mute

    static func isMuted(
        of objectID: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
    ) -> Bool? {
        let address = AudioObjects.address(
            kAudioDevicePropertyMute,
            scope: scope,
            element: kAudioObjectPropertyElementMain
        )
        guard AudioObjects.hasProperty(objectID, address) else { return nil }
        return (try? AudioObjects.value(
            objectID,
            address,
            default: UInt32(0),
            operation: "read device mute"
        )).map { $0 != 0 }
    }

    static func setMuted(
        _ muted: Bool,
        of objectID: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
    ) throws {
        try AudioObjects.setValue(
            objectID,
            AudioObjects.address(
                kAudioDevicePropertyMute,
                scope: scope,
                element: kAudioObjectPropertyElementMain
            ),
            to: UInt32(muted ? 1 : 0),
            operation: "set device mute"
        )
    }

    static func canMute(
        of objectID: AudioObjectID,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeOutput
    ) -> Bool {
        AudioObjects.isSettable(
            objectID,
            AudioObjects.address(
                kAudioDevicePropertyMute,
                scope: scope,
                element: kAudioObjectPropertyElementMain
            )
        )
    }

    // MARK: - Scope-free convenience
    //
    // The UI should never have to reason about Core Audio scopes, so these pick
    // the right one from what the device can actually do. Output wins for a
    // duplex device, because that is the control a user means by "volume".

    private static func naturalScope(for device: AudioDeviceInfo) -> AudioObjectPropertyScope {
        device.canOutput ? kAudioObjectPropertyScopeOutput : kAudioObjectPropertyScopeInput
    }

    static func volume(of device: AudioDeviceInfo) -> Float? {
        volume(of: device.objectID, scope: naturalScope(for: device))
    }

    static func setVolume(_ volume: Float, of device: AudioDeviceInfo) throws {
        try setVolume(volume, of: device.objectID, scope: naturalScope(for: device))
    }

    static func canSetVolume(of device: AudioDeviceInfo) -> Bool {
        canSetVolume(of: device.objectID, scope: naturalScope(for: device))
    }

    static func isMuted(of device: AudioDeviceInfo) -> Bool? {
        isMuted(of: device.objectID, scope: naturalScope(for: device))
    }

    static func setMuted(_ muted: Bool, of device: AudioDeviceInfo) throws {
        try setMuted(muted, of: device.objectID, scope: naturalScope(for: device))
    }

    static func canMute(of device: AudioDeviceInfo) -> Bool {
        canMute(of: device.objectID, scope: naturalScope(for: device))
    }

    /// Channel elements that carry a volume control, 1-based as Core Audio
    /// numbers them.
    private static func volumeChannels(
        _ objectID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectPropertyElement] {
        guard let info = info(for: objectID) else { return [] }
        let count = scope == kAudioObjectPropertyScopeInput
            ? info.inputChannelCount
            : info.outputChannelCount
        guard count > 0 else { return [] }
        return (1 ... count).map(AudioObjectPropertyElement.init).filter { element in
            AudioObjects.hasProperty(
                objectID,
                AudioObjects.address(
                    kAudioDevicePropertyVolumeScalar,
                    scope: scope,
                    element: element
                )
            )
        }
    }
}
