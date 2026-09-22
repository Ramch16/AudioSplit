import AudioSplitEngine
import AudioSplitShared
import SwiftUI

/// Per-app routing: the thing AudioSplit exists for.
struct RoutesView: View {
    @Bindable var model: AppModel
    @State private var isAddingRoute = false
    @State private var isAddingFromToolbar = false

    var body: some View {
        VStack(spacing: 0) {
            if model.routes.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(model.routes) { route in
                            RouteCard(model: model, route: route)
                        }

                        // A toolbar-only "+" is too easy to miss: someone who
                        // wants to route a second app reaches for the device
                        // picker on the card that is already there, and silently
                        // re-points an existing route instead of making a new one.
                        Button {
                            model.refreshInventory()
                            isAddingRoute = true
                        } label: {
                            Label("Route Another App", systemImage: "plus.circle")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.bordered)
                        .popover(isPresented: $isAddingRoute, arrowEdge: .bottom) {
                            AppPickerView(model: model, isPresented: $isAddingRoute)
                        }
                        .padding(.top, 4)
                    }
                    .padding(14)
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    model.refreshInventory()
                    isAddingFromToolbar = true
                } label: {
                    Label("Add Route", systemImage: "plus")
                }
                .help("Route another app to a device of its own")
                .popover(isPresented: $isAddingFromToolbar, arrowEdge: .bottom) {
                    AppPickerView(model: model, isPresented: $isAddingFromToolbar)
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 34))
                .foregroundStyle(.tertiary)
            Text("No routes yet").font(.title3)
            Text("""
            Send one app to your headphones and another to the speakers, so a \
            video and a call stop fighting over the same device.
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 340)
            Button("Add a Route") {
                model.refreshInventory()
                isAddingRoute = true
            }
            .controlSize(.large)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One route, with every control it has.
struct RouteCard: View {
    @Bindable var model: AppModel
    let route: Route

    private var status: RouteStatus { model.status(for: route) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                AppIcon(bundleID: route.appBundleID, name: route.appDisplayName, size: 26)
                VStack(alignment: .leading, spacing: 1) {
                    Text(route.appDisplayName).fontWeight(.medium)
                    Text(route.appBundleID)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                Spacer()
                StatusBadge(status: status)
                Toggle("", isOn: Binding(
                    get: { route.isEnabled },
                    set: { model.setEnabled($0, for: route) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .help(route.isEnabled ? "Turn this route off" : "Turn this route on")
                Button {
                    model.remove(route)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this route")
            }

            HStack(spacing: 8) {
                Text("Plays on").font(.caption).foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)
                Picker("", selection: Binding(
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
                .labelsHidden()
            }

            HStack(spacing: 8) {
                Text("Volume").font(.caption).foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)
                Button {
                    model.setMuted(!route.isMuted, for: route)
                } label: {
                    Image(systemName: route.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)
                Slider(value: Binding(
                    get: { Double(route.volume) },
                    set: { model.setVolume(Float($0), for: route) }
                ), in: 0 ... 1) { editing in
                    if !editing { model.commitParameters() }
                }
                .disabled(route.isMuted)
                LevelMeter(level: model.level(for: route))
                    .frame(width: 60, height: 6)
            }

            HStack(spacing: 8) {
                Text("Delay").font(.caption).foregroundStyle(.secondary)
                    .frame(width: 58, alignment: .leading)
                Image(systemName: "timer").frame(width: 16).foregroundStyle(.tertiary)
                Slider(value: Binding(
                    get: { route.delayMilliseconds },
                    set: { model.setDelay($0, for: route) }
                ), in: 0 ... DelayLimits.maximumMilliseconds) { editing in
                    if !editing { model.commitParameters() }
                }
                Text(route.delayMilliseconds < 1 ? "none" : "\(Int(route.delayMilliseconds)) ms")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 60, alignment: .trailing)
            }
            .help("Delays this route only. Use it to line audio back up with picture.")
        }
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
        .opacity(route.isEnabled ? 1 : 0.55)
    }
}

struct StatusBadge: View {
    let status: RouteStatus

    var body: some View {
        let (text, color) = appearance
        Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
    }

    private var appearance: (String, Color) {
        switch status {
        case .active: ("Active", .green)
        case .waitingForApp: ("Not playing", .secondary)
        case .waitingForDevice: ("Device offline", .orange)
        case .conflicting: ("Duplicate", .orange)
        case .disabled: ("Off", .secondary)
        }
    }
}

/// The real app icon, looked up from the bundle we resolved the route to.
///
/// Plenty of routable things have no installed app bundle to take an icon from —
/// command-line players, apps launched from a build directory. A blank
/// placeholder there looks like a rendering failure, so those get a monogram
/// instead, which reads as deliberate.
struct AppIcon: View {
    let bundleID: String
    var name: String = ""
    var size: CGFloat = 20

    var body: some View {
        Group {
            if let image = Self.icon(for: bundleID) {
                Image(nsImage: image).resizable()
            } else {
                RoundedRectangle(cornerRadius: size * 0.22)
                    .fill(Self.tint(for: bundleID).gradient)
                    .overlay {
                        Text(Self.monogram(name: name, bundleID: bundleID))
                            .font(.system(size: size * 0.5, weight: .semibold))
                            .foregroundStyle(.white)
                    }
            }
        }
        .frame(width: size, height: size)
    }

    private static func icon(for bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared
            .urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }

    private static func monogram(name: String, bundleID: String) -> String {
        let source = name.isEmpty
            ? (bundleID.split(separator: ".").last.map(String.init) ?? bundleID)
            : name
        return source.first.map { String($0).uppercased() } ?? "?"
    }

    /// Stable per-app colour, so the same app always looks the same.
    private static func tint(for bundleID: String) -> Color {
        let palette: [Color] = [.blue, .purple, .pink, .orange, .teal, .indigo, .green]
        return palette[abs(bundleID.hashValue) % palette.count]
    }
}
