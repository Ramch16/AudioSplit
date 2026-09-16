import CoreAudio
import Foundation

/// One entry from `kAudioHardwarePropertyProcessObjectList`, as reported by the HAL.
///
/// Deliberately free of interpretation — resolving which *app* this belongs to is
/// `ProcessIdentityResolver`'s job.
public struct AudioProcessSnapshot: Sendable, Hashable, Identifiable {
    public let objectID: AudioObjectID
    public let pid: pid_t
    public let halBundleID: String?
    public let isRunning: Bool
    public let isRunningInput: Bool
    public let isRunningOutput: Bool
    /// Devices the process is currently using for output.
    public let outputDeviceIDs: [AudioObjectID]

    public var id: AudioObjectID { objectID }
}

/// Discovers audio-producing processes and notifies when that set changes.
@MainActor
public final class AudioProcessController {
    /// Called whenever the HAL's process object list changes.
    public var onProcessListChanged: (() -> Void)?

    private var listenerBlock: AudioObjectPropertyListenerBlock?
    private let listenerQueue = DispatchQueue(label: "com.audiosplit.process-listener")

    public init() {}

    deinit {
        // `stopObserving` needs main-actor isolation; callers are expected to call
        // it explicitly. This is only a safety net for the property address.
        MainActor.assumeIsolated { stopObserving() }
    }

    // MARK: - Discovery

    private static let processListAddress = AudioObjects.address(
        kAudioHardwarePropertyProcessObjectList
    )

    /// Every process object the HAL knows about, including ones not currently
    /// producing audio.
    public static func allProcessObjectIDs() throws -> [AudioObjectID] {
        try AudioObjects.array(
            AudioObjects.system,
            processListAddress,
            of: AudioObjectID.self,
            operation: "read process object list"
        )
    }

    public static func processObjectID(forPID pid: pid_t) throws -> AudioObjectID? {
        let objectID: AudioObjectID = try AudioObjects.translate(
            AudioObjects.system,
            AudioObjects.address(kAudioHardwarePropertyTranslatePIDToProcessObject),
            qualifier: pid,
            default: AudioObjectID(kAudioObjectUnknown),
            operation: "translate pid \(pid) to process object"
        )
        return objectID == AudioObjectID(kAudioObjectUnknown) ? nil : objectID
    }

    public static func snapshot(of objectID: AudioObjectID) -> AudioProcessSnapshot? {
        guard let pid = AudioObjects.optionalValue(
            objectID,
            AudioObjects.address(kAudioProcessPropertyPID),
            default: pid_t(-1),
            operation: "read process pid"
        ), pid >= 0 else { return nil }

        let bundleID = AudioObjects.optionalString(
            objectID,
            AudioObjects.address(kAudioProcessPropertyBundleID),
            operation: "read process bundle id"
        )

        func flag(_ selector: AudioObjectPropertySelector) -> Bool {
            let value = AudioObjects.optionalValue(
                objectID,
                AudioObjects.address(selector),
                default: UInt32(0),
                operation: "read process flag"
            )
            return (value ?? 0) != 0
        }

        let outputDevices = (try? AudioObjects.array(
            objectID,
            AudioObjects.address(
                kAudioProcessPropertyDevices,
                scope: kAudioObjectPropertyScopeOutput
            ),
            of: AudioObjectID.self,
            operation: "read process output devices"
        )) ?? []

        return AudioProcessSnapshot(
            objectID: objectID,
            pid: pid,
            halBundleID: bundleID?.isEmpty == false ? bundleID : nil,
            isRunning: flag(kAudioProcessPropertyIsRunning),
            isRunningInput: flag(kAudioProcessPropertyIsRunningInput),
            isRunningOutput: flag(kAudioProcessPropertyIsRunningOutput),
            outputDeviceIDs: outputDevices
        )
    }

    public static func allProcesses() throws -> [AudioProcessSnapshot] {
        try allProcessObjectIDs().compactMap(snapshot(of:))
    }

    /// Every process object that resolves to `bundleID`.
    ///
    /// This is deliberately one-to-many and recomputed on demand: an app's set of
    /// audio-producing processes changes constantly as helpers and renderers come
    /// and go. A tap must be given all of them, or part of the app stays audible
    /// on its original device.
    public static func processes(routedAs bundleID: String) throws -> [AudioProcessSnapshot] {
        try allProcesses().filter { process in
            ProcessIdentityResolver.resolve(
                pid: process.pid,
                halBundleID: process.halBundleID
            ).bundleID == bundleID
        }
    }

    // MARK: - Change notification

    public func startObserving() throws {
        guard listenerBlock == nil else { return }
        var address = Self.processListAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor in self?.onProcessListChanged?() }
        }
        try CoreAudioError.check(
            AudioObjectAddPropertyListenerBlock(
                AudioObjects.system,
                &address,
                listenerQueue,
                block
            ),
            "observe process object list"
        )
        listenerBlock = block
    }

    public func stopObserving() {
        guard let block = listenerBlock else { return }
        var address = Self.processListAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjects.system,
            &address,
            listenerQueue,
            block
        )
        listenerBlock = nil
    }
}
