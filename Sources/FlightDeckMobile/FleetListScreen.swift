import FleetKit
import SwiftUI

struct FleetListScreen: View {
    let model: FleetModel
    @State private var confirmingUnpair = false
    /// The session being renamed, and the text so far. One optional rather than an id plus a
    /// separate string: two pieces of state can disagree — a stale title against a new id is
    /// a rename applied to the wrong tab — and this way they cannot.
    @State private var renaming: Renaming?

    struct Renaming: Identifiable {
        let id: UUID
        var title: String
    }


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
                        // Driven by the Mac's own `isCollapsed`, not by local state: the
                        // Mac already owns this per project and emits `projectCollapsed`, so
                        // a phone keeping its own copy would disagree with the desk the
                        // moment either end toggled.
                        if !project.isCollapsed {
                            ForEach(project.sessions) { session in
                                sessionRow(session)
                            }
                        }
                    } header: {
                        projectHeader(project)
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
            // `item:` rather than `isPresented:` + a separate id, so the alert cannot outlive
            // the thing it is renaming.
            .alert("Rename session", isPresented: Binding(
                get: { renaming != nil },
                set: { if !$0 { renaming = nil } }
            )) {
                TextField("Name", text: Binding(
                    get: { renaming?.title ?? "" },
                    set: { renaming?.title = $0 }
                ))
                // Off for the same reason the composer's capitalisation is: a tab name is
                // frequently a branch or a path fragment, and a capital changes what it says.
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                Button("Cancel", role: .cancel) { renaming = nil }
                Button("Rename") {
                    if let renaming {
                        model.renameSession(renaming.id, to: renaming.title)
                    }
                    renaming = nil
                }
            }
            .navigationDestination(for: UUID.self) { id in
                // The session is looked up LIVE rather than captured at push time, so a
                // rename or a status change on the Mac reaches a screen that is already
                // open, and a session closed on the Mac leaves the screen able to say so
                // instead of showing a title that no longer exists. Keyed on the tab id,
                // never the conversation id — the same rule the `ForEach` above states.
                //
                // The model comes from `FleetModel` and is made once per session: built
                // here it would be rebuilt, empty, on every re-evaluation of this closure.
                SessionTimelineScreen(
                    session: model.fleet.projects
                        .flatMap(\.sessions)
                        .first { $0.id == id },
                    model: model.timelineModel(for: id)
                )
            }
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

    /// Every row opens its session, and what looks tappable is tappable.
    ///
    /// This used to be a `Button` only for an unread row, and the reason was sound at the
    /// time: `markRead` was the only action the screen had, so every other row highlighted
    /// under a finger, absorbed the touch and did nothing — which came back from testing
    /// twice as "tapping sessions does nothing". Opening a session is what was missing, and
    /// now it exists; the rule that produced the narrower `Button` is the same rule that
    /// makes every row a link today.
    ///
    /// **The link is the row's only gesture, and that is the whole point.** It used to carry
    /// a `.simultaneousGesture(TapGesture())` alongside, to send `markRead` on the way past,
    /// on the theory that a gesture *beside* a `NavigationLink` avoids the two competing
    /// recognisers a `Button` *around* one would create. It does not — it creates the same
    /// two — and that is how "tapping sessions does nothing" came back a third time. What it
    /// looked like on a real phone: the first row tapped opened, and from the moment you came
    /// back from it no row in the list would open again. Every one of those taps was
    /// recognised — UIKit logged them — and no push ever followed, because the extra
    /// recogniser had claimed the touch and the `List` row's own tap handling never saw it.
    ///
    /// So there is nothing left to race. The row is a link and the link pushes; the read mark
    /// has moved to `SessionTimelineModel.open()`, which runs when the conversation is
    /// actually on screen. That is also the truer reading of spec §8 — the mark means "I have
    /// looked at this", and a tap that never opened anything is not a look.
    /// A project's header: a chevron that collapses it, its name and count, and a `+`.
    ///
    /// The chevron is a `Button` around the whole leading group rather than the glyph alone,
    /// because a 12pt chevron is well under the 44pt touch target the platform asks for and
    /// the name beside it is dead space that wants the same job.
    private func projectHeader(_ project: WireProject) -> some View {
        HStack(spacing: 8) {
            Button {
                model.setCollapsed(!project.isCollapsed, project: project.id)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.semibold))
                        // Rotated rather than swapped for `chevron.down`: rotation animates
                        // through the intermediate angles, and a glyph swap cannot.
                        .rotationEffect(.degrees(project.isCollapsed ? 0 : 90))
                        .animation(.easeInOut(duration: 0.15), value: project.isCollapsed)
                        .foregroundStyle(.secondary)
                    Text(project.name).font(.footnote.monospaced())
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(project.isCollapsed
                ? "Expand \(project.name)" : "Collapse \(project.name)")

            Spacer()
            Text("\(project.sessions.count)").font(.caption.monospacedDigit())

            // Tap creates with the project's defaults; press and hold opens the menu. A plain
            // `Menu` would make the common case a two-step, and `primaryAction` is what keeps
            // the tap immediate while leaving the long press its own job.
            Menu {
                Button {
                    model.newSession(inProject: project.id)
                } label: {
                    Label("New session", systemImage: "plus")
                }
            } label: {
                Image(systemName: "plus")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            } primaryAction: {
                model.newSession(inProject: project.id)
            }
            .accessibilityLabel("New session in \(project.name)")
        }
        .listRowInsets(Self.rowInsets)
    }

    private func sessionRow(_ session: WireSession) -> some View {
        NavigationLink(value: session.id) {
            row(session)
        }
        .listRowInsets(Self.rowInsets)
        // `allowsFullSwipe: false`, which is the whole safety story for this gesture. A full
        // swipe closes on release with nothing in between, and this is the one action on the
        // screen that destroys something — a flick while scrolling a list of live sessions
        // would be indistinguishable from an intentional close. Requiring the button means
        // the destructive step is always a second, deliberate tap.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            Button(role: .destructive) {
                model.closeSession(session.id)
            } label: {
                Label("Close", systemImage: "xmark")
            }
        }
        // Long press. A `contextMenu` rather than a second swipe action: renaming is not
        // destructive and does not want the swipe lane's weight, and a menu leaves room for
        // whatever else belongs on a session later.
        .contextMenu {
            Button {
                // Seeded with the CURRENT title, so the common edit is a word changed rather
                // than a name retyped.
                renaming = Renaming(id: session.id, title: session.title)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
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
