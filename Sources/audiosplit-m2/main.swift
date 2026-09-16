import AudioSplitEngine
import CoreAudio
import Foundation

// M2: one hardcoded route. Tap Safari, build an aggregate around the built-in
// speakers, copy tap input to device output in a single IOProc. No UI, no
// persistence, no generalisation — this exists to retire the technical risk.

// Line-buffer stdout so progress survives if the process dies unexpectedly.
setvbuf(stdout, nil, _IOLBF, 0)

let arguments = Array(CommandLine.arguments.dropFirst())

func option(_ name: String) -> String? {
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else {
        return nil
    }
    return arguments[index + 1]
}

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    audiosplit-m2 — AudioSplit M2 single hardcoded route

    Taps one app and plays it through one output device, removing it from
    wherever it was playing before.

    USAGE:
      audiosplit-m2 [--app <bundle id>] [--to <device name or uid>]

    OPTIONS:
      --app   Bundle ID to route. Default com.apple.Safari.
      --to    Destination output device, matched on UID or name.
              Default the built-in speakers.

    Ctrl-C tears everything down.
    """)
    exit(0)
}

let targetBundleID = option("--app") ?? "com.apple.Safari"
let requestedDestination = option("--to")

// MARK: - Find the destination

let outputDevices = try DeviceStore.outputDevices()
let destination: AudioDeviceInfo? = if let requestedDestination {
    outputDevices.first {
        $0.uid == requestedDestination
            || $0.name.localizedCaseInsensitiveContains(requestedDestination)
    }
} else {
    outputDevices.first { $0.uid == "BuiltInSpeakerDevice" }
        ?? outputDevices.first { $0.transportType == kAudioDeviceTransportTypeBuiltIn }
}

guard let destination, !destination.isAggregate else {
    print("error: no destination output device found"
        + (requestedDestination.map { " matching \"\($0)\"" } ?? " (built-in speakers)"))
    print("available:")
    for device in outputDevices where !device.isAggregate {
        print("  \(device.name)  [\(device.uid)]")
    }
    exit(1)
}

// MARK: - Find the processes to tap

let processes = try AudioProcessController.processes(routedAs: targetBundleID)
guard !processes.isEmpty else {
    print("error: no audio processes resolve to \(targetBundleID) — is the app running?")
    print("hint: audiosplit-probe --all  shows every process and its routing key")
    exit(1)
}

let defaultOutputID = try DeviceStore.defaultOutputDeviceID()
let defaultOutputName = defaultOutputID
    .flatMap { DeviceStore.info(for: $0)?.name } ?? "unknown"

print("routing      \(targetBundleID)")
print("to           \(destination.name)  [\(destination.uid)]")
print("default out  \(defaultOutputName)")
print("processes    " + processes.map { "obj \($0.objectID)/pid \($0.pid)" }
    .joined(separator: ", "))

if destination.objectID == defaultOutputID {
    print("""

    note: the destination is also the system default output, so you will not
          hear the audio move. Pass --to with a different device to see the
          effect, e.g. --to "AirPods".
    """)
}

// MARK: - Build the route

let engine = RouteEngine()

let useGlobalTap = arguments.contains("--global")
let tap = try useGlobalTap
    ? TapController.createGlobalTap(name: "AudioSplit M2 — global diagnostic")
    : TapController.createTap(
        name: "AudioSplit M2 — \(targetBundleID)",
        processObjectIDs: processes.map(\.objectID)
    )
if useGlobalTap { print("mode         GLOBAL TAP (diagnostic, unmuted)") }
print("tap          \(tap.uid)")
print("tap format   \(tap.formatDescription)")

let routeID = UUID()
let route: LiveAggregate
do {
    route = try engine.startAggregate(
        taps: [LiveTap(
            routeID: routeID,
            appBundleID: targetBundleID,
            handle: tap,
            processObjectIDs: Set(processes.map { ProcessObjectID($0.objectID) })
        )],
        destination: destination
    )
} catch {
    TapController.destroy(tap)
    print("error: \(error)")
    exit(1)
}

print("aggregate    \(route.aggregateUID)  (object \(route.aggregateID))")
print("channels     aggregate output \(route.outputChannelCount)")

// Report the aggregate's own stream formats.
for (label, scope) in [("input", kAudioObjectPropertyScopeInput),
                       ("output", kAudioObjectPropertyScopeOutput)] {
    if let asbd = AudioObjects.optionalValue(
        route.aggregateID,
        AudioObjects.address(kAudioDevicePropertyStreamFormat, scope: scope),
        default: AudioStreamBasicDescription(),
        operation: "read aggregate stream format"
    ) {
        print("agg \(label)    \(Int(asbd.mSampleRate)) Hz, \(asbd.mChannelsPerFrame) ch, "
            + "flags 0x\(String(asbd.mFormatFlags, radix: 16)), "
            + "\(asbd.mBitsPerChannel) bit, \(asbd.mBytesPerFrame) B/frame")
    }
}

print("")
print("running — play audio in \(targetBundleID). ctrl-c to stop.")
print("")

// MARK: - Teardown

var tornDown = false

@MainActor
func teardown() {
    guard !tornDown else { return }
    tornDown = true
    engine.teardown(route)
    print("\ntorn down — tap, aggregate and IOProc destroyed")
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

// MARK: - Live status

var lastFrames: UInt64 = 0
let ticker = DispatchSource.makeTimerSource(queue: .main)
ticker.schedule(deadline: .now() + 1, repeating: 1)
ticker.setEventHandler {
    MainActor.assumeIsolated {
        let frames = route.framesRendered(forRouteID: routeID) ?? 0
        let delta = frames &- lastFrames
        lastFrames = frames
        let peak = route.peak(forRouteID: routeID) ?? 0
        let bar = String(repeating: "█", count: Int((peak * 40).rounded()))
        let level = peak > 0
            ? String(format: "%5.1f dBFS", 20 * log10(peak))
            : "   silent"
        print(String(
            format: "%10llu frames  %+8llu/s  %@ %@",
            frames, delta, level, bar
        ))
    }
}
ticker.resume()

// RunLoop.main.run(), not dispatchMain(). Under dispatchMain() the main queue
// may be drained by a worker thread rather than the main thread, so main-queue
// handlers are not actually on the MainActor's executor and
// MainActor.assumeIsolated traps. Swift 6.4 diagnoses this; earlier toolchains
// let it through silently.
RunLoop.main.run()
