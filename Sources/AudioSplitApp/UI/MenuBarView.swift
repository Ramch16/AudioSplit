import AudioSplitEngine
import AudioSplitShared
import SwiftUI

struct MenuBarView: View {
    @Bindable var model: AppModel
    @State private var isAddingRoute = false
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if model.routes.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.routes) { route in
                            RouteEditorView(model: model, route: route)
                            if route.id != model.routes.last?.id { Divider() }
                        }
                    }
                }
                .frame(maxHeight: 340)
            }

            Divider()
            InputPickerView(model: model)
            Divider()
            if let message = model.lastError { errorBanner(message) }
            if model.mayBeMissingPermission { permissionBanner }
            footer
        }
        .frame(width: 380)
    }

    private var header: some View {
        HStack {
            Text("AudioSplit").font(.headline)
            Spacer()
            Button {
                model.refreshInventory()
                isAddingRoute = true
            } label: {
                Label("Add Route", systemImage: "plus")
                    .labelStyle(.iconOnly)
            }
            .buttonStyle(.borderless)
            .help("Route an app to a device")
            .popover(isPresented: $isAddingRoute, arrowEdge: .bottom) {
                AppPickerView(model: model, isPresented: $isAddingRoute)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Text("No routes yet")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("Add a route to send an app to a device of its own.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
    }

    private func errorBanner(_ message: String) -> some View {
        Label(message, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .lineLimit(3)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
    }

    private var permissionBanner: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("No audio is being captured", systemImage: "mic.slash.fill")
                .font(.caption.bold())
            Text("""
            Routes are active but silent. macOS returns silence rather than an \
            error when audio capture is not allowed. Grant AudioSplit access \
            under Privacy & Security.
            """)
            .font(.caption2)
            .foregroundStyle(.secondary)
            Button("Open Privacy Settings") {
                let url = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy"
                )!
                NSWorkspace.shared.open(url)
            }
            .buttonStyle(.link)
            .font(.caption2)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var footer: some View {
        HStack {
            Button("Open AudioSplit") {
                openWindow(id: "main")
                // A menu bar popover does not activate the app, so the window
                // would otherwise open behind whatever is in front.
                NSApp.activate(ignoringOtherApps: true)
            }
            .buttonStyle(.borderless)
            Spacer()
            Button("Restore") { model.restoreAllAudio() }
                .buttonStyle(.borderless)
                .help("Destroy every tap and aggregate device AudioSplit owns")
            Button("Quit") { model.quit() }
                .buttonStyle(.borderless)
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
