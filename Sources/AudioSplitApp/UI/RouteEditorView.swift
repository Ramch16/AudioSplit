import AudioSplitEngine
import AudioSplitShared
import SwiftUI

/// One row: an app, where it goes, how loud, and whether it is actually working.
struct RouteEditorView: View {
    @Bindable var model: AppModel
    let route: Route

    private var status: RouteStatus { model.status(for: route) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(route.appDisplayName)
                    .fontWeight(.medium)
                    .lineLimit(1)
                statusBadge
                Spacer(minLength: 4)
                Button {
                    model.remove(route)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.borderless)
                .help("Remove this route")
            }

            HStack(spacing: 6) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Picker("", selection: destinationBinding) {
                    ForEach(model.outputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                    // Keep an unplugged device visible so the route still reads
                    // correctly instead of silently snapping to another device.
                    if !model.outputDevices.contains(where: { $0.uid == route.destinationDeviceUID }) {
                        Text(model.deviceName(forUID: route.destinationDeviceUID))
                            .tag(route.destinationDeviceUID)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                Button {
                    model.setMuted(!route.isMuted, for: route)
                } label: {
                    Image(systemName: route.isMuted
                        ? "speaker.slash.fill"
                        : "speaker.wave.2.fill")
                        .frame(width: 16)
                }
                .buttonStyle(.borderless)
                .help(route.isMuted ? "Unmute" : "Mute")

                Slider(value: volumeBinding, in: 0 ... 1) { editing in
                    if !editing { model.commitParameters() }
                }
                .controlSize(.small)
                .disabled(route.isMuted)

                LevelMeter(level: model.level(for: route))
                    .frame(width: 44, height: 6)
            }

            HStack(spacing: 8) {
                Image(systemName: "timer")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 16)
                Slider(value: delayBinding, in: 0 ... DelayLimits.maximumMilliseconds) { editing in
                    if !editing { model.commitParameters() }
                }
                .controlSize(.small)
                Text(route.delayMilliseconds < 1
                    ? "no delay"
                    : "\(Int(route.delayMilliseconds)) ms")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .frame(width: 52, alignment: .trailing)
            }
            .help("Delay this route to line audio up with picture")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .opacity(route.isEnabled ? 1 : 0.5)
    }

    private var destinationBinding: Binding<String> {
        Binding(
            get: { route.destinationDeviceUID },
            set: { model.setDestination($0, for: route) }
        )
    }

    private var delayBinding: Binding<Double> {
        Binding(
            get: { route.delayMilliseconds },
            set: { model.setDelay($0, for: route) }
        )
    }

    private var volumeBinding: Binding<Double> {
        Binding(
            get: { Double(route.volume) },
            set: { model.setVolume(Float($0), for: route) }
        )
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .active:
            badge("Active", .green)
        case .waitingForApp:
            badge("Not playing", .secondary)
        case .waitingForDevice:
            badge("Device offline", .orange)
        case .conflicting:
            badge("Duplicate", .orange)
        case .disabled:
            badge("Off", .secondary)
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(color)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
    }
}

/// A peak meter. Logarithmic, because linear peak looks dead for normal audio.
struct LevelMeter: View {
    let level: Float

    private var fraction: Double {
        guard level > 0 else { return 0 }
        let decibels = 20 * log10(Double(level))
        return min(max((decibels + 60) / 60, 0), 1)
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(level > 0.98 ? Color.orange : Color.green)
                    .frame(width: geometry.size.width * fraction)
            }
        }
        .animation(.linear(duration: 0.1), value: fraction)
    }
}
