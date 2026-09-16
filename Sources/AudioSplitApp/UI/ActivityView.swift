import AudioSplitEngine
import SwiftUI

/// What is actually happening right now: which apps are producing audio, where
/// it is going, and what the engine has built to make that happen.
///
/// This is also where an unroutable app becomes visible. Some processes never
/// resolve to an owning application and simply cannot be routed.
struct ActivityView: View {
    @Bindable var model: AppModel
    @State private var showIdle = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                playingSection
                if !model.idleAudioApps.isEmpty { idleSection }
                engineSection
            }
            .padding(14)
        }
    }

    private var playingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Playing Now", systemImage: "waveform")
                .font(.headline)

            if model.appsPlayingNow.isEmpty {
                Text("Nothing is playing audio right now.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.appsPlayingNow) { app in
                    AudibleAppRow(model: model, app: app)
                }
            }
        }
    }

    /// Everything that holds an audio process but is silent. This is a long list
    /// — most apps keep an audio process alive without using it — so it stays
    /// collapsed rather than burying the rows that matter.
    private var idleSection: some View {
        DisclosureGroup(isExpanded: $showIdle) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(model.idleAudioApps) { app in
                    AudibleAppRow(model: model, app: app)
                }
            }
            .padding(.top, 4)
        } label: {
            Text("\(model.idleAudioApps.count) other apps have audio open but are silent")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var engineSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Engine", systemImage: "gearshape.2")
                .font(.headline)

            if model.liveAggregates.isEmpty {
                Text("No aggregate devices. Nothing is being captured.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(model.liveAggregates, id: \.aggregateUID) { aggregate in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(aggregate.destinationName).fontWeight(.medium)
                            Spacer()
                            Text("\(Int(aggregate.sampleRate)) Hz · \(aggregate.outputChannelCount) ch")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        Text("\(aggregate.taps.count) tap\(aggregate.taps.count == 1 ? "" : "s") · "
                            + aggregate.taps.map(\.appBundleID).joined(separator: ", "))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        // An aggregate that has run many cycles without ever
                        // mixing anything is the signature of a capture that is
                        // silently failing, not of an idle app.
                        if aggregate.activeCycles == 0, aggregate.emptyCycles > 500 {
                            Label("Running but capturing nothing", systemImage: "exclamationmark.triangle")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    .padding(10)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                }
            }

            if let error = model.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(.top, 4)
            }
        }
    }
}


/// One app in the activity list, with where its audio is going.
struct AudibleAppRow: View {
    @Bindable var model: AppModel
    let app: AudibleApp

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(app.isProducingOutput ? Color.green : Color.clear)
                .frame(width: 6, height: 6)
            AppIcon(bundleID: app.bundleID, name: app.displayName, size: 18)
            Text(app.displayName).lineLimit(1)
            if app.processCount > 1 {
                Text("\(app.processCount) processes")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            destination
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var destination: some View {
        if let route = model.routes.first(where: { $0.appBundleID == app.bundleID }) {
            Text(model.deviceName(forUID: route.destinationDeviceUID))
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if !app.isRoutable {
            // Says why there is no route rather than implying the user forgot.
            Text("system audio")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .help("This is a system process, not an app that can be routed.")
        } else if app.isProducingOutput {
            Text("not routed")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}
