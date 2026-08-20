import FleetKit
import SwiftUI

struct FleetListScreen: View {
    let model: FleetModel
    @State private var confirmingUnpair = false

    var body: some View {
        NavigationStack {
            List {
                connectionBanner
                // Gated on `isConnected`, not just on the fleet being empty: on a cold
                // launch or a fresh pairing the fleet is empty because nothing has arrived
                // yet, not because there's genuinely nothing to show — and the "Connecting…"
                // banner above already says that. Showing both at once claimed two different
                // things about the same absence of data.
                if model.fleet.projects.isEmpty && isConnected {
                    emptyState
                }
                ForEach(model.fleet.projects) { project in
                    Section {
                        // Keyed on the session's tab id, never its conversation id — the
                        // latter is not stable across a re-pin and, for codex, differs from
                        // the tab id from birth.
                        ForEach(project.sessions) { session in
                            Button {
                                // A no-op tap on an already-read row shouldn't fire a command
                                // at all — and `FleetConnector.send` is a silent no-op while
                                // disconnected, so tapping a stale row would otherwise give no
                                // feedback either way. Only send when there's something to do.
                                if session.isUnread { model.markRead(session.id) }
                            } label: {
                                row(session)
                            }
                            .buttonStyle(.plain)
                        }
                    } header: {
                        HStack {
                            Text(project.name).font(.footnote.monospaced())
                            Spacer()
                            Text("\(project.sessions.count)").font(.caption.monospacedDigit())
                        }
                    }
                }
            }
            .font(.system(.body, design: .monospaced))
            .opacity(isStale ? 0.5 : 1)
            .refreshable { model.reconnect() }
            .navigationTitle(model.macName)
            .toolbar {
                Button("Unpair", role: .destructive) { confirmingUnpair = true }
            }
            .confirmationDialog(
                "Unpair from \(model.macName)? This phone will stop receiving your sessions.",
                isPresented: $confirmingUnpair, titleVisibility: .visible
            ) {
                Button("Unpair", role: .destructive) { model.unpair() }
            }
        }
    }

    private func row(_ session: WireSession) -> some View {
        HStack(spacing: 8) {
            SessionStatusGlyph(session: session)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                if let waitingFor = session.waitingFor {
                    Text(waitingFor).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            if session.isUnread {
                Circle().fill(.tint).frame(width: 8, height: 8)
                    .accessibilityLabel("Unread")
            }
        }
    }

    /// Only `.lost` dims the list. `.idle`/`.searching` are the normal shape of a cold launch
    /// or a fresh pairing — the fleet has simply never spoken yet, which is not the same
    /// as having gone quiet after being live, and dimming it would visually claim staleness
    /// that never happened.
    private var isStale: Bool {
        if case .lost = model.state { return true }
        return false
    }

    private var isConnected: Bool {
        if case .connected = model.state { return true }
        return false
    }

    @ViewBuilder
    private var connectionBanner: some View {
        switch model.state {
        case .connected:
            EmptyView()
        case .idle, .searching:
            Label("Connecting to \(model.macName)…", systemImage: "antenna.radiowaves.left.and.right")
                .font(.footnote)
                .foregroundStyle(.secondary)
        case .lost(let retryingIn):
            staleBanner(retryingIn: retryingIn)
        }
    }

    /// A disconnected fleet must look disconnected, and say what it's showing instead of
    /// current data. A list that keeps rendering the last thing it heard, indistinguishable
    /// from a live one, is the single most misleading thing this app could show.
    ///
    /// `.lost` is reachable straight from `.searching`, with no `.connected` in between — a
    /// Mac that never once answered still eventually times out into `.lost`. So the *primary*
    /// claim here, "showing what it last said", is gated on `model.lastLive` too, not only the
    /// timestamp sentence beneath it: a fleet that has never been live has nothing it "last
    /// said", and claiming otherwise was the whole bug this banner exists to not repeat.
    private func staleBanner(retryingIn: TimeInterval) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            if let lastLive = model.lastLive {
                Label(
                    "Not connected to \(model.macName) — showing what it last said.",
                    systemImage: "wifi.slash"
                )
                Text("Last live \(lastLive.formatted(.relative(presentation: .named))). "
                    + "Retrying in \(Int(retryingIn))s.")
            } else {
                Label(
                    "Couldn't reach \(model.macName). Retrying in \(Int(retryingIn))s.",
                    systemImage: "wifi.slash"
                )
            }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
    }

    private var emptyState: some View {
        Text("No sessions yet. Open a project in Flight Deck on \(model.macName) to see it here.")
            .font(.footnote)
            .foregroundStyle(.secondary)
    }
}
