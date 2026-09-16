import CoreAudio
import Foundation

/// A failed Core Audio HAL call, carrying the `OSStatus` and what we were doing.
public struct CoreAudioError: Error, CustomStringConvertible, Sendable {
    public let status: OSStatus
    public let operation: String

    public init(status: OSStatus, operation: String) {
        self.status = status
        self.operation = operation
    }

    /// Most HAL errors are four-char codes; render them readably when they are.
    public var description: String {
        "\(operation) failed: \(Self.describe(status)) (\(status))"
    }

    public static func describe(_ status: OSStatus) -> String {
        let bytes = [
            UInt8((status >> 24) & 0xFF),
            UInt8((status >> 16) & 0xFF),
            UInt8((status >> 8) & 0xFF),
            UInt8(status & 0xFF),
        ]
        let printable = bytes.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
        guard printable, let text = String(bytes: bytes, encoding: .ascii) else {
            return "OSStatus \(status)"
        }
        return "'\(text)'"
    }

    @inlinable
    public static func check(_ status: OSStatus, _ operation: @autoclosure () -> String) throws {
        guard status == noErr else {
            throw CoreAudioError(status: status, operation: operation())
        }
    }
}

/// Thin, allocation-tolerant wrappers over `AudioObjectGetPropertyData` and friends.
///
/// Nothing in here is realtime safe — it is for the control path only.
public enum AudioObjects {
    public static let system = AudioObjectID(kAudioObjectSystemObject)

    public static func address(
        _ selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
        element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    public static func hasProperty(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress
    ) -> Bool {
        var address = address
        return AudioObjectHasProperty(objectID, &address)
    }

    public static func isSettable(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress
    ) -> Bool {
        var address = address
        var settable: DarwinBoolean = false
        guard AudioObjectHasProperty(objectID, &address),
              AudioObjectIsPropertySettable(objectID, &address, &settable) == noErr
        else { return false }
        return settable.boolValue
    }

    public static func dataSize(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        operation: String
    ) throws -> UInt32 {
        var address = address
        var size: UInt32 = 0
        try CoreAudioError.check(
            AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &size),
            "\(operation) (size)"
        )
        return size
    }

    /// Read a fixed-size POD property (UInt32, pid_t, Float64, AudioObjectID, ASBD, ...).
    public static func value<T>(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        default defaultValue: T,
        operation: String
    ) throws -> T {
        var address = address
        var value = defaultValue
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        try CoreAudioError.check(status, operation)
        return value
    }

    /// Write a fixed-size POD property.
    public static func setValue<T>(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        to value: T,
        operation: String
    ) throws {
        var address = address
        var value = value
        let size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafePointer(to: &value) { pointer in
            AudioObjectSetPropertyData(objectID, &address, 0, nil, size, pointer)
        }
        try CoreAudioError.check(status, operation)
    }

    /// Read a variable-length array property (device lists, process lists, ...).
    public static func array<T>(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        of _: T.Type,
        operation: String
    ) throws -> [T] {
        var address = address
        var size = try dataSize(objectID, address, operation: operation)
        guard size > 0 else { return [] }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<T>.alignment
        )
        defer { raw.deallocate() }

        try CoreAudioError.check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, raw),
            operation
        )

        let count = Int(size) / MemoryLayout<T>.stride
        let typed = raw.bindMemory(to: T.self, capacity: count)
        return Array(UnsafeBufferPointer(start: typed, count: count))
    }

    /// Read a `CFStringRef` property. The HAL hands these back at +1.
    public static func string(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        operation: String
    ) throws -> String? {
        var address = address
        var unmanaged: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanaged) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, pointer)
        }
        try CoreAudioError.check(status, operation)
        return unmanaged?.takeRetainedValue() as String?
    }

    /// Same as `string`, but returns nil instead of throwing when the property is absent.
    public static func optionalString(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        operation: String
    ) -> String? {
        guard hasProperty(objectID, address) else { return nil }
        return try? string(objectID, address, operation: operation)
    }

    /// Same as `value`, but returns nil instead of throwing when the property is absent.
    public static func optionalValue<T>(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        default defaultValue: T,
        operation: String
    ) -> T? {
        guard hasProperty(objectID, address) else { return nil }
        return try? value(objectID, address, default: defaultValue, operation: operation)
    }

    /// Read a property that needs qualifier data, e.g. translating a PID to a process object.
    public static func translate<Qualifier, Result>(
        _ objectID: AudioObjectID,
        _ address: AudioObjectPropertyAddress,
        qualifier: Qualifier,
        default defaultValue: Result,
        operation: String
    ) throws -> Result {
        var address = address
        var qualifier = qualifier
        var result = defaultValue
        var size = UInt32(MemoryLayout<Result>.size)
        let status = withUnsafeMutablePointer(to: &qualifier) { qualifierPointer in
            withUnsafeMutablePointer(to: &result) { resultPointer in
                AudioObjectGetPropertyData(
                    objectID,
                    &address,
                    UInt32(MemoryLayout<Qualifier>.size),
                    qualifierPointer,
                    &size,
                    resultPointer
                )
            }
        }
        try CoreAudioError.check(status, operation)
        return result
    }
}
