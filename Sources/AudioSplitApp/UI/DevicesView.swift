import AudioSplitEngine
import SwiftUI

/// Every audio device on the machine, with the controls the device itself
/// offers: volume, mute, and whether it is the system default.
///
/// This is ordinary system audio control. It works on devices AudioSplit is not
/// routing anything to, and it involves no taps.
struct DevicesView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                deviceSection(
                    title: "Output",
                    icon: "hifispeaker",
                    devices: model.outputDevices,
                    defaultUID: model.defaultOutputUID,
                    makeDefault: { model.setDefaultOutput(uid: $0) }
                )

                deviceSection(
                    title: "Input",
                    icon: "mic",
                    devices: model.inputDevices,
                    defaultUID: model.defaultInputUID,
                    makeDefault: { model.setDefaultInput(uid: $0) }
                )

                InputToggleSettings(model: model)
            }
            .padding(14)
        }
    }

    private func deviceSection(
        title: String,
        icon: String,
        devices: [AudioDeviceInfo],
        defaultUID: String?,
        makeDefault: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.headline)

            if devices.isEmpty {
                Text("No \(title.lowercased()) devices").font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(devices) { device in
                    DeviceCard(
                        model: model,
                        device: device,
                        isDefault: device.uid == defaultUID,
                        makeDefault: { makeDefault(device.uid) }
                    )
                }
            }
        }
    }
}

struct DeviceCard: View {
    @Bindable var model: AppModel
    let device: AudioDeviceInfo
    let isDefault: Bool
    let makeDefault: () -> Void

    private var control: AppModel.DeviceControlState { model.control(for: device) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(device.name).fontWeight(.medium)
                if isDefault {
                    Text("Default")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.12), in: Capsule())
                }
                Spacer()
                if !isDefault {
                    Button("Make Default", action: makeDefault)
                        .buttonStyle(.borderless)
                        .font(.caption)
                }
            }

            Text("\(device.transportDescription) · \(device.outputChannelCount > 0 ? "\(device.outputChannelCount) out" : "\(device.inputChannelCount) in") · \(Int(device.nominalSampleRate)) Hz")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            if control.canSetVolume || control.canMute {
                HStack(spacing: 8) {
                    Button {
                        model.setDeviceMuted(!control.isMuted, for: device)
                    } label: {
                        Image(systemName: control.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .frame(width: 16)
                    }
                    .buttonStyle(.borderless)
                    .disabled(!control.canMute)

                    Slider(value: Binding(
                        get: { Double(control.volume ?? 0) },
                        set: { model.setDeviceVolume(Float($0), for: device) }
                    ), in: 0 ... 1)
                    .disabled(!control.canSetVolume || control.isMuted)

                    Text(control.volume.map { "\(Int($0 * 100))%" } ?? "—")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            } else {
                // Plenty of devices genuinely have no software volume — AirPlay,
                // some HDMI and USB interfaces. Say so rather than showing a
                // dead slider.
                Text("This device has no software volume control.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            let routed = model.routes(toDeviceUID: device.uid)
            if !routed.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.branch").font(.caption2)
                    Text(routed.map(\.appDisplayName).joined(separator: ", "))
                        .font(.caption2)
                        .lineLimit(1)
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Configuration for the global input-toggle hotkey.
struct InputToggleSettings: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Input Toggle Hotkey", systemImage: "keyboard")
                .font(.headline)

            Text("Press \(model.preferences.inputToggleHotKey.displayString) from any app to flip between two input devices.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                ForEach([0, 1], id: \.self) { slot in
                    Picker("", selection: pairBinding(slot)) {
                        Text("None").tag("")
                        // Hide the device the other slot already holds; the same
                        // device twice is a toggle that does nothing.
                        ForEach(model.inputDevices.filter {
                            $0.uid == pairBinding(slot).wrappedValue
                                || !model.preferences.inputToggleDeviceUIDs.contains($0.uid)
                        }) { device in
                            Text(device.name).tag(device.uid)
                        }
                    }
                    .labelsHidden()
                }
            }

            Toggle("Enable hotkey", isOn: Binding(
                get: { model.preferences.inputToggleHotKey.isEnabled },
                set: { model.setHotKeyEnabled($0) }
            ))
            .disabled(!model.preferences.hasValidTogglePair)

            if !model.preferences.hasValidTogglePair {
                Text("Pick two different devices to enable the hotkey.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if model.hotKeyFailed {
                Label("Another app already uses that shortcut.", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(10)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private func pairBinding(_ slot: Int) -> Binding<String> {
        Binding(
            get: {
                let pair = model.preferences.inputToggleDeviceUIDs
                return slot < pair.count ? pair[slot] : ""
            },
            set: { uid in
                var pair = model.preferences.inputToggleDeviceUIDs
                while pair.count < 2 { pair.append("") }
                pair[slot] = uid
                model.setInputTogglePair(pair.filter { !$0.isEmpty })
            }
        )
    }
}
