import SwiftUI

/// Settings → Hosting → Code Index: the machine-wide code index daemon (`fdindex`) that answers
/// every agent's `qartez_*` queries. It runs whether or not Flight Deck does; this section only
/// reads its status over its socket and can restart it.
struct IndexStatusSection: View {
    @ObservedObject var model: IndexStatusModel

    /// Views listed before "and N more": the tab is a settings pane, not a monitor.
    private static let shownViews = 5

    var body: some View {
        Section("Code Index") {
            statusLine
            if case .running(let status) = model.state {
                details(status)
            }
            HStack(spacing: 8) {
                // `service restart` starts a stopped daemon too, so the one button covers both.
                Button(model.state == .notRunning ? "Start Index" : "Restart Index") { model.restart() }
                    .disabled(model.restarting)
                    .help("Runs `fdindex service restart`. Agents' index queries fail for a moment while it restarts.")
                    .accessibilityIdentifier("index-restart")
                if model.restarting {
                    ProgressView().controlSize(.small)
                }
                Spacer()
            }
            if let error = model.actionError {
                caption(error, color: .red, id: "index-action-error")
            } else if let note = model.actionNote {
                caption(note, color: .secondary, id: "index-action-note")
            }
            Text("One index serves every agent on this Mac, with or without Flight Deck open.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Polled only while the tab is on screen, like the hostd's admin poll above it.
        .task {
            while !Task.isCancelled {
                await model.refresh().value
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    @ViewBuilder
    private var statusLine: some View {
        switch model.state {
        case .unknown:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                status("Reading…", color: .secondary)
            }
        case .running(let s):
            status(IndexStatusText.running(s), color: .secondary)
        case .notRunning:
            status("Not running. The next agent query starts it.", color: .secondary)
        case .failed(let message):
            status(message, color: .red)
        }
    }

    @ViewBuilder
    private func details(_ s: IndexDaemonStatus) -> some View {
        LabeledContent("Memory") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(IndexStatusText.memory(s))
                if let fraction = IndexStatusText.memoryFraction(s) {
                    ProgressView(value: min(fraction, 1))
                        .tint(fraction > 1 ? .orange : .accentColor)
                        .frame(width: 160)
                }
            }
        }
        .accessibilityIdentifier("index-memory")

        LabeledContent("Store", value: IndexStatusText.store(s))
            .accessibilityIdentifier("index-store")

        let views = s.views ?? []
        LabeledContent("Views") {
            VStack(alignment: .trailing, spacing: 2) {
                Text(views.isEmpty ? "None" : "\(views.count)")
                ForEach(Array(views.prefix(Self.shownViews).enumerated()), id: \.offset) { _, view in
                    Text(IndexStatusText.view(view))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(view.worktree ?? "")
                }
                if views.count > Self.shownViews {
                    Text("and \(views.count - Self.shownViews) more").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityIdentifier("index-views")

        let builds = s.builds ?? []
        LabeledContent("Builds") {
            VStack(alignment: .trailing, spacing: 2) {
                if builds.isEmpty {
                    Text("None running")
                } else {
                    ForEach(Array(builds.enumerated()), id: \.offset) { _, build in
                        Text(IndexStatusText.build(build)).lineLimit(1).truncationMode(.middle)
                    }
                }
            }
        }
        .accessibilityIdentifier("index-builds")

        LabeledContent("Last error") {
            Text(IndexStatusText.lastError(s) ?? "None")
                .foregroundStyle(IndexStatusText.lastError(s) == nil ? Color.secondary : Color.orange)
                .multilineTextAlignment(.trailing)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .accessibilityIdentifier("index-last-error")
    }

    private func status(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("index-status")
    }

    private func caption(_ text: String, color: Color, id: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier(id)
    }
}

extension IndexStatusModel {
    /// The machine's real daemon: its default socket, restarted with the bundled `fdindex`.
    static func live() -> IndexStatusModel {
        let client = IndexDaemonClient(socketPath: IndexDaemonClient.defaultSocketPath())
        return IndexStatusModel(client: client,
                                restarter: FdindexServiceRestarter(binary: FdindexServiceRestarter.bundled(), client: client))
    }

    /// Reads a socket nothing listens on and restarts nothing: tests and UITest reset launches.
    static func inert() -> IndexStatusModel {
        IndexStatusModel(client: IndexDaemonClient(socketPath: "/tmp/fd-index-inert-\(UUID().uuidString.prefix(8)).sock"),
                         restarter: InertIndexRestarter())
    }
}
