import AudioSplitShared
import SwiftUI

/// The Mac's audio devices, with the controls each one offers.
struct RemoteDevicesView: View {
    @Bindable var model: RemoteModel

    var body: some View {
        List {
            section(
                title: "Output",
                devices: model.outputDevices,
                makeDefault: { model.setDefaultOutput($0) }
            )
            section(
                title: "Input",
                devices: model.inputDevices,
                makeDefault: { model.setDefaultInput($0) }
            )
        }
        .navigationTitle("Devices")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func section(
        title: String,
        devices: [RemoteDevice],
        makeDefault: @escaping (String) -> Void
    ) -> some View {
        Section(title) {
            ForEach(devices) { device in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(device.name)
                        if title == "Output" ? device.isDefaultOutput : device.isDefaultInput {
                            Text("Default")
                                .font(.caption2)
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.blue.opacity(0.12), in: Capsule())
                        }
                        Spacer()
                        if !(title == "Output" ? device.isDefaultOutput : device.isDefaultInput) {
                            Button("Use") { makeDefault(device.uid) }
                                .buttonStyle(.borderless)
                                .font(.caption)
                        }
                    }

                    if device.canSetVolume || device.canMute {
                        HStack(spacing: 10) {
                            Button {
                                model.setDeviceMuted(!device.isMuted, uid: device.uid)
                            } label: {
                                Image(systemName: device.isMuted
                                    ? "speaker.slash.fill"
                                    : "speaker.wave.2.fill")
                            }
                            .buttonStyle(.borderless)
                            .disabled(!device.canMute)

                            Slider(
                                value: Binding(
                                    get: { Double(device.volume ?? 0) },
                                    set: { model.setDeviceVolume(Float($0), uid: device.uid) }
                                ),
                                in: 0 ... 1
                            )
                            .disabled(!device.canSetVolume || device.isMuted)
                        }
                    } else {
                        // Plenty of devices genuinely have no software volume.
                        Text("No software volume control.")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}
