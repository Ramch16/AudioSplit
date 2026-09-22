import AudioSplitEngine
import SwiftUI

enum Section: String, CaseIterable, Identifiable {
    case routes = "Routes"
    case devices = "Devices"
    case activity = "Activity"
    case remote = "Remote"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .routes: "arrow.triangle.branch"
        case .devices: "hifispeaker.2"
        case .activity: "waveform"
        case .remote: "iphone.gen3"
        }
    }
}

struct MainWindowView: View {
    @Bindable var model: AppModel
    @State private var section: Section = .routes

    var body: some View {
        NavigationSplitView {
            List(Section.allCases, selection: $section) { item in
                Label(item.rawValue, systemImage: item.systemImage)
                    .tag(item)
            }
            .navigationSplitViewColumnWidth(min: 150, ideal: 170, max: 220)
            .safeAreaInset(edge: .bottom) { sidebarFooter }
        } detail: {
            VStack(spacing: 0) {
                // The banner lives here, not in the sidebar. A multi-line inset
                // in a narrow column has no width to wrap into, so it grew the
                // sidebar's layout height past the window and took the whole
                // split view with it — cards ended up at negative y.
                if model.mayBeMissingPermission {
                    PermissionNotice()
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                }

                switch section {
                case .routes: RoutesView(model: model)
                case .devices: DevicesView(model: model)
                case .activity: ActivityView(model: model)
                case .remote: RemoteView(model: model)
                }
            }
            .frame(minWidth: 520, minHeight: 420)
        }
        .navigationTitle("AudioSplit")
    }

    /// Recovery lives where it can always be reached, not buried in a section.
    ///
    /// Kept to a single short row: anything taller here has to fit a narrow
    /// column, and a `safeAreaInset` that cannot fit its content will stretch
    /// the sidebar rather than wrap or scroll.
    private var sidebarFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Divider()
            Button {
                model.restoreAllAudio()
            } label: {
                Label("Restore All Audio", systemImage: "arrow.uturn.backward.circle")
            }
            .buttonStyle(.borderless)
            .help("Destroy every tap and aggregate device AudioSplit owns")
            .padding(.horizontal, 10)
            .padding(.bottom, 8)
        }
    }
}

/// Shown wherever routes are active but nothing has ever produced a sample.
struct PermissionNotice: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("No audio captured", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.bold())
                .foregroundStyle(.orange)
            Text("""
            macOS returns silence rather than an error when audio capture is not \
            allowed. Grant AudioSplit access in Privacy & Security.
            """)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            Button("Open Privacy Settings") {
                if let url = URL(
                    string: "x-apple.systempreferences:com.apple.preference.security?Privacy"
                ) {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)
            .font(.caption2)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}
