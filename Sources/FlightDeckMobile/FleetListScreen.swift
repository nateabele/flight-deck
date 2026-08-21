import FleetKit
import SwiftUI

struct FleetListScreen: View {
    let model: FleetModel
    @State private var confirmingUnpair = false
    /// Set to the session a tap just marked read, purely to drive `.sensoryFeedback` below.
    /// Never read for display.
    @State private var justMarkedRead: UUID?

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
                            sessionRow(session)
                        }
                    } header: {
                        HStack {
                            Text(project.name).font(.footnote.monospaced())
                            Spacer()
                            Text("\(project.sessions.count)").font(.caption.monospacedDigit())
                        }
                        .listRowInsets(Self.rowInsets)
                    }
                }
            }
            // The default inset-grouped style STAYS, against the obvious instinct. `.plain`
            // looks like the denser choice for a terminal-adjacent list and measures as the
            // opposite one here: on an iPhone 17 Pro it puts 22pt of padding above the first
            // section header where inset-grouped puts the header flush under the bar, and its
            // inter-section gap is wider too (22pt against 17). Measured over a three-project,
            // five-session deck it ended 30pt LOWER down the screen than the style it was
            // meant to improve on. The headroom this screen was wasting was all chrome above
            // the list, not the list's own metrics.
            .opacity(isStale ? 0.5 : 1)
            .refreshable { model.reconnect() }
            // Marking a session read is a command sent to the Mac, and the row does not change
            // until the Mac echoes the event back — a round trip. The haptic is what confirms
            // the tap landed in the meantime. Triggered by `justMarkedRead`, which is only ever
            // set on a tap that actually sent something, so it cannot fire for a tap that did
            // nothing.
            .sensoryFeedback(.selection, trigger: justMarkedRead)
            // Inline, not the default large title. A large title costs roughly 52pt of height
            // to render one unchanging word on the one screen in this app that has nothing but
            // a list to show.
            .navigationTitle("Sessions")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // The Mac's name rides in the title area as a subtitle rather than taking a
                // list row of its own. It is context, not content: there is only ever one
                // paired Mac, and it was costing a full row plus that row's separators and
                // section gap at the very top of the list, immediately above the section
                // header that actually organises things. `navigationSubtitle` would be the
                // natural home for this and is iOS 26+; the deployment target is 17, so this
                // is the `.principal` slot doing the same job by hand.
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        Text("Sessions").font(.headline)
                        if let mac = model.mac {
                            Text(mac.macName)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                // Behind a menu rather than sitting in the toolbar as a bare destructive
                // button. Unpairing is rare and irreversible without the Mac in hand; it does
                // not earn the one always-visible action slot on the screen.
                ToolbarItem {
                    Menu {
                        Button("Unpair…", role: .destructive) { confirmingUnpair = true }
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .confirmationDialog(
                "Unpair from \(model.macName)? This phone will stop receiving your sessions.",
                isPresented: $confirmingUnpair, titleVisibility: .visible
            ) {
                Button("Unpair", role: .destructive) { model.unpair() }
            }
        }
    }

    /// Tighter than the platform default, and the only lever pulled for density that touches
    /// the rows themselves. It is padding, not type: the text keeps its own size at every
    /// Dynamic Type setting and the row grows to fit it, so a large-text user loses nothing a
    /// default-text user does not.
    ///
    /// What it actually buys, measured rather than assumed: nothing at all on a one-line row,
    /// which is floored at 52pt either way, and 14pt on a two-line one — a `waiting` session,
    /// whose reason caption sits under its title, drops from 66pt to the same 52pt as its
    /// neighbours instead of standing a quarter taller than them. It also takes 7pt off every
    /// section header.
    private static let rowInsets = EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16)

    /// A row is a `Button` only when tapping it does something.
    ///
    /// Every row used to be one, which meant every row highlighted under a finger and absorbed
    /// the touch — and then did nothing, because `markRead` is the only action this screen has
    /// and it only applies to an unread session. Opening a session is slice 1b and does not
    /// exist. Twice the report came back as "tapping sessions does nothing", which is exactly
    /// what a control that looks live and is not will always produce. After this, what looks
    /// tappable is what is tappable.
    ///
    /// `isConnected` is part of that and not belt-and-braces: `FleetConnector.send` is a silent
    /// no-op while disconnected, so an unread row on a stale fleet is a button whose action
    /// cannot run. The list is already dimmed in that state; this stops it also being falsely
    /// interactive.
    @ViewBuilder
    private func sessionRow(_ session: WireSession) -> some View {
        if isConnected && session.isUnread {
            Button {
                model.markRead(session.id)
                justMarkedRead = session.id
            } label: {
                row(session)
            }
            .buttonStyle(.plain)
            .listRowInsets(Self.rowInsets)
        } else {
            row(session)
                .listRowInsets(Self.rowInsets)
        }
    }

    /// The font is set HERE, on the title itself, and not once on the enclosing `List`.
    ///
    /// `List { … }.font(…)` looks like it dresses every row, and it does not: a `List` hands
    /// its rows to the platform's own cell machinery, which resolves each row's content in
    /// an environment of its own rather than the one the modifier wrote. The result is not
    /// even uniformly wrong — some rows inherited the monospaced font and their neighbours
    /// rendered in the system font, in the same list, which is what sent this back from
    /// testing. (Rendering the identical hierarchy offscreen on the Mac shows the stronger
    /// form: *no* row content inherits it there, headers included, and only the `Text`s that
    /// name their own font survive.)
    ///
    /// So every `Text` in this file names its own font — the section headers, the banners,
    /// the empty state and the glyph's subagent count already did, and the title was the one
    /// that did not. The terminal idiom is deliberate (see the headers' `.monospaced()`), so
    /// it is stated where it has to hold rather than inherited from a container that cannot
    /// be relied on to pass it down.
    private func row(_ session: WireSession) -> some View {
        HStack(spacing: 8) {
            SessionStatusGlyph(session: session)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(.body, design: .monospaced))
                if let waitingFor = session.waitingFor {
                    Text(waitingFor).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
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
