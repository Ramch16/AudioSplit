import Foundation
import Testing

@testable import AudioSplitEngine

// The reconciler is the one part of the engine that can be tested exhaustively
// without hardware, permissions, or the risk of leaving devices behind. These
// tests are the safety net for every event that can perturb routing: apps
// starting and stopping, devices appearing and disappearing, sleep/wake, and
// the user editing routes.

private let speakers = "BuiltInSpeakerDevice"
private let airpods = "AirPods:output"

private func route(
    _ bundleID: String,
    to destination: String,
    enabled: Bool = true,
    id: UUID = UUID()
) -> Route {
    Route(
        id: id,
        appBundleID: bundleID,
        appDisplayName: bundleID,
        destinationDeviceUID: destination,
        isEnabled: enabled
    )
}

private func input(
    _ routes: [Route],
    devices: Set<String> = [speakers, airpods],
    processes: [String: Set<ProcessObjectID>] = [:]
) -> ReconcilerInput {
    ReconcilerInput(
        routes: routes,
        availableDestinationUIDs: devices,
        processObjectIDsByBundleID: processes
    )
}

private func spec(
    _ destination: String,
    _ taps: (route: Route, processes: Set<ProcessObjectID>)...
) -> AggregateSpec {
    AggregateSpec(
        destinationDeviceUID: destination,
        taps: taps.map {
            TapSpec(
                routeID: $0.route.id,
                appBundleID: $0.route.appBundleID,
                processObjectIDs: $0.processes
            )
        }
    )
}

@Suite("RouteReconciler")
struct RouteReconcilerTests {
    @Test("no routes and no live state does nothing")
    func emptyIsNoOp() {
        let result = RouteReconciler.reconcile(input([]), live: [:])
        #expect(result.isNoOp)
        #expect(result.statuses.isEmpty)
    }

    @Test("a runnable route creates one aggregate")
    func createsAggregate() {
        let safari = route("com.apple.Safari", to: speakers)
        let result = RouteReconciler.reconcile(
            input([safari], processes: ["com.apple.Safari": [10, 11]]),
            live: [:]
        )
        #expect(result.actions == [
            .create(spec(speakers, (safari, [10, 11]))),
        ])
        #expect(result.statuses[safari.id] == .active)
    }

    @Test("reconciling against the state it just asked for is a no-op")
    func isIdempotent() {
        let safari = route("com.apple.Safari", to: speakers)
        let state = input([safari], processes: ["com.apple.Safari": [10, 11]])

        let first = RouteReconciler.reconcile(state, live: [:])
        guard case let .create(spec) = first.actions.first else {
            Issue.record("expected a create")
            return
        }

        let second = RouteReconciler.reconcile(state, live: [speakers: spec])
        #expect(second.isNoOp)

        // And a third time, to be sure nothing accumulates.
        let third = RouteReconciler.reconcile(state, live: [speakers: spec])
        #expect(third.isNoOp)
    }

    @Test("a route whose app is not running is kept, not discarded")
    func keepsRouteWhenAppNotRunning() {
        let safari = route("com.apple.Safari", to: speakers)
        let result = RouteReconciler.reconcile(input([safari]), live: [:])

        #expect(result.actions.isEmpty)
        #expect(result.statuses[safari.id] == .waitingForApp)
    }

    @Test("an app quitting tears its aggregate down but leaves the route")
    func destroysAggregateWhenAppQuits() {
        let safari = route("com.apple.Safari", to: speakers)
        let live = [speakers: spec(speakers, (safari, [10]))]

        let result = RouteReconciler.reconcile(input([safari]), live: live)
        #expect(result.actions == [.destroy(destinationDeviceUID: speakers)])
        #expect(result.statuses[safari.id] == .waitingForApp)
    }

    @Test("an unplugged device parks the route instead of dropping it")
    func handlesDeviceDisappearing() {
        let music = route("com.apple.Music", to: airpods)
        let live = [airpods: spec(airpods, (music, [20]))]

        let result = RouteReconciler.reconcile(
            input([music], devices: [speakers], processes: ["com.apple.Music": [20]]),
            live: live
        )
        #expect(result.actions == [.destroy(destinationDeviceUID: airpods)])
        #expect(result.statuses[music.id] == .waitingForDevice)
    }

    @Test("the route comes back when the device is plugged in again")
    func recoversWhenDeviceReturns() {
        let music = route("com.apple.Music", to: airpods)
        let state = input([music], processes: ["com.apple.Music": [20]])

        let result = RouteReconciler.reconcile(state, live: [:])
        #expect(result.actions == [
            .create(spec(airpods, (music, [20]))),
        ])
        #expect(result.statuses[music.id] == .active)
    }

    @Test("apps sharing a destination share one aggregate and one tap")
    func sharesAggregatePerDestination() {
        let safari = route("com.apple.Safari", to: speakers)
        let music = route("com.apple.Music", to: speakers)

        let result = RouteReconciler.reconcile(
            input(
                [safari, music],
                processes: ["com.apple.Safari": [10], "com.apple.Music": [20, 21]]
            ),
            live: [:]
        )

        // One aggregate, but a tap each — they must stay separable so volume,
        // mute and delay can be applied per route.
        #expect(result.actions == [
            .create(spec(speakers, (safari, [10]), (music, [20, 21]))),
        ])
    }

    @Test("two destinations means two aggregates")
    func oneAggregatePerDestination() {
        let safari = route("com.apple.Safari", to: speakers)
        let zoom = route("us.zoom.xos", to: airpods)

        let result = RouteReconciler.reconcile(
            input([safari, zoom], processes: ["com.apple.Safari": [10], "us.zoom.xos": [30]]),
            live: [:]
        )

        #expect(result.actions.count == 2)
        #expect(Set(result.actions.map(\.destinationDeviceUID)) == [speakers, airpods])
    }

    @Test("a helper process appearing updates the tap instead of rebuilding it")
    func updatesProcessesInPlace() {
        let chrome = route("com.google.Chrome", to: speakers)
        let live = [speakers: spec(speakers, (chrome, [40]))]

        let result = RouteReconciler.reconcile(
            input([chrome], processes: ["com.google.Chrome": [40, 41]]),
            live: live
        )

        #expect(result.actions == [
            .update(spec(speakers, (chrome, [40, 41]))),
        ])
    }

    @Test("disabling a route tears it down and records why")
    func disabledRouteIsTornDown() {
        let safari = route("com.apple.Safari", to: speakers, enabled: false)
        let live = [speakers: spec(speakers, (safari, [10]))]

        let result = RouteReconciler.reconcile(
            input([safari], processes: ["com.apple.Safari": [10]]),
            live: live
        )
        #expect(result.actions == [.destroy(destinationDeviceUID: speakers)])
        #expect(result.statuses[safari.id] == .disabled)
    }

    @Test("deleting a route destroys its aggregate")
    func deletedRouteIsDestroyed() {
        let live = [speakers: spec(speakers, (route("gone", to: speakers), [10]))]
        let result = RouteReconciler.reconcile(input([]), live: live)
        #expect(result.actions == [.destroy(destinationDeviceUID: speakers)])
    }

    @Test("the same app routed twice keeps the first route and flags the second")
    func duplicateBundleIDConflicts() {
        let first = route("com.apple.Safari", to: speakers)
        let second = route("com.apple.Safari", to: airpods)

        let result = RouteReconciler.reconcile(
            input([first, second], processes: ["com.apple.Safari": [10]]),
            live: [:]
        )

        #expect(result.statuses[first.id] == .active)
        #expect(result.statuses[second.id] == .conflicting(withRouteID: first.id))
        #expect(result.actions == [.create(spec(speakers, (first, [10])))])
    }

    @Test("moving an app to another device destroys before it creates")
    func destroyOrderedBeforeCreate() {
        let safari = route("com.apple.Safari", to: airpods)
        let live = [speakers: spec(speakers, (safari, [10]))]

        let result = RouteReconciler.reconcile(
            input([safari], processes: ["com.apple.Safari": [10]]),
            live: live
        )

        #expect(result.actions.count == 2)
        #expect(result.actions[0] == .destroy(destinationDeviceUID: speakers))
        if case .create = result.actions[1] {} else {
            Issue.record("expected the create to come second")
        }
    }

    @Test("apps sharing a destination each get their own tap")
    func separateTapPerRoute() {
        let safari = route("com.apple.Safari", to: speakers)
        let zoom = route("us.zoom.xos", to: speakers)

        let result = RouteReconciler.reconcile(
            input([safari, zoom], processes: ["com.apple.Safari": [10], "us.zoom.xos": [20]]),
            live: [:]
        )

        guard case let .create(created) = result.actions.first else {
            Issue.record("expected a create")
            return
        }
        // Two taps, not one merged tap. A tap mixes its processes to stereo, so
        // merging would make per-route volume impossible.
        #expect(created.taps.count == 2)
        #expect(created.taps.map(\.routeID) == [safari.id, zoom.id])
        #expect(created.taps[0].processObjectIDs == [10])
        #expect(created.taps[1].processObjectIDs == [20])
    }

    @Test("changing volume or mute produces no reconciler actions")
    func volumeIsNotTopology() {
        var safari = route("com.apple.Safari", to: speakers)
        let processes = ["com.apple.Safari": Set<ProcessObjectID>([10])]
        let live = [speakers: spec(speakers, (safari, [10]))]

        safari.volume = 0.25
        safari.isMuted = true

        // Volume and mute go straight to the realtime thread as atomics. If they
        // leaked into the aggregate's identity, every slider movement would tear
        // down and rebuild the audio path.
        let result = RouteReconciler.reconcile(input([safari], processes: processes), live: live)
        #expect(result.isNoOp)
    }

    @Test("re-pointing a tap is an update, adding a route is a rebuild")
    func rebuildOnlyWhenRouteSetChanges() {
        let safari = route("com.apple.Safari", to: speakers)
        let zoom = route("us.zoom.xos", to: speakers)

        let oneRoute = spec(speakers, (safari, [10]))
        let sameRouteMoreProcesses = spec(speakers, (safari, [10, 11]))
        let twoRoutes = spec(speakers, (safari, [10]), (zoom, [20]))

        #expect(!sameRouteMoreProcesses.requiresRebuild(comparedTo: oneRoute))
        #expect(twoRoutes.requiresRebuild(comparedTo: oneRoute))
    }

    @Test("muting a route does not remove its tap")
    func mutedRouteStaysLive() {
        var safari = route("com.apple.Safari", to: speakers)
        safari.isMuted = true

        let result = RouteReconciler.reconcile(
            input([safari], processes: ["com.apple.Safari": [10]]),
            live: [:]
        )
        // Mute is a gain of zero on the realtime thread, not a teardown — so
        // unmuting is instant and does not re-trigger the TCC/aggregate dance.
        #expect(result.actions == [.create(spec(speakers, (safari, [10])))])
        #expect(result.statuses[safari.id] == .active)
    }

    @Test("action order is stable across repeated runs")
    func actionOrderIsDeterministic() {
        let routes = (0 ..< 8).map { index in
            route("app.\(index)", to: index.isMultiple(of: 2) ? speakers : airpods)
        }
        let processes = Dictionary(
            uniqueKeysWithValues: routes.enumerated().map {
                ($0.element.appBundleID, Set([ProcessObjectID($0.offset + 100)]))
            }
        )
        let state = input(routes, processes: processes)

        let first = RouteReconciler.reconcile(state, live: [:])
        for _ in 0 ..< 20 {
            #expect(RouteReconciler.reconcile(state, live: [:]).actions == first.actions)
        }
    }
}

@Suite("Store")
struct StoreTests {
    private func temporaryStore() -> Store {
        Store(fileURL: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("audiosplit-tests-\(UUID().uuidString)")
            .appendingPathComponent("routes.json"))
    }

    @Test("a first run with no file starts empty")
    func missingFileIsEmpty() throws {
        #expect(try temporaryStore().load().routes.isEmpty)
    }

    @Test("routes survive a save and load round trip")
    func roundTrips() throws {
        let store = temporaryStore()
        let saved = [
            Route(
                appBundleID: "com.apple.Safari",
                appDisplayName: "Safari",
                destinationDeviceUID: "BuiltInSpeakerDevice",
                volume: 0.4,
                isMuted: true
            ),
            Route(
                appBundleID: "com.apple.Music",
                appDisplayName: "Music",
                destinationDeviceUID: "AirPods:output",
                isEnabled: false
            ),
        ]
        try store.save(saved)

        let loaded = try store.load().routes
        #expect(loaded == saved)
        #expect(loaded[0].volume == 0.4)
        #expect(loaded[0].isMuted)
        #expect(loaded[1].isEnabled == false)
    }

    @Test("a file written before volume existed still loads")
    func decodesLegacyFile() throws {
        let store = temporaryStore()
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let legacy = """
        {"version":1,"routes":[{"id":"\(UUID().uuidString)",
        "appBundleID":"com.apple.Safari","appDisplayName":"Safari",
        "destinationDeviceUID":"BuiltInSpeakerDevice"}]}
        """
        try Data(legacy.utf8).write(to: store.fileURL)

        let loaded = try store.load().routes
        #expect(loaded.count == 1)
        #expect(loaded[0].volume == 1)
        #expect(loaded[0].isMuted == false)
        #expect(loaded[0].isEnabled)
        #expect(loaded[0].delayMilliseconds == 0)
    }

    @Test("delay and preferences round trip")
    func persistsDelayAndPreferences() throws {
        let store = temporaryStore()
        let route = Route(
            appBundleID: "com.apple.Safari",
            appDisplayName: "Safari",
            destinationDeviceUID: "BuiltInSpeakerDevice",
            delayMilliseconds: 180
        )
        let preferences = Preferences(
            inputToggleDeviceUIDs: ["BuiltInMicrophoneDevice", "AirPods:input"],
            inputToggleHotKey: HotKeyBinding(keyCode: 34, modifiers: 0x1900, isEnabled: true)
        )
        try store.save([route], preferences: preferences)

        let document = try store.load()
        #expect(document.routes.first?.delayMilliseconds == 180)
        #expect(document.preferences == preferences)
    }

    @Test("the input toggle alternates and recovers from a third device")
    func inputToggleChoosesNextDevice() {
        let preferences = Preferences(inputToggleDeviceUIDs: ["built-in", "airpods"])

        #expect(preferences.nextInputUID(currentUID: "built-in") == "airpods")
        #expect(preferences.nextInputUID(currentUID: "airpods") == "built-in")
        // Currently on neither of the pair: go somewhere useful rather than nowhere.
        #expect(preferences.nextInputUID(currentUID: "usb-mic") == "airpods")
        #expect(preferences.nextInputUID(currentUID: nil) == "airpods")
        // Not configured yet.
        #expect(Preferences().nextInputUID(currentUID: "built-in") == nil)
    }

    @Test("the same input device in both slots is not a valid toggle")
    func rejectsDuplicateTogglePair() {
        // Seen in a real preferences file: both slots holding one device. The
        // hotkey reported itself as enabled and did nothing when pressed.
        let duplicate = Preferences(inputToggleDeviceUIDs: ["airpods", "airpods"])
        #expect(!duplicate.hasValidTogglePair)
        #expect(duplicate.nextInputUID(currentUID: "airpods") == nil)

        let empty = Preferences(inputToggleDeviceUIDs: ["airpods", ""])
        #expect(!empty.hasValidTogglePair)
        #expect(empty.nextInputUID(currentUID: "airpods") == nil)

        let valid = Preferences(inputToggleDeviceUIDs: ["built-in", "airpods"])
        #expect(valid.hasValidTogglePair)
        #expect(valid.nextInputUID(currentUID: "built-in") == "airpods")
    }

    @Test("an unreadable file is moved aside rather than lost")
    func quarantinesCorruptFile() throws {
        let store = temporaryStore()
        try FileManager.default.createDirectory(
            at: store.fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("this is not json".utf8).write(to: store.fileURL)

        #expect(throws: Store.StoreError.self) { try store.load() }
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))

        let siblings = try FileManager.default.contentsOfDirectory(
            atPath: store.fileURL.deletingLastPathComponent().path
        )
        #expect(siblings.contains { $0.contains("corrupt") })
    }
}
