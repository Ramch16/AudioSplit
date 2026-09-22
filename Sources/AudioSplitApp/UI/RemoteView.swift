import AudioSplitEngine
import AudioSplitShared
import SwiftUI

/// Lets an iPhone or iPad drive this Mac's routing.
///
/// Worth being blunt in the UI about what this is: AudioSplit is not sandboxed
/// and can mute or re-route every app on the machine. Turning this on puts that
/// behind a pairing code on your local network. It is off until asked for.
struct RemoteView: View {
    @Bindable var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("iPhone & iPad Remote", systemImage: "iphone.gen3")
                        .font(.headline)
                    Text("""
                    Control this Mac's routing from your phone or iPad on the same \
                    network. Audio never leaves the Mac — the remote only sends \
                    instructions and shows what is happening.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                    Toggle("Allow remote control", isOn: Binding(
                        get: { model.isRemoteEnabled },
                        set: { model.setRemoteEnabled($0) }
                    ))
                    .padding(.top, 2)
                }

                if model.isRemoteEnabled {
                    pairingCard
                    statusCard
                }

                if let error = model.remoteError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                Text("""
                Why there is no standalone iPhone app: routing works by capturing \
                other apps' audio, which iOS has no API for and its sandbox exists \
                to prevent. The engine can only run where the audio hardware is.
                """)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 4)
            }
            .padding(14)
        }
    }

    private var pairingCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Pairing code").font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(model.pairingCode)
                    .font(.system(.title, design: .monospaced))
                    .kerning(6)
                    .textSelection(.enabled)
                Spacer()
                Button("New Code") { model.regeneratePairingCode() }
                    .help("Disconnects every paired device immediately")
            }
            Text("Enter this on your iPhone or iPad the first time it connects.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }

    private var statusCard: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isRemoteRunning ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            Text(model.isRemoteRunning
                ? "Listening on this network"
                : "Not listening")
            Spacer()
            Text(model.remoteClientCount == 1
                ? "1 device connected"
                : "\(model.remoteClientCount) devices connected")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(12)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
    }
}
