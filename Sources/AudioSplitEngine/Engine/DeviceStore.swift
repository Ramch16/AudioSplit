import CoreAudio
import Foundation

/// A hardware (or aggregate) audio device as the HAL describes it.
public struct AudioDeviceInfo: Sendable, Hashable, Identifiable {
    public let objectID: AudioObjectID
    /// Stable across reboots and reconnects — this is what we persist, never the objectID.
    public let uid: String
    public let name: String
    public let manufacturer: String?
    public let transportType: UInt32
    public let inputChannelCount: Int
    public let outputChannelCount: Int
    public let nominalSampleRate: Double
    public let classID: AudioClassID

    public var id: AudioObjectID { objectID }
    public var canOutput: Bool { outputChannelCount > 0 }
    public var canInput: Bool { inputChannelCount > 0 }
    public var isAggregate: Bool { classID == kAudioAggregateDeviceClassID }

    public var transportDescription: String {
        switch transportType {
        case kAudioDeviceTransportTypeBuiltIn: "Built-in"
        case kAudioDeviceTransportTypeAggregate: "Aggregate"
        case kAudioDeviceTransportTypeVirtual: "Virtual"
        case kAudioDeviceTransportTypeAirPlay: "AirPlay"
        case kAudioDeviceTransportTypeBluetooth: "Bluetooth"
        case kAudioDeviceTransportTypeBluetoothLE: "Bluetooth LE"
        case kAudioDeviceTransportTypeUSB: "USB"
        case kAudioDeviceTransportTypeHDMI: "HDMI"
        case kAudioDeviceTransportTypeDisplayPort: "DisplayPort"
        case kAudioDeviceTransportTypeThunderbolt: "Thunderbolt"
        case kAudioDeviceTransportTypePCI: "PCI"
        case kAudioDeviceTransportTypeFireWire: "FireWire"
        case kAudioDeviceTransportTypeAVB: "AVB"
        case kAudioDeviceTransportTypeContinuityCaptureWired: "Continuity (wired)"
        case kAudioDeviceTransportTypeContinuityCaptureWireless: "Continuity (wireless)"
        case kAudioDeviceTransportTypeUnknown: "Unknown"
        default: "Other"
        }
    }
}

/// Enumerates audio devices and the system default selections, and notifies on change.
@MainActor
public final class DeviceStore {
    public var onDevicesChanged: (() -> Void)?
    public var onDefaultInputChanged: (() -> Void)?
    public var onDefaultOutputChanged: (() -> Void)?

    private let listenerQueue = DispatchQueue(label: "com.audiosplit.device-listener")
    private var registeredListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []

    public init() {}

    deinit {
        MainActor.assumeIsolated { stopObserving() }
    }

    // MARK: - Enumeration

    public static func allDeviceIDs() throws -> [AudioObjectID] {
        try AudioObjects.array(
            AudioObjects.system,
            AudioObjects.address(kAudioHardwarePropertyDevices),
            of: AudioObjectID.self,
            operation: "read device list"
        )
    }

    public static func info(for objectID: AudioObjectID) -> AudioDeviceInfo? {
        guard let uid = AudioObjects.optionalString(
            objectID,
            AudioObjects.address(kAudioDevicePropertyDeviceUID),
            operation: "read device uid"
        ) else { return nil }

        let name = AudioObjects.optionalString(
            objectID,
            AudioObjects.address(kAudioObjectPropertyName),
            operation: "read device name"
        ) ?? uid

        return AudioDeviceInfo(
            objectID: objectID,
            uid: uid,
            name: name,
            manufacturer: AudioObjects.optionalString(
                objectID,
                AudioObjects.address(kAudioObjectPropertyManufacturer),
                operation: "read device manufacturer"
            ),
            transportType: AudioObjects.optionalValue(
                objectID,
                AudioObjects.address(kAudioDevicePropertyTransportType),
                default: UInt32(kAudioDeviceTransportTypeUnknown),
                operation: "read transport type"
            ) ?? UInt32(kAudioDeviceTransportTypeUnknown),
            inputChannelCount: channelCount(objectID, scope: kAudioObjectPropertyScopeInput),
            outputChannelCount: channelCount(objectID, scope: kAudioObjectPropertyScopeOutput),
            nominalSampleRate: AudioObjects.optionalValue(
                objectID,
                AudioObjects.address(kAudioDevicePropertyNominalSampleRate),
                default: Double(0),
                operation: "read nominal sample rate"
            ) ?? 0,
            classID: AudioObjects.optionalValue(
                objectID,
                AudioObjects.address(kAudioObjectPropertyClass),
                default: AudioClassID(0),
                operation: "read class id"
            ) ?? 0
        )
    }

    public static func allDevices() throws -> [AudioDeviceInfo] {
        try allDeviceIDs().compactMap(info(for:))
    }

    public static func outputDevices() throws -> [AudioDeviceInfo] {
        try allDevices().filter(\.canOutput)
    }

    public static func inputDevices() throws -> [AudioDeviceInfo] {
        try allDevices().filter(\.canInput)
    }

    public static func device(withUID uid: String) throws -> AudioDeviceInfo? {
        try allDevices().first { $0.uid == uid }
    }

    /// `kAudioDevicePropertyStreamConfiguration` returns a variable-length
    /// AudioBufferList; sum the channels across its buffers.
    private static func channelCount(
        _ objectID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) -> Int {
        let address = AudioObjects.address(
            kAudioDevicePropertyStreamConfiguration,
            scope: scope
        )
        guard AudioObjects.hasProperty(objectID, address),
              let size = try? AudioObjects.dataSize(
                  objectID,
                  address,
                  operation: "read stream configuration"
              ),
              size >= UInt32(MemoryLayout<AudioBufferList>.size)
        else { return 0 }

        var mutableAddress = address
        var mutableSize = size
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }

        guard AudioObjectGetPropertyData(
            objectID,
            &mutableAddress,
            0,
            nil,
            &mutableSize,
            raw
        ) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    // MARK: - System defaults

    public static func defaultDeviceID(
        _ selector: AudioObjectPropertySelector
    ) throws -> AudioObjectID? {
        let objectID: AudioObjectID = try AudioObjects.value(
            AudioObjects.system,
            AudioObjects.address(selector),
            default: AudioObjectID(kAudioObjectUnknown),
            operation: "read default device"
        )
        return objectID == AudioObjectID(kAudioObjectUnknown) ? nil : objectID
    }

    public static func defaultOutputDeviceID() throws -> AudioObjectID? {
        try defaultDeviceID(kAudioHardwarePropertyDefaultOutputDevice)
    }

    public static func defaultInputDeviceID() throws -> AudioObjectID? {
        try defaultDeviceID(kAudioHardwarePropertyDefaultInputDevice)
    }

    public static func defaultSystemOutputDeviceID() throws -> AudioObjectID? {
        try defaultDeviceID(kAudioHardwarePropertyDefaultSystemOutputDevice)
    }

    /// Make a device the system default input.
    ///
    /// This is a plain system-wide preference change, the same one the Sound
    /// pane makes. It is not part of routing and does not involve taps — per-app
    /// input routing is explicitly out of scope.
    public static func setDefaultInputDevice(_ objectID: AudioObjectID) throws {
        try AudioObjects.setValue(
            AudioObjects.system,
            AudioObjects.address(kAudioHardwarePropertyDefaultInputDevice),
            to: objectID,
            operation: "set default input device"
        )
    }

    public static func setDefaultInputDevice(uid: String) throws {
        guard let device = try device(withUID: uid), device.canInput else {
            throw CoreAudioError(
                status: kAudioHardwareBadDeviceError,
                operation: "find input device \(uid)"
            )
        }
        try setDefaultInputDevice(device.objectID)
    }

    // MARK: - Change notification

    public func startObserving() throws {
        try addListener(AudioObjects.address(kAudioHardwarePropertyDevices)) { [weak self] in
            self?.onDevicesChanged?()
        }
        try addListener(
            AudioObjects.address(kAudioHardwarePropertyDefaultInputDevice)
        ) { [weak self] in
            self?.onDefaultInputChanged?()
        }
        try addListener(
            AudioObjects.address(kAudioHardwarePropertyDefaultOutputDevice)
        ) { [weak self] in
            self?.onDefaultOutputChanged?()
        }
    }

    public func stopObserving() {
        for (address, block) in registeredListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(
                AudioObjects.system,
                &address,
                listenerQueue,
                block
            )
        }
        registeredListeners.removeAll()
    }

    private func addListener(
        _ address: AudioObjectPropertyAddress,
        handler: @escaping @MainActor () -> Void
    ) throws {
        var address = address
        let block: AudioObjectPropertyListenerBlock = { _, _ in
            Task { @MainActor in handler() }
        }
        try CoreAudioError.check(
            AudioObjectAddPropertyListenerBlock(
                AudioObjects.system,
                &address,
                listenerQueue,
                block
            ),
            "observe device property"
        )
        registeredListeners.append((address, block))
    }
}
