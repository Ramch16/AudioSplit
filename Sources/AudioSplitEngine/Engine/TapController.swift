import CoreAudio
import Foundation

/// A live process tap and the facts we need about it to wire up IO.
public struct TapHandle {
    public let objectID: AudioObjectID
    /// Persistent for the life of the tap; this is what goes in an aggregate's tap list.
    public let uid: String
    /// The tap's actual stream format. Never assume — it follows the tapped
    /// processes' output, and a mixdown tap is whatever the HAL decides.
    public let format: AudioStreamBasicDescription

    public var channelCount: Int { Int(format.mChannelsPerFrame) }
    public var sampleRate: Double { format.mSampleRate }
    public var isFloat: Bool { format.mFormatFlags & kAudioFormatFlagIsFloat != 0 }
    public var isInterleaved: Bool {
        format.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0
    }

    public var formatDescription: String {
        let layout = isInterleaved ? "interleaved" : "non-interleaved"
        let sampleType = isFloat ? "float\(format.mBitsPerChannel)" : "int\(format.mBitsPerChannel)"
        return "\(Int(format.mSampleRate)) Hz, \(format.mChannelsPerFrame) ch, \(sampleType), \(layout)"
    }
}

/// Creates and destroys Core Audio process taps.
///
/// A tap on its own produces nothing — it has to be placed in an aggregate
/// device before any audio can be read from it. See `RouteEngine`.
public enum TapController {
    /// Create a tap that mixes the given processes down to stereo and removes
    /// their audio from wherever it was going.
    ///
    /// `muteBehavior = .mutedWhenTapped` is what makes this a *route* rather than
    /// a duplicate: the HAL stops sending the tapped processes' audio to the
    /// hardware for as long as something is reading the tap. Without it you hear
    /// the app twice, once on its original device and once on the destination.
    public static func createTap(
        name: String,
        processObjectIDs: [AudioObjectID]
    ) throws -> TapHandle {
        guard !processObjectIDs.isEmpty else {
            throw CoreAudioError(status: kAudioHardwareIllegalOperationError, operation: "create tap with no processes")
        }

        let description = CATapDescription(stereoMixdownOfProcesses: processObjectIDs)
        description.name = name
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioError.check(
            AudioHardwareCreateProcessTap(description, &tapID),
            "create process tap"
        )
        guard tapID != AudioObjectID(kAudioObjectUnknown) else {
            throw CoreAudioError(status: kAudioHardwareBadObjectError, operation: "create process tap")
        }

        do {
            return TapHandle(
                objectID: tapID,
                uid: try uid(of: tapID),
                format: try format(of: tapID)
            )
        } catch {
            // Never leak a tap we cannot describe.
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
    }

    /// Diagnostic: tap everything except the given processes.
    ///
    /// Not used for routing — a global tap cannot express per-app routing. It
    /// exists to separate "the tap mechanism is not working" from "we selected
    /// the wrong processes", which are indistinguishable from the symptom
    /// (silence) alone.
    public static func createGlobalTap(
        name: String,
        excluding processObjectIDs: [AudioObjectID] = []
    ) throws -> TapHandle {
        let description = CATapDescription(
            stereoGlobalTapButExcludeProcesses: processObjectIDs
        )
        description.name = name
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tapID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioError.check(
            AudioHardwareCreateProcessTap(description, &tapID),
            "create global process tap"
        )
        do {
            return TapHandle(
                objectID: tapID,
                uid: try uid(of: tapID),
                format: try format(of: tapID)
            )
        } catch {
            AudioHardwareDestroyProcessTap(tapID)
            throw error
        }
    }

    /// Read back the description a tap was created with.
    public static func description(of tapID: AudioObjectID) throws -> CATapDescription {
        var address = AudioObjects.address(kAudioTapPropertyDescription)
        var unmanaged: Unmanaged<CATapDescription>?
        var size = UInt32(MemoryLayout<Unmanaged<CATapDescription>?>.size)
        let status = withUnsafeMutablePointer(to: &unmanaged) { pointer in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, pointer)
        }
        try CoreAudioError.check(status, "read tap description")
        guard let description = unmanaged?.takeRetainedValue() else {
            throw CoreAudioError(
                status: kAudioHardwareBadObjectError,
                operation: "read tap description"
            )
        }
        return description
    }

    /// Change which processes a live tap covers, without disturbing the
    /// aggregate device or the IOProc built around it.
    ///
    /// This is the difference between a browser opening a tab and the user
    /// hearing a dropout. Helper processes appear and disappear constantly, so
    /// the tap's process list changes far more often than the route does;
    /// rebuilding the aggregate each time would glitch the audio every time.
    ///
    /// The existing description is read back and mutated rather than replaced,
    /// so the tap keeps its UUID — and therefore its UID, which is what the
    /// aggregate's tap list refers to.
    public static func setProcessObjectIDs(
        _ processObjectIDs: [AudioObjectID],
        onTap tapID: AudioObjectID
    ) throws {
        let description = try description(of: tapID)
        description.processes = processObjectIDs

        var address = AudioObjects.address(kAudioTapPropertyDescription)
        var object = description
        let status = withUnsafePointer(to: &object) { pointer in
            AudioObjectSetPropertyData(
                tapID,
                &address,
                0,
                nil,
                UInt32(MemoryLayout<UnsafeRawPointer>.size),
                pointer
            )
        }
        try CoreAudioError.check(status, "update tap process list")
    }

    public static func destroy(_ handle: TapHandle) {
        AudioHardwareDestroyProcessTap(handle.objectID)
    }

    public static func uid(of tapID: AudioObjectID) throws -> String {
        guard let uid = try AudioObjects.string(
            tapID,
            AudioObjects.address(kAudioTapPropertyUID),
            operation: "read tap uid"
        ) else {
            throw CoreAudioError(status: kAudioHardwareBadObjectError, operation: "read tap uid")
        }
        return uid
    }

    public static func format(of tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        try AudioObjects.value(
            tapID,
            AudioObjects.address(kAudioTapPropertyFormat),
            default: AudioStreamBasicDescription(),
            operation: "read tap format"
        )
    }
}
