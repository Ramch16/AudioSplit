import AppKit
import AudioSplitEngine
import AudioSplitShared
import CoreAudio
import Foundation

// M3 harness: N routes to N destinations, driven by the reconciler, reacting to
// apps and devices coming and going. Exists to prove lifecycle and teardown.

setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())

if arguments.contains("--help") || arguments.contains("-h") || arguments.isEmpty {
    print("""
    audiosplit-m3 — AudioSplit M3 engine harness

    USAGE:
      audiosplit-m3 --route <bundle id>=<device> [--route ...]
      audiosplit-m3 --churn <n> --route <bundle id>=<device> [--route ...]
      audiosplit-m3 --orphans

    OPTIONS:
      --route   A route, repeatable. Device matches on UID or name substring,
                e.g. --route com.apple.Safari="MacBook Pro Speakers"
      --churn   Create and destroy every route n times as fast as possible,
                then report anything left behind.
      --orphans List aggregate devices owned by AudioSplit and exit.

    Reconciles on app start/stop, device plug/unplug and wake from sleep.
    Ctrl-C tears everything down.
    """)
    exit(0)
}

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

func padded(_ text: String, _ width: Int) -> String {
    let limit = width - 1
    guard text.count > limit else {
        return text + String(repeating: " ", count: width - text.count)
    }
    return String(text.prefix(limit - 1)) + "\u{2026} "
}

// MARK: - Orphan scanning

/// Aggregate devices carrying AudioSplit's UID prefix.
///
/// Note that AudioSplit's aggregates are private, so this only ever sees the
/// ones this process owns — which is exactly what makes it a teardown check.
@MainActor
func audioSplitAggregates() throws -> [AudioDeviceInfo] {
    try DeviceStore.allDevices().filter {
        AudioSplitIdentifiers.isAudioSplitAggregate(uid: $0.uid)
    }
}

/// Wait for AudioSplit's aggregates to disappear from the device list.
///
/// `AudioHardwareDestroyAggregateDevice` returns success well before the HAL
/// removes the device from `kAudioHardwarePropertyDevices`. Scanning
/// immediately after teardown therefore reports a device that is already dead.
/// Poll instead of trusting a single read.
@MainActor
func waitForTeardown(timeout: TimeInterval = 2) throws -> [AudioDeviceInfo] {
    let deadline = Date().addingTimeInterval(timeout)
    var remaining = try audioSplitAggregates()
    while !remaining.isEmpty, Date() < deadline {
        usleep(20_000)
        remaining = try audioSplitAggregates()
    }
    return remaining
}

if arguments.contains("--orphans") {
    let orphans = try audioSplitAggregates()
    if orphans.isEmpty {
        print("no AudioSplit aggregate devices present")
    } else {
        for device in orphans { print("orphan: \(device.name)  [\(device.uid)]") }
    }
    exit(orphans.isEmpty ? 0 : 1)
}

// MARK: - Parse routes

let outputDevices = try DeviceStore.outputDevices().filter { !$0.isAggregate }

func resolveDevice(_ text: String) -> AudioDeviceInfo? {
    outputDevices.first { $0.uid == text }
        ?? outputDevices.first { $0.name.localizedCaseInsensitiveContains(text) }
}

var routes: [Route] = []
for (index, argument) in arguments.enumerated() where argument == "--route" {
    guard index + 1 < arguments.count else { continue }
    let spec = arguments[index + 1]
    guard let separator = spec.firstIndex(of: "=") else {
        print("error: --route needs <bundle id>=<device>, got \"\(spec)\"")
        exit(1)
    }
    let bundleID = String(spec[spec.startIndex ..< separator])
    var deviceText = String(spec[spec.index(after: separator)...])

    // Optional "@<volume>" suffix, e.g. --route com.apple.Safari=AirPods@0.25
    var volume: Float = 1
    var muted = false
    if let at = deviceText.lastIndex(of: "@") {
        let suffix = String(deviceText[deviceText.index(after: at)...])
        if suffix == "mute" {
            muted = true
            deviceText = String(deviceText[deviceText.startIndex ..< at])
        } else if let parsed = Float(suffix) {
            volume = parsed
            deviceText = String(deviceText[deviceText.startIndex ..< at])
        }
    }

    guard let device = resolveDevice(deviceText) else {
        print("error: no output device matching \"\(deviceText)\"")
        for device in outputDevices { print("  \(device.name)  [\(device.uid)]") }
        exit(1)
    }
    let delay = option("--delay").flatMap(Double.init) ?? 0
    routes.append(Route(
        appBundleID: bundleID,
        appDisplayName: bundleID,
        destinationDeviceUID: device.uid,
        volume: volume,
        isMuted: muted,
        delayMilliseconds: delay
    ))
}

guard !routes.isEmpty else {
    print("error: no routes given. Use --route <bundle id>=<device>.")
    exit(1)
}

let engine = RouteEngine()

// MARK: - Churn mode

if let index = arguments.firstIndex(of: "--churn"),
   index + 1 < arguments.count,
   let cycles = Int(arguments[index + 1]) {
    print("churning \(cycles) create/destroy cycles over \(routes.count) route(s)")
    var created = 0
    for cycle in 1 ... cycles {
        let (result, failures) = try engine.reconcile(routes: routes)
        created += result.actions.filter { if case .create = $0 { true } else { false } }.count
        for failure in failures {
            print("  cycle \(cycle): \(failure.destinationDeviceUID) — \(failure.message)")
        }
        for problem in engine.stopAll() { print("  cycle \(cycle): \(problem)") }
        let leftovers = try waitForTeardown()
        if !leftovers.isEmpty {
            print("  cycle \(cycle): LEAKED \(leftovers.count) aggregate(s)")
            for device in leftovers { print("    \(device.uid)") }
            exit(1)
        }
    }
    print("created and destroyed \(created) aggregate(s) across \(cycles) cycles")
    let remaining = try waitForTeardown()
    print(remaining.isEmpty
        ? "clean — no AudioSplit devices remain"
        : "LEAKED \(remaining.count) aggregate(s)")
    exit(remaining.isEmpty ? 0 : 1)
}

// MARK: - Live mode

print("routes")
for route in routes {
    let name = outputDevices.first { $0.uid == route.destinationDeviceUID }?.name
        ?? route.destinationDeviceUID
    let gain = route.isMuted
        ? "muted"
        : String(format: "%.0f%%", route.volume * 100)
    let delay = route.delayMilliseconds < 1
        ? ""
        : String(format: "  +%.0f ms", route.delayMilliseconds)
    print("  \(padded(route.appBundleID, 42))→ \(padded(name, 24))\(gain)\(delay)")
}
print("")

var statuses: [Route.ID: RouteStatus] = [:]

@MainActor
func reconcileNow(_ reason: String) {
    do {
        let (result, failures) = try engine.reconcile(routes: routes)
        statuses = result.statuses
        if !result.actions.isEmpty {
            print("\u{001B}[2m── \(reason): "
                + result.actions.map(describe).joined(separator: ", ") + "\u{001B}[0m")
        }
        for failure in failures {
            print("  failed \(failure.destinationDeviceUID): \(failure.message)")
        }
    } catch {
        print("  reconcile error: \(error)")
    }
}

func describe(_ taps: [TapSpec]) -> String {
    taps.map { "\($0.appBundleID): \($0.processObjectIDs.count) procs" }
        .joined(separator: ", ")
}

func describe(_ action: ReconcileAction) -> String {
    switch action {
    case let .create(spec): "create \(spec.destinationDeviceUID) (\(describe(spec.taps)))"
    case let .update(spec): "update \(spec.destinationDeviceUID) (\(describe(spec.taps)))"
    case let .destroy(uid): "destroy \(uid)"
    }
}

reconcileNow("initial")

for aggregate in engine.liveAggregates {
    print("aggregate \(aggregate.destinationName): \(aggregate.taps.count) tap(s), "
        + "output \(aggregate.outputChannelCount) ch — "
        + aggregate.taps.map(\.appBundleID).joined(separator: " + "))
}

// Every event that can invalidate routing funnels into the same call.
let processController = AudioProcessController()
let deviceStore = DeviceStore()
processController.onProcessListChanged = { reconcileNow("process list changed") }
deviceStore.onDevicesChanged = { reconcileNow("device list changed") }
try processController.startObserving()
try deviceStore.startObserving()

// Sleep invalidates device state; reconcile once the machine is back.
NSWorkspace.shared.notificationCenter.addObserver(
    forName: NSWorkspace.didWakeNotification,
    object: nil,
    queue: .main
) { _ in
    MainActor.assumeIsolated { reconcileNow("woke from sleep") }
}

var tornDown = false

@MainActor
func teardown() {
    guard !tornDown else { return }
    tornDown = true
    engine.stopAll()
    let leftovers = (try? waitForTeardown()) ?? []
    print("\ntorn down — "
        + (leftovers.isEmpty
            ? "no AudioSplit devices remain"
            : "LEAKED \(leftovers.count) aggregate(s)"))
}

signal(SIGINT, SIG_IGN)
let interrupts = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
interrupts.setEventHandler {
    MainActor.assumeIsolated {
        teardown()
        exit(0)
    }
}
interrupts.resume()

print("running — ctrl-c to stop\n")

let ticker = DispatchSource.makeTimerSource(queue: .main)
ticker.schedule(deadline: .now() + 1, repeating: 1)
ticker.setEventHandler {
    MainActor.assumeIsolated {
        print(padded("ROUTE", 40) + padded("STATUS", 22) + "LEVEL")
        for route in routes {
            let status = statuses[route.id]?.summary ?? "unknown"
            // Per-route now, not per-aggregate: each route has its own tap.
            let peak = engine.peak(forRouteID: route.id)
            let level: String = if let peak, peak > 0 {
                String(format: "%.1f dBFS  %@", 20 * log10(peak),
                       String(repeating: "█", count: Int((peak * 30).rounded())))
            } else if peak != nil {
                "silent"
            } else {
                "—"
            }
            print(padded(route.appBundleID, 40) + padded(status, 22) + level)
        }
        print("")
    }
}
ticker.resume()

RunLoop.main.run()
