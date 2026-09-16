import CAudioSplitAtomics
import CoreAudio
import Foundation

/// Identifiers AudioSplit stamps on the Core Audio objects it owns, so that
/// orphans left behind by a crash can be found and destroyed on the next launch.
public enum AudioSplitIdentifiers {
    public static let aggregateUIDPrefix = "com.audiosplit.aggregate."

    public static func isAudioSplitAggregate(uid: String) -> Bool {
        uid.hasPrefix(aggregateUIDPrefix)
    }
}

/// One route's realtime parameters and telemetry, shared with the IO thread.
///
/// Allocated once when the aggregate is built and never resized. The control
/// thread writes gain and mute; the IO thread writes peak and frame counts. See
/// `audiosplit_atomics.h` — the accessors are relaxed atomics, which on arm64
/// are plain aligned loads and stores.
typealias TapSlot = as_tap_slot

/// Plain-old-data handed to the realtime thread. Holds no Swift objects, so
/// touching it cannot trigger ARC.
struct RouteIOContext {
    var tapCount: Int32 = 0
    /// Leading input buffers that are not taps. Measured to be 0 on every
    /// destination tried, including duplex Bluetooth devices, but the aggregate
    /// decides the layout, not us.
    var tapBufferOffset: Int32 = 0
    var slots: UnsafeMutablePointer<TapSlot>
    /// One delay line per tap, sized for the 500 ms cap at creation.
    var delayLines: UnsafeMutablePointer<DelayLine>
    /// Shared staging buffer for one tap's delayed output. Sized for the largest
    /// block the device can ask for, so the delay never truncates a cycle.
    var scratch: UnsafeMutablePointer<Float>
    var scratchCapacityFrames: Int32 = 0
    /// Cycles that mixed at least one tap. IO thread only.
    var activeCycles: UInt64 = 0
    /// Cycles that found nothing to mix. IO thread only.
    var emptyCycles: UInt64 = 0
}

/// The whole of the realtime work: level each tap and sum them onto the
/// destination.
///
/// Realtime safe — no allocation, no locks, no ARC, no logging. Everything it
/// touches was allocated before the IOProc started.
@inline(__always)
private func renderRoute(
    input: UnsafePointer<AudioBufferList>,
    output: UnsafeMutablePointer<AudioBufferList>,
    context: UnsafeMutablePointer<RouteIOContext>
) {
    let inputList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    let outputList = UnsafeMutableAudioBufferListPointer(output)
    let tapCount = Int(context.pointee.tapCount)
    let bufferOffset = Int(context.pointee.tapBufferOffset)
    let slots = context.pointee.slots

    // Silence the destination first; every tap accumulates into it.
    var outputFrames = 0
    for index in 0 ..< outputList.count {
        let buffer = outputList[index]
        let channels = Int(buffer.mNumberChannels)
        guard channels > 0, let data = buffer.mData else { continue }
        let samples = data.assumingMemoryBound(to: Float.self)
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        for sample in 0 ..< count { samples[sample] = 0 }
        outputFrames = max(outputFrames, count / channels)
    }

    guard outputFrames > 0 else {
        context.pointee.emptyCycles &+= 1
        return
    }

    var mixedAnything = false

    for tap in 0 ..< tapCount {
        let inputIndex = bufferOffset + tap
        guard inputIndex < inputList.count else { continue }

        // Muted or silent routes cost nothing beyond clearing their meter.
        let slot = slots.advanced(by: tap)

        let source = inputList[inputIndex]
        let sourceChannels = Int(source.mNumberChannels)
        guard sourceChannels > 0, let sourceData = source.mData else { continue }
        let sourceSamples = sourceData.assumingMemoryBound(to: Float.self)
        let sourceFrames = Int(source.mDataByteSize)
            / (MemoryLayout<Float>.size * sourceChannels)
        let frames = min(outputFrames, sourceFrames, Int(context.pointee.scratchCapacityFrames))
        guard frames > 0 else {
            as_slot_set_peak_bits(slot, 0)
            continue
        }

        // Always feed the delay line, even when muted, so unmuting does not
        // replay whatever was in the buffer from before.
        let line = context.pointee.delayLines.advanced(by: tap)
        let delayedChannels = Int(line.pointee.channels)
        delayLineProcess(
            line,
            source: sourceSamples,
            sourceChannels: sourceChannels,
            destination: context.pointee.scratch,
            frames: frames,
            delayFrames: Int(as_slot_delay_frames(slot))
        )
        let delayed = context.pointee.scratch

        // Muted or silent routes still advanced the delay line above; they just
        // do not reach the destination.
        let gain = as_slot_muted(slot) != 0
            ? 0
            : Float(bitPattern: as_slot_gain_bits(slot))
        guard gain > 0 else {
            as_slot_set_peak_bits(slot, 0)
            continue
        }

        var peak: Float = 0
        var globalChannel = 0
        for index in 0 ..< outputList.count {
            let buffer = outputList[index]
            let channels = Int(buffer.mNumberChannels)
            guard channels > 0, let data = buffer.mData else {
                globalChannel += channels
                continue
            }
            let destination = data.assumingMemoryBound(to: Float.self)
            for channel in 0 ..< channels {
                // A destination with more channels than the tap repeats the
                // tap's last channel rather than falling silent.
                let sourceChannel = min(globalChannel + channel, delayedChannels - 1)
                for frame in 0 ..< frames {
                    let sample = delayed[frame * delayedChannels + sourceChannel] * gain
                    destination[frame * channels + channel] += sample
                    let magnitude = sample < 0 ? -sample : sample
                    if magnitude > peak { peak = magnitude }
                }
            }
            globalChannel += channels
        }

        as_slot_set_peak_bits(slot, peak.bitPattern)
        as_slot_add_frames(slot, UInt64(frames))
        mixedAnything = true
    }

    // Independent routes summing can exceed full scale. Clamp rather than
    // letting the driver deal with it.
    for index in 0 ..< outputList.count {
        let buffer = outputList[index]
        guard let data = buffer.mData else { continue }
        let samples = data.assumingMemoryBound(to: Float.self)
        let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
        for sample in 0 ..< count {
            if samples[sample] > 1 {
                samples[sample] = 1
            } else if samples[sample] < -1 {
                samples[sample] = -1
            }
        }
    }

    if mixedAnything {
        context.pointee.activeCycles &+= 1
    } else {
        context.pointee.emptyCycles &+= 1
    }
}

/// Build the IOProc block.
///
/// This lives at file scope, outside any actor, and that is load-bearing. A
/// closure written inside a `@MainActor` type inherits main-actor isolation, and
/// Swift 6 then injects a `swift_task_isCurrentExecutor` check — a
/// `dispatch_assert_queue` — at the top of it. On the realtime IO thread that
/// assertion fails and the process takes SIGTRAP on the very first callback:
///
///     _dispatch_assert_queue_fail
///     swift_task_isCurrentExecutorWithFlags
///     closure #1 in RouteEngine.startRoute(...)
///     HALC_ProxyIOContext::IOWorkLoop()
///
/// Defining the block here keeps it nonisolated, so no check is emitted and
/// nothing actor-related runs on the realtime thread. Every capture is a plain
/// pointer, so there is no ARC traffic either.
private func makeRouteIOBlock(
    context: UnsafeMutablePointer<RouteIOContext>
) -> AudioDeviceIOBlock {
    { _, inputData, _, outputData, _ in
        renderRoute(input: inputData, output: outputData, context: context)
    }
}

/// One live tap inside an aggregate, serving exactly one route.
public struct LiveTap {
    public let routeID: Route.ID
    public let appBundleID: String
    public let handle: TapHandle
    public internal(set) var processObjectIDs: Set<ProcessObjectID>

    public init(
        routeID: Route.ID,
        appBundleID: String,
        handle: TapHandle,
        processObjectIDs: Set<ProcessObjectID>
    ) {
        self.routeID = routeID
        self.appBundleID = appBundleID
        self.handle = handle
        self.processObjectIDs = processObjectIDs
    }
}

/// One live aggregate device: a set of taps, the destination they feed, and the
/// IOProc mixing them together.
public struct LiveAggregate {
    public let destinationDeviceUID: String
    public let destinationName: String
    public let aggregateID: AudioObjectID
    public let aggregateUID: String
    public let outputChannelCount: Int
    /// The clock everything on this aggregate runs at; delay is converted with it.
    public let sampleRate: Double
    /// Largest delay the preallocated buffers can express.
    public let maximumDelayFrames: Int
    /// Ordered to match the aggregate's input buffers and the IO slot array.
    public internal(set) var taps: [LiveTap]

    let ioProcID: AudioDeviceIOProcID
    let context: UnsafeMutablePointer<RouteIOContext>
    let slots: UnsafeMutablePointer<TapSlot>

    public var activeCycles: UInt64 { context.pointee.activeCycles }
    public var emptyCycles: UInt64 { context.pointee.emptyCycles }

    /// Peak level of one route, 0...1.
    public func peak(forRouteID routeID: Route.ID) -> Float? {
        guard let index = taps.firstIndex(where: { $0.routeID == routeID }) else { return nil }
        return Float(bitPattern: as_slot_peak_bits(slots.advanced(by: index)))
    }

    /// Frames this route has contributed since the aggregate started.
    public func framesRendered(forRouteID routeID: Route.ID) -> UInt64? {
        guard let index = taps.firstIndex(where: { $0.routeID == routeID }) else { return nil }
        return as_slot_frames_rendered(slots.advanced(by: index))
    }

    func setParameters(
        gain: Float,
        muted: Bool,
        delayMilliseconds: Double,
        atIndex index: Int
    ) {
        guard index < taps.count else { return }
        let slot = slots.advanced(by: index)
        as_slot_set_gain_bits(slot, gain.bitPattern)
        as_slot_set_muted(slot, muted ? 1 : 0)
        // Milliseconds are converted here, on the control thread, so the
        // realtime thread never divides or touches the sample rate.
        let frames = min(
            DelayLimits.frames(forMilliseconds: delayMilliseconds, sampleRate: sampleRate),
            maximumDelayFrames
        )
        as_slot_set_delay_frames(slot, UInt32(max(0, frames)))
    }

    /// The reconciler's view of this aggregate.
    public var spec: AggregateSpec {
        AggregateSpec(
            destinationDeviceUID: destinationDeviceUID,
            taps: taps.map {
                TapSpec(
                    routeID: $0.routeID,
                    appBundleID: $0.appBundleID,
                    processObjectIDs: $0.processObjectIDs
                )
            }
        )
    }
}

/// An action the engine could not carry out. Reconciliation continues past
/// these — one broken route must not stop the others from working.
public struct ReconcileFailure: Sendable {
    public let destinationDeviceUID: String
    public let message: String
}

/// Builds the aggregate devices that make taps audible on chosen destinations,
/// and runs the IOProcs that mix them.
///
/// One aggregate per destination device, containing every tap bound for it plus
/// the destination as sub-device, with the destination as clock master. That
/// gives a single IOProc where each route arrives as its own input buffer and
/// the destination is output, all on one clock — so the work is a gain stage and
/// a sum. No ring buffer, no sample rate conversion, no manual drift correction.
@MainActor
public final class RouteEngine {
    private var aggregates: [String: LiveAggregate] = [:]

    public init() {}

    public var liveAggregates: [LiveAggregate] {
        aggregates.values.sorted { $0.destinationName < $1.destinationName }
    }

    /// Live state in the form the reconciler consumes.
    public var liveSpecs: [String: AggregateSpec] {
        aggregates.mapValues(\.spec)
    }

    /// Peak level for a route, if it is currently live.
    public func peak(forRouteID routeID: Route.ID) -> Float? {
        for aggregate in aggregates.values {
            if let peak = aggregate.peak(forRouteID: routeID) { return peak }
        }
        return nil
    }

    // MARK: - Reconciliation

    /// Gather the current state of the machine, diff it against `routes`, and
    /// make Core Audio match.
    ///
    /// Safe to call on any event and safe to call repeatedly — the diffing is
    /// done by `RouteReconciler`, which is idempotent.
    @discardableResult
    public func reconcile(routes: [Route]) throws -> (ReconcileResult, [ReconcileFailure]) {
        let devices = try DeviceStore.allDevices()
        let destinations = Set(
            devices.filter { $0.canOutput && !$0.isAggregate }.map(\.uid)
        )

        let input = ReconcilerInput(
            routes: routes,
            availableDestinationUIDs: destinations,
            processObjectIDsByBundleID: try Self.processObjectIDsByBundleID()
        )

        let result = RouteReconciler.reconcile(input, live: liveSpecs)
        let failures = apply(result.actions, devices: devices)

        // Volume and mute are pushed every time, separately from the topology.
        // A slider move must never look like a structural change.
        applyParameters(routes: routes)
        return (result, failures)
    }

    /// Push per-route gain and mute to the realtime thread. Lock-free and cheap
    /// enough to call on every slider movement.
    public func applyParameters(routes: [Route]) {
        let routesByID = Dictionary(routes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for aggregate in aggregates.values {
            for (index, tap) in aggregate.taps.enumerated() {
                guard let route = routesByID[tap.routeID] else { continue }
                aggregate.setParameters(
                    gain: route.effectiveGain,
                    muted: route.isMuted,
                    delayMilliseconds: route.delayMilliseconds,
                    atIndex: index
                )
            }
        }
    }

    /// Every audio process object on the system, grouped by the app it belongs to.
    ///
    /// Processes that are alive but silent are included on purpose: a tap that
    /// already covers them captures the first buffer of audio, instead of
    /// letting it leak to the old device while we notice and catch up.
    public static func processObjectIDsByBundleID() throws -> [String: Set<ProcessObjectID>] {
        var result: [String: Set<ProcessObjectID>] = [:]
        for process in try AudioProcessController.allProcesses() {
            let identity = ProcessIdentityResolver.resolve(
                pid: process.pid,
                halBundleID: process.halBundleID
            )
            guard identity.isResolved else { continue }
            result[identity.bundleID, default: []].insert(ProcessObjectID(process.objectID))
        }
        return result
    }

    /// Carry out reconciler actions. Failures are collected, not thrown, so one
    /// unusable destination cannot take the others down with it.
    @discardableResult
    public func apply(
        _ actions: [ReconcileAction],
        devices: [AudioDeviceInfo]
    ) -> [ReconcileFailure] {
        let devicesByUID = Dictionary(
            devices.map { ($0.uid, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        var failures: [ReconcileFailure] = []

        for action in actions {
            do {
                switch action {
                case let .destroy(uid):
                    if let aggregate = aggregates[uid] { teardown(aggregate) }

                case let .create(spec):
                    try create(spec, devicesByUID: devicesByUID)

                case let .update(spec):
                    try update(spec, devicesByUID: devicesByUID)
                }
            } catch {
                failures.append(ReconcileFailure(
                    destinationDeviceUID: action.destinationDeviceUID,
                    message: String(describing: error)
                ))
            }
        }
        return failures
    }

    // MARK: - Individual actions

    private func destination(
        _ uid: String,
        in devicesByUID: [String: AudioDeviceInfo]
    ) throws -> AudioDeviceInfo {
        guard let device = devicesByUID[uid] else {
            throw CoreAudioError(
                status: kAudioHardwareBadDeviceError,
                operation: "find destination \(uid)"
            )
        }
        guard !device.isAggregate else {
            throw CoreAudioError(
                status: kAudioHardwareIllegalOperationError,
                operation: "use aggregate device \(device.name) as a destination"
            )
        }
        return device
    }

    private func create(
        _ spec: AggregateSpec,
        devicesByUID: [String: AudioDeviceInfo]
    ) throws {
        let destination = try destination(spec.destinationDeviceUID, in: devicesByUID)

        var taps: [LiveTap] = []
        func destroyTaps() {
            for tap in taps { TapController.destroy(tap.handle) }
        }

        do {
            for tapSpec in spec.taps {
                let handle = try TapController.createTap(
                    name: "AudioSplit — \(tapSpec.appBundleID) → \(destination.name)",
                    processObjectIDs: tapSpec.processObjectIDs.sorted()
                )
                taps.append(LiveTap(
                    routeID: tapSpec.routeID,
                    appBundleID: tapSpec.appBundleID,
                    handle: handle,
                    processObjectIDs: tapSpec.processObjectIDs
                ))
            }
            let aggregate = try startAggregate(taps: taps, destination: destination)
            aggregates[spec.destinationDeviceUID] = aggregate
        } catch {
            destroyTaps()
            throw error
        }
    }

    private func update(
        _ spec: AggregateSpec,
        devicesByUID: [String: AudioDeviceInfo]
    ) throws {
        guard var aggregate = aggregates[spec.destinationDeviceUID] else {
            // Nothing live to update — treat it as a create so reconcile stays
            // idempotent even if our bookkeeping has drifted.
            try create(spec, devicesByUID: devicesByUID)
            return
        }

        // Adding or removing a route changes the aggregate's tap list, which is
        // fixed at creation. Re-point existing taps in place; rebuild only when
        // the set of routes itself changed.
        if spec.requiresRebuild(comparedTo: aggregate.spec) {
            teardown(aggregate)
            try create(spec, devicesByUID: devicesByUID)
            return
        }

        for (index, tapSpec) in spec.taps.enumerated() {
            guard index < aggregate.taps.count else { continue }
            guard aggregate.taps[index].processObjectIDs != tapSpec.processObjectIDs else {
                continue
            }
            try TapController.setProcessObjectIDs(
                tapSpec.processObjectIDs.sorted(),
                onTap: aggregate.taps[index].handle.objectID
            )
            aggregate.taps[index].processObjectIDs = tapSpec.processObjectIDs
        }
        aggregates[spec.destinationDeviceUID] = aggregate
    }

    // MARK: - Lifecycle

    /// Build the aggregate around a set of existing taps and start audio flowing.
    public func startAggregate(
        taps: [LiveTap],
        destination: AudioDeviceInfo
    ) throws -> LiveAggregate {
        guard !taps.isEmpty else {
            throw CoreAudioError(
                status: kAudioHardwareIllegalOperationError,
                operation: "build an aggregate with no taps"
            )
        }

        let aggregateUID = AudioSplitIdentifiers.aggregateUIDPrefix + UUID().uuidString
        let aggregateID = try createAggregate(
            uid: aggregateUID,
            name: "AudioSplit → \(destination.name)",
            destination: destination,
            tapUIDs: taps.map(\.handle.uid)
        )

        // Everything the realtime thread will touch is allocated here, before
        // the IOProc exists, and never resized afterwards.
        let aggregateInfo = DeviceStore.info(for: aggregateID)
        let sampleRate = aggregateInfo?.nominalSampleRate ?? destination.nominalSampleRate
        // Ask the device how large a block it may hand us, then leave generous
        // headroom — a truncated cycle would drop audio, not just delay it.
        let deviceBlockFrames = Int(AudioObjects.optionalValue(
            aggregateID,
            AudioObjects.address(kAudioDevicePropertyBufferFrameSize),
            default: UInt32(512),
            operation: "read buffer frame size"
        ) ?? 512)
        let blockFrames = max(deviceBlockFrames * 4, 4096)

        let delayCapacity = DelayLimits.capacityFrames(
            sampleRate: sampleRate > 0 ? sampleRate : 48000,
            maximumBlockFrames: blockFrames
        )
        let maximumDelayFrames = delayCapacity - blockFrames

        let slots = UnsafeMutablePointer<TapSlot>.allocate(capacity: taps.count)
        for index in 0 ..< taps.count {
            as_slot_init(slots.advanced(by: index), Float(1).bitPattern, 0)
        }

        let maximumChannels = max(taps.map(\.handle.channelCount).max() ?? 2, 1)
        let delayLines = UnsafeMutablePointer<DelayLine>.allocate(capacity: taps.count)
        var delayStorage: [UnsafeMutablePointer<Float>] = []
        for (index, tap) in taps.enumerated() {
            let channels = max(tap.handle.channelCount, 1)
            let storage = UnsafeMutablePointer<Float>.allocate(
                capacity: delayCapacity * channels
            )
            storage.initialize(repeating: 0, count: delayCapacity * channels)
            delayStorage.append(storage)
            delayLines.advanced(by: index).initialize(to: DelayLine(
                storage: storage,
                capacityFrames: Int32(delayCapacity),
                channels: Int32(channels),
                writeIndex: 0,
                maximumDelayFrames: Int32(maximumDelayFrames)
            ))
        }

        let scratch = UnsafeMutablePointer<Float>.allocate(
            capacity: blockFrames * maximumChannels
        )
        scratch.initialize(repeating: 0, count: blockFrames * maximumChannels)

        let context = UnsafeMutablePointer<RouteIOContext>.allocate(capacity: 1)

        func releaseMemory() {
            for storage in delayStorage { storage.deallocate() }
            delayLines.deallocate()
            scratch.deallocate()
            slots.deallocate()
            context.deallocate()
        }

        do {
            let inputBuffers = try bufferCount(aggregateID, scope: kAudioObjectPropertyScopeInput)
            let outputChannels = DeviceStore.info(for: aggregateID)?.outputChannelCount ?? 0

            context.initialize(to: RouteIOContext(
                tapCount: Int32(taps.count),
                // Taps arrive as the trailing input buffers if the destination
                // ever contributes any of its own.
                tapBufferOffset: Int32(max(0, inputBuffers - taps.count)),
                slots: slots,
                delayLines: delayLines,
                scratch: scratch,
                scratchCapacityFrames: Int32(blockFrames)
            ))

            var ioProcID: AudioDeviceIOProcID?
            let status = AudioDeviceCreateIOProcIDWithBlock(
                &ioProcID,
                aggregateID,
                nil, // nil queue: run on the device's realtime IO thread
                makeRouteIOBlock(context: context)
            )
            guard status == noErr, let ioProcID else {
                throw CoreAudioError(status: status, operation: "create IOProc")
            }

            do {
                try CoreAudioError.check(
                    AudioDeviceStart(aggregateID, ioProcID),
                    "start aggregate device"
                )
            } catch {
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
                throw error
            }

            return LiveAggregate(
                destinationDeviceUID: destination.uid,
                destinationName: destination.name,
                aggregateID: aggregateID,
                aggregateUID: aggregateUID,
                outputChannelCount: outputChannels,
                sampleRate: sampleRate,
                maximumDelayFrames: maximumDelayFrames,
                taps: taps,
                ioProcID: ioProcID,
                context: context,
                slots: slots
            )
        } catch {
            releaseMemory()
            AudioHardwareDestroyAggregateDevice(aggregateID)
            throw error
        }
    }

    /// Tear an aggregate down completely: stop IO, destroy the IOProc, the
    /// aggregate and every tap, and free the IO memory.
    @discardableResult
    public func teardown(_ aggregate: LiveAggregate) -> [String] {
        var problems: [String] = []
        func note(_ status: OSStatus, _ what: String) {
            guard status != noErr else { return }
            problems.append("\(what): \(CoreAudioError.describe(status))")
        }

        note(AudioDeviceStop(aggregate.aggregateID, aggregate.ioProcID), "stop device")
        note(
            AudioDeviceDestroyIOProcID(aggregate.aggregateID, aggregate.ioProcID),
            "destroy IOProc"
        )
        note(
            AudioHardwareDestroyAggregateDevice(aggregate.aggregateID),
            "destroy aggregate"
        )
        for tap in aggregate.taps {
            note(AudioHardwareDestroyProcessTap(tap.handle.objectID), "destroy tap")
        }

        for index in 0 ..< aggregate.taps.count {
            aggregate.context.pointee.delayLines[index].storage.deallocate()
        }
        aggregate.context.pointee.delayLines.deallocate()
        aggregate.context.pointee.scratch.deallocate()
        aggregate.slots.deallocate()
        aggregate.context.deallocate()

        aggregates[aggregate.destinationDeviceUID] = nil
        return problems
    }

    /// Destroy every aggregate this engine owns. Restores normal audio.
    @discardableResult
    public func stopAll() -> [String] {
        // Snapshot first: teardown mutates `aggregates`.
        let problems = Array(aggregates.values).flatMap(teardown)
        aggregates.removeAll()
        return problems
    }

    // MARK: - Aggregate construction

    private func createAggregate(
        uid: String,
        name: String,
        destination: AudioDeviceInfo,
        tapUIDs: [String]
    ) throws -> AudioObjectID {
        let description: [String: Any] = [
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceNameKey: name,
            // Private keeps it out of Sound settings and Audio MIDI Setup.
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            // The destination is the clock master; everything else follows it.
            kAudioAggregateDeviceMainSubDeviceKey: destination.uid,
            kAudioAggregateDeviceSubDeviceListKey: [
                [
                    kAudioSubDeviceUIDKey: destination.uid,
                    // The master defines the clock, so it has nothing to drift against.
                    kAudioSubDeviceDriftCompensationKey: 0,
                ],
            ],
            // Order matters: the aggregate presents one input buffer per tap in
            // this order, and the IOProc indexes them positionally.
            kAudioAggregateDeviceTapListKey: tapUIDs.map { uid in
                [
                    kAudioSubTapUIDKey: uid,
                    // Each tap runs off its app's clock, not the destination's.
                    kAudioSubTapDriftCompensationKey: 1,
                ]
            },
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioError.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
            "create aggregate device for \(destination.name)"
        )
        guard aggregateID != AudioObjectID(kAudioObjectUnknown) else {
            throw CoreAudioError(
                status: kAudioHardwareBadObjectError,
                operation: "create aggregate device"
            )
        }
        return aggregateID
    }

    /// Number of buffers the device presents in a scope — one per tap on the
    /// input side.
    private func bufferCount(
        _ objectID: AudioObjectID,
        scope: AudioObjectPropertyScope
    ) throws -> Int {
        let address = AudioObjects.address(
            kAudioDevicePropertyStreamConfiguration,
            scope: scope
        )
        let size = try AudioObjects.dataSize(
            objectID,
            address,
            operation: "read stream configuration"
        )
        guard size >= UInt32(MemoryLayout<AudioBufferList>.size) else { return 0 }

        var mutableAddress = address
        var mutableSize = size
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        try CoreAudioError.check(
            AudioObjectGetPropertyData(objectID, &mutableAddress, 0, nil, &mutableSize, raw),
            "read stream configuration"
        )
        return UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        ).count
    }
}
