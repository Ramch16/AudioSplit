import AudioSplitEngine
import CoreAudio
import Foundation

// M1 discovery spike: prove that we can see the right processes and devices
// before any tap, aggregate or IOProc exists.

let arguments = Array(CommandLine.arguments.dropFirst())
let watching = arguments.contains("watch") || arguments.contains("--watch")
let showAll = arguments.contains("--all")
let verbose = arguments.contains("--verbose") || arguments.contains("-v")

// Inspect, and optionally set, a device's own volume.
if let index = arguments.firstIndex(of: "--device-volume"), index + 1 < arguments.count {
    let wanted = arguments[index + 1]
    let devices = try DeviceStore.outputDevices()
    guard let device = devices.first(where: { $0.name.localizedCaseInsensitiveContains(wanted) })
    else {
        print("no output device matching \"\(wanted)\"")
        exit(1)
    }
    let canSet = DeviceStore.canSetVolume(of: device.objectID)
    let current = DeviceStore.volume(of: device.objectID)
    print("\(device.name): volume "
        + (current.map { String(format: "%.3f", $0) } ?? "not supported")
        + ", settable \(canSet), mute \(DeviceStore.isMuted(of: device.objectID).map(String.init) ?? "not supported")")

    if index + 2 < arguments.count, let target = Float(arguments[index + 2]) {
        try DeviceStore.setVolume(target, of: device.objectID)
        let after = DeviceStore.volume(of: device.objectID)
        print("  set to \(target) -> now \(after.map { String(format: "%.3f", $0) } ?? "?")")
    }
    exit(0)
}

// Switch the system default input, the same change the Sound pane makes.
if let index = arguments.firstIndex(of: "--set-input"), index + 1 < arguments.count {
    let wanted = arguments[index + 1]
    let devices = try DeviceStore.inputDevices()
    guard let device = devices.first(where: { $0.uid == wanted })
        ?? devices.first(where: { $0.name.localizedCaseInsensitiveContains(wanted) })
    else {
        print("no input device matching \"\(wanted)\"")
        for device in devices { print("  \(device.name)  [\(device.uid)]") }
        exit(1)
    }
    let before = try DeviceStore.defaultInputDeviceID()
        .flatMap { DeviceStore.info(for: $0)?.name } ?? "unknown"
    try DeviceStore.setDefaultInputDevice(device.objectID)
    let after = try DeviceStore.defaultInputDeviceID()
        .flatMap { DeviceStore.info(for: $0)?.name } ?? "unknown"
    print("default input: \(before) -> \(after)")
    exit(after == device.name ? 0 : 1)
}

if arguments.contains("--help") || arguments.contains("-h") {
    print("""
    audiosplit-probe — AudioSplit M1 discovery spike

    USAGE:
      audiosplit-probe [watch] [--all] [--verbose]

    OPTIONS:
      watch       Keep running and reprint whenever the process or device list changes.
      --all       Include process objects that are not currently producing output.
      --verbose   Show executable paths and process ancestry used to resolve each app.
      --set-input <name>  Switch the system default input device and exit.
      --help      This message.
    """)
    exit(0)
}

/// Pad to `width`, always leaving at least one space so truncated cells never
/// run into the next column.
func padded(_ text: String, _ width: Int) -> String {
    let limit = width - 1
    guard text.count > limit else {
        return text + String(repeating: " ", count: width - text.count)
    }
    return String(text.prefix(limit - 1)) + "\u{2026} "
}

func rule(_ title: String) {
    print("")
    print("── \(title) " + String(repeating: "─", count: max(0, 68 - title.count)))
}

@MainActor
func printDevices() throws {
    let devices = try DeviceStore.allDevices()
    let defaultOutput = try DeviceStore.defaultOutputDeviceID()
    let defaultInput = try DeviceStore.defaultInputDeviceID()
    let defaultSystem = try DeviceStore.defaultSystemOutputDeviceID()

    rule("OUTPUT DEVICES")
    print(padded("ID", 7) + padded("CH", 4) + padded("RATE", 9)
        + padded("TRANSPORT", 14) + padded("NAME", 30) + "UID")
    for device in devices.filter(\.canOutput).sorted(by: { $0.name < $1.name }) {
        var marks: [String] = []
        if device.objectID == defaultOutput { marks.append("default-out") }
        if device.objectID == defaultSystem { marks.append("system-out") }
        if device.isAggregate { marks.append("aggregate") }
        let suffix = marks.isEmpty ? "" : "  [\(marks.joined(separator: ", "))]"
        print(
            padded("\(device.objectID)", 7)
                + padded("\(device.outputChannelCount)", 4)
                + padded("\(Int(device.nominalSampleRate))", 9)
                + padded(device.transportDescription, 14)
                + padded(device.name, 30)
                + device.uid + suffix
        )
    }

    rule("INPUT DEVICES")
    print(padded("ID", 7) + padded("CH", 4) + padded("RATE", 9)
        + padded("TRANSPORT", 14) + padded("NAME", 30) + "UID")
    for device in devices.filter(\.canInput).sorted(by: { $0.name < $1.name }) {
        let mark = device.objectID == defaultInput ? "  [default-in]" : ""
        print(
            padded("\(device.objectID)", 7)
                + padded("\(device.inputChannelCount)", 4)
                + padded("\(Int(device.nominalSampleRate))", 9)
                + padded(device.transportDescription, 14)
                + padded(device.name, 30)
                + device.uid + mark
        )
    }
}

@MainActor
func printProcesses() throws {
    let processes = try AudioProcessController.allProcesses()
    let devices = try DeviceStore.allDevices()
    let deviceNames = Dictionary(uniqueKeysWithValues: devices.map { ($0.objectID, $0.name) })

    let interesting = showAll ? processes : processes.filter { $0.isRunningOutput }
    let title = showAll
        ? "AUDIO PROCESS OBJECTS (all \(processes.count))"
        : "AUDIO PROCESS OBJECTS PRODUCING OUTPUT (\(interesting.count) of \(processes.count))"
    rule(title)

    if interesting.isEmpty {
        print("(none — start playing audio somewhere, or pass --all)")
        return
    }

    print(padded("OBJ", 7) + padded("PID", 8) + padded("APP", 26)
        + padded("ROUTING KEY (bundle ID)", 40) + padded("VIA", 20) + "PLAYING TO")
    for process in interesting.sorted(by: { $0.pid < $1.pid }) {
        let identity = ProcessIdentityResolver.resolve(
            pid: process.pid,
            halBundleID: process.halBundleID
        )
        let playingTo = process.outputDeviceIDs
            .compactMap { deviceNames[$0] }
            .joined(separator: ", ")
        print(
            padded("\(process.objectID)", 7)
                + padded("\(process.pid)", 8)
                + padded(identity.displayName, 26)
                + padded(identity.bundleID, 40)
                + padded(identity.source.rawValue, 20)
                + (playingTo.isEmpty ? "—" : playingTo)
        )

        if verbose {
            let facts = ProcessIdentityResolver.facts(for: process.pid)
            print("        hal bundle id : \(process.halBundleID ?? "—")")
            print("        executable    : \(facts.executablePath ?? "—")")
            print("        enclosing app : \(facts.enclosingAppBundleURL?.path ?? "—")")
            print("        ancestry      : "
                + (facts.ancestors.isEmpty
                    ? "—"
                    : facts.ancestors.map { "\($0.1) (\($0.0))" }.joined(separator: " ← ")))
            print("        responsible   : "
                + (facts.responsiblePID.map { pid in
                    let name = ProcessIdentityResolver.executablePath(of: pid)
                        .map { URL(fileURLWithPath: $0).lastPathComponent } ?? "?"
                    return "\(name) (\(pid))"
                } ?? "—"))
            print("        running io    : out=\(process.isRunningOutput) "
                + "in=\(process.isRunningInput) any=\(process.isRunning)")
        }
    }

    // Routing keys are what later milestones persist. Several processes sharing a
    // key is normal and desirable — that is a helper being folded into its app.
    // What matters is whether the fold looks right, and what failed to resolve.
    var byKey: [String: (name: String, pids: [pid_t])] = [:]
    var unresolved: [(AudioProcessSnapshot, AppIdentity)] = []
    for process in interesting {
        let identity = ProcessIdentityResolver.resolve(
            pid: process.pid,
            halBundleID: process.halBundleID
        )
        byKey[identity.bundleID, default: (identity.displayName, [])].pids.append(process.pid)
        if !identity.isResolved { unresolved.append((process, identity)) }
    }

    let grouped = byKey.filter { $0.value.pids.count > 1 }
    if !grouped.isEmpty {
        rule("GROUPED PROCESSES (helpers folded into their app)")
        for (key, value) in grouped.sorted(by: { $0.key < $1.key }) {
            print(padded(value.name, 26) + padded(key, 44)
                + value.pids.map(String.init).joined(separator: ", "))
        }
    }

    if !unresolved.isEmpty {
        rule("NOT ROUTABLE (no owning application)")
        for (process, identity) in unresolved {
            print(padded("pid \(process.pid)", 12) + identity.bundleID)
        }
    }
}

@MainActor
func printSnapshot() {
    print("\u{001B}[1mAudioSplit probe — \(Date().formatted(date: .omitted, time: .standard))\u{001B}[0m")
    if !ResponsibleProcess.isAvailable {
        print("\u{001B}[33mwarning: process responsibility lookup unavailable — "
            + "helper processes will resolve less precisely\u{001B}[0m")
    }
    do {
        try printProcesses()
        try printDevices()
    } catch {
        print("error: \(error)")
    }
    print("")
}

printSnapshot()

if watching {
    let processController = AudioProcessController()
    let deviceStore = DeviceStore()
    var pending = false

    // The HAL fires these in bursts; collapse them so the terminal stays readable.
    func scheduleReprint(_ reason: String) {
        guard !pending else { return }
        pending = true
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            pending = false
            print("\u{001B}[2m── change: \(reason)\u{001B}[0m")
            printSnapshot()
        }
    }

    processController.onProcessListChanged = { scheduleReprint("process list") }
    deviceStore.onDevicesChanged = { scheduleReprint("device list") }
    deviceStore.onDefaultInputChanged = { scheduleReprint("default input device") }

    do {
        try processController.startObserving()
        try deviceStore.startObserving()
    } catch {
        print("error: could not install listeners: \(error)")
        exit(1)
    }

    print("watching — start/stop audio, plug or unplug a device. ctrl-c to exit.")
    RunLoop.main.run()
}
