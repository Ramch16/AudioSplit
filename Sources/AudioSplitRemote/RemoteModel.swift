import AudioSplitShared
import Foundation
import Observation

/// State for the phone/iPad remote.
///
/// Holds no routing logic: it renders the Mac's snapshot and forwards intent.
/// Local edits are optimistic only for sliders, where waiting for a round trip
/// would make the control feel broken.
@MainActor
@Observable
final class RemoteModel {
    private(set) var discovered: [RemoteClient.DiscoveredMac] = []
    private(set) var state: RemoteClient.ConnectionState = .idle
    private(set) var snapshot: RemoteSnapshot?

    /// Slider positions being dragged right now, so incoming snapshots do not
    /// yank the thumb out from under the user's finger.
    private var pendingVolumes: [UUID: Float] = [:]
    private var pendingDelays: [UUID: Double] = [:]

    private let client = RemoteClient()

    /// Remembered so returning to the app reconnects without retyping.
    private let codeKey = "AudioSplitPairingCode"
    var pairingCode: String {
        didSet { UserDefaults.standard.set(pairingCode, forKey: codeKey) }
    }

    init() {
        pairingCode = UserDefaults.standard.string(forKey: codeKey) ?? ""
        client.onChange = { [weak self] in
            guard let self else { return }
            discovered = client.discovered
            state = client.state
            snapshot = client.snapshot
        }
        client.startDiscovery()
    }

    var isConnected: Bool { state == .connected }

    var routes: [Route] { snapshot?.routes ?? [] }
    var devices: [RemoteDevice] { snapshot?.devices ?? [] }
    var outputDevices: [RemoteDevice] { devices.filter(\.canOutput) }
    var inputDevices: [RemoteDevice] { devices.filter(\.canInput) }
    var hostName: String { snapshot?.hostName ?? "Mac" }
    var captureLooksBroken: Bool { snapshot?.captureLooksBroken ?? false }

    /// Apps worth offering, minus the ones already routed.
    var routableApps: [AudibleApp] {
        let claimed = Set(routes.map(\.appBundleID))
        return (snapshot?.audibleApps ?? [])
            .filter { $0.isRoutable && !claimed.contains($0.bundleID) }
    }

    func status(for route: Route) -> RouteStatus {
        snapshot?.statuses[route.id] ?? .waitingForApp
    }

    func level(for route: Route) -> Float {
        snapshot?.levels[route.id] ?? 0
    }

    func volume(for route: Route) -> Float {
        pendingVolumes[route.id] ?? route.volume
    }

    func delay(for route: Route) -> Double {
        pendingDelays[route.id] ?? route.delayMilliseconds
    }

    func deviceName(forUID uid: String) -> String {
        devices.first { $0.uid == uid }?.name ?? "Unavailable device"
    }

    // MARK: - Connection

    func rediscover() { client.startDiscovery() }

    func connect(to mac: RemoteClient.DiscoveredMac) {
        client.connect(to: mac, pairingCode: pairingCode)
    }

    func disconnect() { client.disconnect() }

    // MARK: - Commands

    func setVolume(_ volume: Float, for route: Route) {
        pendingVolumes[route.id] = volume
        client.send(.setVolume(id: route.id, volume: volume))
    }

    func commitVolume(for route: Route) { pendingVolumes[route.id] = nil }

    func setDelay(_ milliseconds: Double, for route: Route) {
        pendingDelays[route.id] = milliseconds
        client.send(.setDelay(id: route.id, milliseconds: milliseconds))
    }

    func commitDelay(for route: Route) { pendingDelays[route.id] = nil }

    func setMuted(_ muted: Bool, for route: Route) {
        client.send(.setMuted(id: route.id, muted: muted))
    }

    func setEnabled(_ enabled: Bool, for route: Route) {
        client.send(.setEnabled(id: route.id, enabled: enabled))
    }

    func setDestination(_ uid: String, for route: Route) {
        client.send(.setDestination(id: route.id, deviceUID: uid))
    }

    func remove(_ route: Route) {
        client.send(.removeRoute(id: route.id))
    }

    func addRoute(app: AudibleApp, destinationUID: String) {
        client.send(.addRoute(
            bundleID: app.bundleID,
            displayName: app.displayName,
            destinationUID: destinationUID
        ))
    }

    func setDefaultOutput(_ uid: String) { client.send(.setDefaultOutput(deviceUID: uid)) }
    func setDefaultInput(_ uid: String) { client.send(.setDefaultInput(deviceUID: uid)) }
    func setDeviceVolume(_ volume: Float, uid: String) {
        client.send(.setDeviceVolume(deviceUID: uid, volume: volume))
    }
    func setDeviceMuted(_ muted: Bool, uid: String) {
        client.send(.setDeviceMuted(deviceUID: uid, muted: muted))
    }
    func restoreAllAudio() { client.send(.restoreAllAudio) }
}
