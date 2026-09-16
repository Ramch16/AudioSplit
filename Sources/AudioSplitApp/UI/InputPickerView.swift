import AudioSplitEngine
import SwiftUI

/// Microphone switcher, plus the pair the global hotkey flips between.
///
/// This is a system-wide default-input change, the same one the Sound pane
/// makes. AudioSplit does not route input per app — that is out of scope and
/// would need a completely different mechanism.
struct InputPickerView: View {
    @Bindable var model: AppModel
    @State private var isConfiguring = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: "mic")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Input").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button {
                    isConfiguring.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Configure the input toggle hotkey")
                .popover(isPresented: $isConfiguring, arrowEdge: .bottom) {
                    hotKeyConfiguration
                }
            }

            Picker("", selection: inputBinding) {
                ForEach(model.inputDevices) { device in
                    Text(device.name).tag(device.uid)
                }
                if let current = model.defaultInputUID,
                   !model.inputDevices.contains(where: { $0.uid == current }) {
                    Text(model.inputDeviceName(forUID: current)).tag(current)
                }
            }
            .labelsHidden()
            .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var inputBinding: Binding<String> {
        Binding(
            get: { model.defaultInputUID ?? "" },
            set: { model.setDefaultInput(uid: $0) }
        )
    }

    private var hotKeyConfiguration: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Input toggle").font(.headline)
            Text("Press \(model.preferences.inputToggleHotKey.displayString) anywhere to flip between two inputs.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle("Enable hotkey", isOn: Binding(
                get: { model.preferences.inputToggleHotKey.isEnabled },
                set: { model.setHotKeyEnabled($0) }
            ))
            .controlSize(.small)
            .disabled(!model.preferences.hasValidTogglePair)

            if model.hotKeyFailed {
                Label("Another app already uses that shortcut.", systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

            Divider()
            Text("Flip between").font(.caption).foregroundStyle(.secondary)

            ForEach([0, 1], id: \.self) { slot in
                Picker("", selection: pairBinding(slot)) {
                    Text("None").tag("")
                    ForEach(model.inputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
            }

            if !model.preferences.hasValidTogglePair {
                Text("Pick two different devices to enable the hotkey.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .frame(width: 250)
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
