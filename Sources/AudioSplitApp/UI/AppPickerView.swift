import AudioSplitEngine
import SwiftUI

/// Pick an app to route. Apps currently making noise are listed first, because
/// that is almost always the one the user came here for.
struct AppPickerView: View {
    @Bindable var model: AppModel
    @Binding var isPresented: Bool

    @State private var selectedDeviceUID: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Route an app").font(.headline)

            if model.routableApps.isEmpty {
                Text("Every app currently using audio is already routed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Picker("To", selection: $selectedDeviceUID) {
                    ForEach(model.outputDevices) { device in
                        Text(device.name).tag(device.uid)
                    }
                }
                .controlSize(.small)

                Divider()

                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.routableApps) { app in
                            Button {
                                model.addRoute(app: app, destinationUID: selectedDeviceUID)
                                isPresented = false
                            } label: {
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(app.isProducingOutput ? Color.green : Color.clear)
                                        .frame(width: 6, height: 6)
                                    Text(app.displayName).lineLimit(1)
                                    Spacer()
                                    if app.isProducingOutput {
                                        Text("playing")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.borderless)
                            .padding(.vertical, 3)
                        }
                    }
                }
                .frame(maxHeight: 220)
            }
        }
        .padding(12)
        .frame(width: 260)
        .onAppear {
            if selectedDeviceUID.isEmpty {
                selectedDeviceUID = model.outputDevices.first?.uid ?? ""
            }
        }
    }
}
