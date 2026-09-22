import AppKit
import AudioSplitEngine
import AudioSplitShared
import Foundation
import Observation

/// Owns the route list, the engine, and every event that can invalidate routing.
///
/// The UI never touches Core Audio. It edits routes; this reconciles.
@MainActor
@Observable
final class AppModel {
    private(set) var routes: [Route] = []
    private(set) var statuses: [Route.ID: RouteStatus] = [:]
    private(set) var outputDevices: [AudioDeviceInfo] = []
    private(set) var inputDevices: [AudioDeviceInfo] = []
    private(set) var defaultInputUID: String?
    private(set) var defaultOutputUID: String?
    /// Per-device volume and mute, keyed by device UID.
    private(set) var deviceControls: [String: DeviceControlState] = [:]
    private(set) var preferences = Preferences()
    private(set) var hotKeyFailed = false
    private(set) var remoteClientCount = 0
    private(set) var remoteError: String?
    private(set) var audibleApps: [AudibleApp] = []
    private(set) var levels: [Route.ID: Float] = [:]
    private(set) var lastError: String?

    /// True once a route has been active long enough to have moved audio. Used
    /// to distinguish "nothing is playing" from "permission was never granted".
    private(set) var hasEverRenderedAudio = false
    /// Consecutive meter ticks where an app was audibly playing but its route
    /// captured nothing.
    private var silentWhilePlayingTicks = 0

    private let engine = RouteEngine()
    private let store = Store()
    private let processController = AudioProcessController()
    private let deviceStore = DeviceStore()
    private var meterTimer: Timer?
    private var deviceTimer: Timer?

    /// What a device itself can do, independent of any routing.
    struct DeviceControlState: Equatable {
        var volume: Float?
        var isMuted: Bool
        var canSetVolume: Bool
        var canMute: Bool
    }
    private let hotKeyMonitor = HotKeyMonitor()
    private let remoteServer = RemoteServer()

    /// Our own bundle ID — routing AudioSplit through itself would be a loop.
    private let ownBundleID = Bundle.main.bundleIdentifier ?? "com.audiosplit.AudioSplit"

    init() {
        do {
            let document = try store.load()
            routes = document.routes
            preferences = document.preferences
            Diagnostics.log("loaded \(routes.count) route(s) from \(store.fileURL.path)")
        } catch {
            lastError = String(describing: error)
        }
        start()
    }

    // MARK: - Wiring

    private func start() {
        refreshInventory()

        processController.onProcessListChanged = { [weak self] in
            self?.refreshInventory()
            self?.reconcile()
        }
        deviceStore.onDevicesChanged = { [weak self] in
            self?.refreshInventory()
            self?.reconcile()
        }
        deviceStore.onDefaultInputChanged = { [weak self] in
            self?.refreshInventory()
        }
        deviceStore.onDefaultOutputChanged = { [weak self] in
            self?.refreshInventory()
        }

        do {
            try processController.startObserving()
            try deviceStore.startObserving()
        } catch {
            lastError = String(describing: error)
        }

        // Sleep invalidates device state; everything has to be re-established.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reconcile() }
        }

        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshLevels() }
        }
        // Device volume can be changed from anywhere — the Sound pane, a
        // keyboard key, another app. Poll slowly so the UI stays truthful
        // without hammering the HAL.
        deviceTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDeviceControls() }
        }

        applyHotKey()

        remoteServer.onCommand = { [weak self] command in
            self?.handle(command)
        }
        remoteServer.onClientsChanged = { [weak self] count in
            self?.remoteClientCount = count
        }
        applyRemoteSetting()

        reconcile()
    }

    // MARK: - iPhone / iPad remote
    //
    // The remote renders state and sends intent; every decision stays here on
    // the Mac. That is not a simplification — iOS has no Core Audio HAL, so a
    // phone physically cannot run the engine.

    var isRemoteEnabled: Bool { preferences.isRemoteEnabled }
    var pairingCode: String { preferences.pairingCode }
    var isRemoteRunning: Bool { remoteServer.isRunning }

    func setRemoteEnabled(_ enabled: Bool) {
        preferences.isRemoteEnabled = enabled
        if enabled, preferences.pairingCode.isEmpty {
            preferences.pairingCode = RemoteServer.generatePairingCode()
        }
        persist()
        applyRemoteSetting()
    }

    /// Issue a new code. Any connected remote drops immediately, which is the
    /// point — this is how you revoke a device you no longer trust.
    func regeneratePairingCode() {
        preferences.pairingCode = RemoteServer.generatePairingCode()
        persist()
        applyRemoteSetting()
    }

    private func applyRemoteSetting() {
        remoteServer.stop()
        remoteClientCount = 0
        guard preferences.isRemoteEnabled else {
            remoteError = nil
            return
        }
        do {
            try remoteServer.start(
                pairingCode: preferences.pairingCode,
                serviceName: Host.current().localizedName ?? "Mac"
            )
            remoteError = nil
            Diagnostics.log("remote listening, pairing code \(preferences.pairingCode)")
        } catch {
            remoteError = "Could not start the remote: \(error)"
            Diagnostics.log("remote failed to start: \(error)")
        }
    }

    /// Apply a command from a remote. Each case routes to the same method the
    /// local UI calls, so a remote can never do something the Mac's own
    /// interface cannot.
    private func handle(_ command: RemoteCommand) {
        func route(_ id: UUID) -> Route? { routes.first { $0.id == id } }

        switch command {
        case let .addRoute(bundleID, displayName, destinationUID):
            addRoute(
                app: AudibleApp(
                    bundleID: bundleID,
                    displayName: displayName,
                    isProducingOutput: false,
                    processCount: 0,
                    isRoutable: true
                ),
                destinationUID: destinationUID
            )
        case let .removeRoute(id):
            if let route = route(id) { remove(route) }
        case let .setDestination(id, uid):
            if let route = route(id) { setDestination(uid, for: route) }
        case let .setVolume(id, volume):
            if let route = route(id) { setVolume(volume, for: route); commitParameters() }
        case let .setMuted(id, muted):
            if let route = route(id) { setMuted(muted, for: route) }
        case let .setDelay(id, milliseconds):
            if let route = route(id) { setDelay(milliseconds, for: route); commitParameters() }
        case let .setEnabled(id, enabled):
            if let route = route(id) { setEnabled(enabled, for: route) }
        case let .setDefaultOutput(uid):
            setDefaultOutput(uid: uid)
        case let .setDefaultInput(uid):
            setDefaultInput(uid: uid)
        case let .setDeviceVolume(uid, volume):
            if let device = device(withUID: uid) { setDeviceVolume(volume, for: device) }
        case let .setDeviceMuted(uid, muted):
            if let device = device(withUID: uid) { setDeviceMuted(muted, for: device) }
        case .toggleInput:
            toggleInput()
        case .restoreAllAudio:
            restoreAllAudio()
        }
        broadcastToRemotes()
    }

    private func device(withUID uid: String) -> AudioDeviceInfo? {
        (outputDevices + inputDevices).first { $0.uid == uid }
    }

    private func broadcastToRemotes() {
        guard remoteServer.isRunning, remoteClientCount > 0 else { return }

        let remoteDevices = (outputDevices + inputDevices).map { device -> RemoteDevice in
            let control = control(for: device)
            return RemoteDevice(
                uid: device.uid,
                name: device.name,
                transport: device.transportDescription,
                canOutput: device.canOutput,
                canInput: device.canInput,
                isDefaultOutput: device.uid == defaultOutputUID,
                isDefaultInput: device.uid == defaultInputUID,
                volume: control.volume,
                isMuted: control.isMuted,
                canSetVolume: control.canSetVolume,
                canMute: control.canMute
            )
        }

        remoteServer.broadcast(RemoteSnapshot(
            hostName: Host.current().localizedName ?? "Mac",
            routes: routes,
            statuses: statuses,
            levels: levels,
            devices: remoteDevices,
            audibleApps: audibleApps,
            preferences: preferences,
            captureLooksBroken: mayBeMissingPermission
        ))
    }

    func refreshInventory() {
        do {
            outputDevices = try DeviceStore.outputDevices().filter { !$0.isAggregate }
            inputDevices = try DeviceStore.inputDevices().filter { !$0.isAggregate }
            defaultInputUID = try DeviceStore.defaultInputDeviceID()
                .flatMap { DeviceStore.info(for: $0)?.uid }
            defaultOutputUID = try DeviceStore.defaultOutputDeviceID()
                .flatMap { DeviceStore.info(for: $0)?.uid }
            refreshDeviceControls()
            audibleApps = try AudioProcessController.audibleApps(
                excludingBundleIDs: [ownBundleID],
                // The milestone harnesses ship their own bundle IDs, so a plain
                // self-exclusion would still list our own test rigs as routable.
                excludingPrefixes: ["com.audiosplit."]
            )
        } catch {
            lastError = String(describing: error)
        }
    }

    // MARK: - Device control

    private func refreshDeviceControls() {
        var next: [String: DeviceControlState] = [:]
        for device in outputDevices + inputDevices where next[device.uid] == nil {
            next[device.uid] = DeviceControlState(
                volume: DeviceStore.volume(of: device),
                isMuted: DeviceStore.isMuted(of: device) ?? false,
                canSetVolume: DeviceStore.canSetVolume(of: device),
                canMute: DeviceStore.canMute(of: device)
            )
        }
        deviceControls = next
    }

    func control(for device: AudioDeviceInfo) -> DeviceControlState {
        deviceControls[device.uid]
            ?? DeviceControlState(volume: nil, isMuted: false, canSetVolume: false, canMute: false)
    }

    func setDefaultOutput(uid: String) {
        do {
            try DeviceStore.setDefaultOutputDevice(uid: uid)
            defaultOutputUID = uid
            Diagnostics.log("default output -> \(deviceName(forUID: uid))")
        } catch {
            lastError = "Could not switch output: \(error)"
        }
    }

    func setDeviceVolume(_ volume: Float, for device: AudioDeviceInfo) {
        // Update locally first so the slider tracks the drag rather than the
        // one-second poll.
        deviceControls[device.uid]?.volume = volume
        do {
            try DeviceStore.setVolume(volume, of: device)
        } catch {
            lastError = "Could not set \(device.name) volume: \(error)"
        }
    }

    func setDeviceMuted(_ muted: Bool, for device: AudioDeviceInfo) {
        deviceControls[device.uid]?.isMuted = muted
        do {
            try DeviceStore.setMuted(muted, of: device)
        } catch {
            lastError = "Could not mute \(device.name): \(error)"
        }
    }

    /// Routes currently pointed at a device, for the device list.
    func routes(toDeviceUID uid: String) -> [Route] {
        routes.filter { $0.destinationDeviceUID == uid }
    }

    /// Live engine state, for the activity view.
    var liveAggregates: [LiveAggregate] { engine.liveAggregates }

    // MARK: - Input device

    func setDefaultInput(uid: String) {
        do {
            try DeviceStore.setDefaultInputDevice(uid: uid)
            defaultInputUID = uid
            Diagnostics.log("default input -> \(inputDeviceName(forUID: uid))")
        } catch {
            lastError = "Could not switch input: \(error)"
        }
    }

    /// Flip the system input between the two configured devices.
    func toggleInput() {
        guard let next = preferences.nextInputUID(currentUID: defaultInputUID) else {
            lastError = "Pick two input devices to toggle between first."
            return
        }
        setDefaultInput(uid: next)
    }

    func setInputTogglePair(_ uids: [String]) {
        preferences.inputToggleDeviceUIDs = uids
        persist()
    }

    func setHotKeyEnabled(_ enabled: Bool) {
        preferences.inputToggleHotKey.isEnabled = enabled
        persist()
        applyHotKey()
    }

    private func applyHotKey() {
        let succeeded = hotKeyMonitor.register(preferences.inputToggleHotKey) { [weak self] in
            self?.toggleInput()
        }
        hotKeyFailed = !succeeded
        let binding = preferences.inputToggleHotKey
        if !succeeded {
            Diagnostics.log("could not register \(binding.displayString) — another app owns it")
        } else if binding.isEnabled {
            Diagnostics.log("registered hotkey \(binding.displayString) for input toggle")
        }
    }

    func inputDeviceName(forUID uid: String) -> String {
        inputDevices.first { $0.uid == uid }?.name ?? "Unavailable device"
    }

    func reconcile() {
        do {
            let (result, failures) = try engine.reconcile(routes: routes)
            statuses = result.statuses
            for action in result.actions { Diagnostics.log(describe(action)) }
            for failure in failures {
                Diagnostics.log("failed \(failure.destinationDeviceUID): \(failure.message)")
            }
            lastError = failures.first.map { "\($0.destinationDeviceUID): \($0.message)" }
            broadcastToRemotes()
        } catch {
            Diagnostics.log("reconcile error: \(error)")
            lastError = String(describing: error)
        }
    }

    private func describe(_ action: ReconcileAction) -> String {
        switch action {
        case let .create(spec):
            "create \(deviceName(forUID: spec.destinationDeviceUID)) — "
                + spec.taps.map(\.appBundleID).joined(separator: " + ")
        case let .update(spec):
            "update \(deviceName(forUID: spec.destinationDeviceUID)) — "
                + spec.taps.map(\.appBundleID).joined(separator: " + ")
        case let .destroy(uid):
            "destroy \(deviceName(forUID: uid))"
        }
    }

    private func refreshLevels() {
        var next: [Route.ID: Float] = [:]
        for route in routes {
            guard let peak = engine.peak(forRouteID: route.id) else { continue }
            next[route.id] = peak
            if peak > 0 { hasEverRenderedAudio = true }
        }
        levels = next

        // The only honest signal for a failed capture: the HAL says the app is
        // producing output, its route is live, and our tap still hands us
        // nothing. A route that is merely idle must not trigger this.
        let playing = Set(appsPlayingNow.map(\.bundleID))
        let capturedNothing = routes.contains { route in
            status(for: route) == .active
                && playing.contains(route.appBundleID)
                && (next[route.id] ?? 0) == 0
        }
        silentWhilePlayingTicks = capturedNothing ? silentWhilePlayingTicks + 1 : 0

        broadcastToRemotes()
    }

    // MARK: - Editing

    private func persist() {
        do {
            try store.save(routes, preferences: preferences)
        } catch {
            lastError = "Could not save routes: \(error)"
        }
    }

    /// Apply an edit, save it, and make the hardware match.
    private func mutate(_ change: () -> Void) {
        change()
        persist()
        reconcile()
    }

    func addRoute(app: AudibleApp, destinationUID: String) {
        mutate {
            routes.append(Route(
                appBundleID: app.bundleID,
                appDisplayName: app.displayName,
                destinationDeviceUID: destinationUID
            ))
        }
    }

    func remove(_ route: Route) {
        mutate { routes.removeAll { $0.id == route.id } }
    }

    func setDestination(_ uid: String, for route: Route) {
        mutate { update(route) { $0.destinationDeviceUID = uid } }
    }

    func setEnabled(_ enabled: Bool, for route: Route) {
        mutate { update(route) { $0.isEnabled = enabled } }
    }

    func setMuted(_ muted: Bool, for route: Route) {
        mutate { update(route) { $0.isMuted = muted } }
    }

    /// Volume is special: it must not go through `reconcile`.
    ///
    /// Gain is pushed straight to the realtime thread as an atomic, so dragging
    /// a slider costs nothing. Routing it through reconciliation would have the
    /// engine re-examine the whole topology on every frame of the drag.
    func setVolume(_ volume: Float, for route: Route) {
        update(route) { $0.volume = volume }
        engine.applyParameters(routes: routes)
    }

    /// Delay is pushed the same lock-free way as volume — the realtime thread
    /// only ever reads a frame count, and changing it moves a read offset.
    func setDelay(_ milliseconds: Double, for route: Route) {
        update(route) { $0.delayMilliseconds = milliseconds }
        engine.applyParameters(routes: routes)
    }

    /// Call when a slider drag finishes.
    func commitParameters() { persist() }

    private func update(_ route: Route, _ change: (inout Route) -> Void) {
        guard let index = routes.firstIndex(where: { $0.id == route.id }) else { return }
        change(&routes[index])
    }

    // MARK: - Recovery

    /// Destroy every tap and aggregate we own, putting all audio back to normal.
    func restoreAllAudio() {
        let problems = engine.stopAll()
        lastError = problems.first
        statuses = [:]
        levels = [:]
    }

    /// Restore normal audio and re-apply the routes.
    func restartRouting() {
        engine.stopAll()
        reconcile()
    }

    func quit() {
        engine.stopAll()
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Derived state for the UI

    func status(for route: Route) -> RouteStatus {
        statuses[route.id] ?? (route.isEnabled ? .waitingForApp : .disabled)
    }

    func level(for route: Route) -> Float {
        levels[route.id] ?? 0
    }

    func deviceName(forUID uid: String) -> String {
        outputDevices.first { $0.uid == uid }?.name ?? "Unavailable device"
    }

    /// Apps that could be routed and are not already.
    var routableApps: [AudibleApp] {
        let claimed = Set(routes.map(\.appBundleID))
        return audibleApps.filter { $0.isRoutable && !claimed.contains($0.bundleID) }
    }

    /// Apps making a sound this instant — what someone opening Activity is
    /// actually looking for.
    var appsPlayingNow: [AudibleApp] {
        audibleApps.filter(\.isProducingOutput)
    }

    /// Everything else that holds an audio process but is silent. Long, and
    /// mostly uninteresting, so the UI keeps it collapsed.
    var idleAudioApps: [AudibleApp] {
        audibleApps.filter { !$0.isProducingOutput && $0.isRoutable }
    }

    /// True when an app is audibly playing but its route captures silence.
    ///
    /// A tap with no audio-capture permission succeeds, runs, and delivers pure
    /// silence — there is no error to report anywhere, so this inference is the
    /// only signal available. It needs roughly two seconds of the condition
    /// holding before it will say so, because a stream starting up legitimately
    /// produces a few empty buffers.
    var mayBeMissingPermission: Bool {
        !hasEverRenderedAudio && silentWhilePlayingTicks > 20
    }
}
