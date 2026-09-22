import AudioSplitShared
import SwiftUI

struct RemoteRootView: View {
    @Bindable var model: RemoteModel

    var body: some View {
        if model.isConnected {
            connected
        } else {
            ConnectView(model: model)
        }
    }

    private var connected: some View {
        TabView {
            NavigationStack { RemoteRoutesView(model: model) }
                .tabItem { Label("Routes", systemImage: "arrow.triangle.branch") }
            NavigationStack { RemoteDevicesView(model: model) }
                .tabItem { Label("Devices", systemImage: "hifispeaker.2") }
        }
    }
}

/// Find a Mac and pair with it.
struct ConnectView: View {
    @Bindable var model: RemoteModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if model.discovered.isEmpty {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Looking for Macs running AudioSplit…")
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        ForEach(model.discovered) { mac in
                            Button {
                                model.connect(to: mac)
                            } label: {
                                HStack {
                                    Label(mac.name, systemImage: "desktopcomputer")
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            .disabled(model.pairingCode.count < 6)
                        }
                    }
                } header: {
                    Text("Macs on this network")
                } footer: {
                    Text("""
                    Your Mac must have AudioSplit open with **Remote → Allow remote \
                    control** switched on.
                    """)
                }

                Section {
                    TextField("ABC123", text: $model.pairingCode)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .font(.system(.title3, design: .monospaced))
                } header: {
                    Text("Pairing code")
                } footer: {
                    Text("Shown on the Mac under Remote. Six characters.")
                }

                if case let .failed(reason) = model.state {
                    Section {
                        Label(reason, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("AudioSplit")
            .toolbar {
                Button("Search Again") { model.rediscover() }
            }
        }
    }
}
