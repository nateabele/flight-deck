import FleetKit
import SwiftUI

struct FleetListScreen: View {
    let model: FleetModel
    @State private var confirmingUnpair = false

    var body: some View {
        NavigationStack {
            List {
                if !model.isLive { staleBanner }
                ForEach(model.fleet.projects) { project in
                    Section {
                        // Keyed on the session's tab id, never its conversation id — the
                        // latter is not stable across a re-pin and, for codex, differs from
                        // the tab id from birth.
                        ForEach(project.sessions) { session in
                            row(session)
                                .onTapGesture { model.markRead(session.id) }
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
            .opacity(model.isLive ? 1 : 0.5)
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
            }
        }
    }

    /// A disconnected fleet must look disconnected. A list that keeps rendering the last
    /// thing it heard, indistinguishable from a live one, is the single most misleading
    /// thing this app could show.
    private var staleBanner: some View {
        Label(
            "Not connected to \(model.macName) — showing what it last said.",
            systemImage: "wifi.slash"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
}
