import AudioSplitShared
import SwiftUI

/// The routes list, as the Mac reports it.
struct RemoteRoutesView: View {
    @Bindable var model: RemoteModel
    @State private var isAdding = false

    var body: some View {
        List {
            if model.captureLooksBroken {
                Section {
                    Label(
                        "The Mac is not capturing audio. Check its audio permission.",
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(.orange)
                    .font(.footnote)
                }
            }

            if model.routes.isEmpty {
                Section {
                    ContentUnavailableView(
                        "No routes",
                        systemImage: "arrow.triangle.branch",
                        description: Text("Send an app to a device of its own.")
                    )
                }
            }

            ForEach(model.routes) { route in
                Section {
                    RemoteRouteRow(model: model, route: route)
                }
            }

            Section {
                Button("Restore All Audio", systemImage: "arrow.uturn.backward.circle") {
                    model.restoreAllAudio()
                }
                Button("Disconnect", systemImage: "xmark.circle") {
                    model.disconnect()
                }
                .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(model.hostName)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Add", systemImage: "plus") { isAdding = true }
                .disabled(model.routableApps.isEmpty)
        }
        .sheet(isPresented: $isAdding) {
            RemoteAddRouteView(model: model, isPresented: $isAdding)
        }
    }
}

struct RemoteRouteRow: View {
    @Bindable var model: RemoteModel
    let route: Route

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(route.appDisplayName).font(.headline)
                Spacer()
                statusBadge
            }

            Picker("Plays on", selection: Binding(
                get: { route.destinationDeviceUID },
                set: { model.setDestination($0, for: route) }
            )) {
                ForEach(model.outputDevices) { device in
                    Text(device.name).tag(device.uid)
                }
                if !model.outputDevices.contains(where: { $0.uid == route.destinationDeviceUID }) {
                    Text("\(model.deviceName(forUID: route.destinationDeviceUID)) (offline)")
                        .tag(route.destinationDeviceUID)
                }
            }

            HStack(spacing: 10) {
                Button {
                    model.setMuted(!route.isMuted, for: route)
                } label: {
                    Image(systemName: route.isMuted
                        ? "speaker.slash.fill"
                        : "speaker.wave.2.fill")
                }
                .buttonStyle(.borderless)

                Slider(
                    value: Binding(
                        get: { Double(model.volume(for: route)) },
                        set: { model.setVolume(Float($0), for: route) }
                    ),
                    in: 0 ... 1
                ) { editing in
                    if !editing { model.commitVolume(for: route) }
                }
                .disabled(route.isMuted)

                RemoteLevelMeter(level: model.level(for: route))
                    .frame(width: 40, height: 6)
            }

            HStack(spacing: 10) {
                Image(systemName: "timer").foregroundStyle(.tertiary)
                Slider(
                    value: Binding(
                        get: { model.delay(for: route) },
                        set: { model.setDelay($0, for: route) }
                    ),
                    in: 0 ... DelayLimits.maximumMilliseconds
                ) { editing in
                    if !editing { model.commitDelay(for: route) }
                }
                Text(model.delay(for: route) < 1
                    ? "none"
                    : "\(Int(model.delay(for: route))) ms")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .trailing)
            }
        }
        .padding(.vertical, 4)
        .swipeActions {
            Button("Remove", systemImage: "trash", role: .destructive) {
                model.remove(route)
            }
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        let (text, color): (String, Color) = switch model.status(for: route) {
        case .active: ("Active", .green)
        case .waitingForApp: ("Not playing", .secondary)
        case .waitingForDevice: ("Device offline", .orange)
        case .conflicting: ("Duplicate", .orange)
        case .disabled: ("Off", .secondary)
        }
        Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }
}

struct RemoteLevelMeter: View {
    let level: Float

    private var fraction: Double {
        guard level > 0 else { return 0 }
        return min(max((20 * log10(Double(level)) + 60) / 60, 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule().fill(.green).frame(width: geometry.size.width * fraction)
            }
        }
        .animation(.linear(duration: 0.1), value: fraction)
    }
}

struct RemoteAddRouteView: View {
    @Bindable var model: RemoteModel
    @Binding var isPresented: Bool
    @State private var destination = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Send to") {
                    Picker("Device", selection: $destination) {
                        ForEach(model.outputDevices) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                }
                Section("App") {
                    ForEach(model.routableApps) { app in
                        Button {
                            model.addRoute(app: app, destinationUID: destination)
                            isPresented = false
                        } label: {
                            HStack {
                                Circle()
                                    .fill(app.isProducingOutput ? Color.green : .clear)
                                    .frame(width: 7, height: 7)
                                Text(app.displayName)
                                Spacer()
                                if app.isProducingOutput {
                                    Text("playing")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Route an App")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Cancel") { isPresented = false }
            }
            .onAppear {
                if destination.isEmpty {
                    destination = model.outputDevices.first?.uid ?? ""
                }
            }
        }
    }
}
