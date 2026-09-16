import Foundation

// Deliberately no Core Audio import. Everything here is pure value-to-value so
// it can be unit tested without hardware, without permissions, and without
// leaving devices behind when a test fails.

/// Everything the reconciler needs to know about the world.
public struct ReconcilerInput: Hashable, Sendable {
    /// Desired state, in user-visible order. Order decides who wins a conflict.
    public var routes: [Route]
    /// Output devices currently connected.
    public var availableDestinationUIDs: Set<String>
    /// Audio process objects currently resolving to each app.
    ///
    /// This includes processes that are not making noise right now. An idle
    /// process still belongs in the tap, so that audio is already captured the
    /// instant it starts rather than leaking to the old device for a moment.
    public var processObjectIDsByBundleID: [String: Set<ProcessObjectID>]

    public init(
        routes: [Route],
        availableDestinationUIDs: Set<String>,
        processObjectIDsByBundleID: [String: Set<ProcessObjectID>]
    ) {
        self.routes = routes
        self.availableDestinationUIDs = availableDestinationUIDs
        self.processObjectIDsByBundleID = processObjectIDsByBundleID
    }
}

/// One tap: everything one route needs captured, kept separate from every other
/// route's audio.
///
/// A tap mixes the processes it covers down to stereo. That is why there is one
/// tap per *route* rather than one per destination — two apps sharing a tap
/// would arrive already summed, and per-route volume, mute and delay would be
/// impossible to apply.
public struct TapSpec: Hashable, Sendable {
    public var routeID: Route.ID
    public var appBundleID: String
    public var processObjectIDs: Set<ProcessObjectID>

    public init(
        routeID: Route.ID,
        appBundleID: String,
        processObjectIDs: Set<ProcessObjectID>
    ) {
        self.routeID = routeID
        self.appBundleID = appBundleID
        self.processObjectIDs = processObjectIDs
    }
}

/// One aggregate device's worth of desired state.
///
/// There is exactly one of these per destination device no matter how many apps
/// are routed to it. The apps share the aggregate, its clock and its IOProc —
/// but each gets its own tap, so they arrive as separate input buffers and can
/// be levelled independently before being summed.
///
/// Volume and mute are deliberately *not* part of this type. They are pushed
/// straight to the realtime thread as atomics, so changing a slider never makes
/// the reconciler think the topology changed and rebuild anything.
public struct AggregateSpec: Hashable, Sendable {
    public var destinationDeviceUID: String
    /// Ordered, because the aggregate's input buffers arrive in tap-list order
    /// and the IOProc indexes them positionally.
    public var taps: [TapSpec]

    public init(destinationDeviceUID: String, taps: [TapSpec] = []) {
        self.destinationDeviceUID = destinationDeviceUID
        self.taps = taps
    }

    public var routeIDs: Set<Route.ID> { Set(taps.map(\.routeID)) }

    /// Whether the aggregate itself has to be rebuilt, as opposed to its taps
    /// merely being re-pointed at a different set of processes.
    public func requiresRebuild(comparedTo other: AggregateSpec) -> Bool {
        taps.map(\.routeID) != other.taps.map(\.routeID)
    }
}

/// What the engine should do to make Core Audio match the desired state.
public enum ReconcileAction: Hashable, Sendable {
    /// Build a tap, an aggregate and an IOProc for this destination.
    case create(AggregateSpec)
    /// Keep the aggregate and IOProc; change which processes the tap covers.
    /// Updating in place matters: browser helpers come and go constantly, and
    /// rebuilding the aggregate every time would glitch the audio.
    case update(AggregateSpec)
    /// Tear this destination's aggregate down completely.
    case destroy(destinationDeviceUID: String)

    public var destinationDeviceUID: String {
        switch self {
        case let .create(spec), let .update(spec): spec.destinationDeviceUID
        case let .destroy(uid): uid
        }
    }
}

public struct ReconcileResult: Hashable, Sendable {
    /// Ordered: destroys first, so devices are released before anything claims
    /// them again.
    public var actions: [ReconcileAction]
    public var statuses: [Route.ID: RouteStatus]

    public var isNoOp: Bool { actions.isEmpty }
}

/// Diffs desired routes against live Core Audio state.
///
/// Safe to call on any event — app launch, app quit, device plug or unplug, wake
/// from sleep, user edit, permission grant. Calling it twice with the same
/// inputs produces no actions the second time.
public enum RouteReconciler {
    public static func reconcile(
        _ input: ReconcilerInput,
        live: [String: AggregateSpec]
    ) -> ReconcileResult {
        var statuses: [Route.ID: RouteStatus] = [:]

        // An app can only be tapped by one route. Two taps covering the same
        // process would capture it twice and play it on two destinations at
        // once, which is not a thing the user can have asked for. First route
        // wins, deterministically.
        var claimedBy: [String: Route.ID] = [:]
        var effectiveRoutes: [Route] = []
        for route in input.routes {
            guard route.isEnabled else {
                statuses[route.id] = .disabled
                continue
            }
            if let owner = claimedBy[route.appBundleID] {
                statuses[route.id] = .conflicting(withRouteID: owner)
                continue
            }
            claimedBy[route.appBundleID] = route.id
            effectiveRoutes.append(route)
        }

        // Group the routes that can actually run by destination.
        var desired: [String: AggregateSpec] = [:]
        for route in effectiveRoutes {
            guard input.availableDestinationUIDs.contains(route.destinationDeviceUID) else {
                // The device is gone. The route is not — it comes back when the
                // device does.
                statuses[route.id] = .waitingForDevice
                continue
            }

            let processes = input.processObjectIDsByBundleID[route.appBundleID] ?? []
            guard !processes.isEmpty else {
                statuses[route.id] = .waitingForApp
                continue
            }

            statuses[route.id] = .active
            var spec = desired[route.destinationDeviceUID]
                ?? AggregateSpec(destinationDeviceUID: route.destinationDeviceUID)
            spec.taps.append(TapSpec(
                routeID: route.id,
                appBundleID: route.appBundleID,
                processObjectIDs: processes
            ))
            desired[route.destinationDeviceUID] = spec
        }

        // Sorted throughout so the action list is deterministic and testable.
        var actions: [ReconcileAction] = []
        for uid in live.keys.sorted() where desired[uid] == nil {
            actions.append(.destroy(destinationDeviceUID: uid))
        }
        for uid in desired.keys.sorted() {
            guard let spec = desired[uid] else { continue }
            if let existing = live[uid] {
                if existing != spec { actions.append(.update(spec)) }
            } else {
                actions.append(.create(spec))
            }
        }

        return ReconcileResult(actions: actions, statuses: statuses)
    }
}
