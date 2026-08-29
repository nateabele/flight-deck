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

    /// The session the close confirmation is about, and its name for the prompt.
    ///
    /// One optional rather than an id plus a separate `Bool`, for the reason `Renaming` is
    /// one: two pieces of state can disagree, and here the disagreement closes the wrong tab.
    /// Carrying the title too means the prompt can name what it is about — "Close this
    /// session?" over a list of eight of them is a question the reader cannot answer.
    @State private var closing: Closing?

    struct Closing: Identifiable {
        let id: UUID
        let title: String
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
                newSessionMenu(for: project)
            } label: {
                Image(systemName: "plus")
                    .font(.footnote.weight(.semibold))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            } primaryAction: {
                model.newSession(inProject: project.id)
            }
            .disabled(model.newSessionOptions[project.id]?.isEmpty == true)
            .accessibilityLabel("New session in \(project.name)")
        }
        .listRowInsets(Self.rowInsets)
    }

    /// The project's New Session rows, mirroring the menu at the foot of the desktop sidebar.
    ///
    /// **Drawn from the Mac's answer, never rebuilt here.** Which agents appear, in what order,
    /// flat or nested, and which account wears the tick are all decided by
    /// `NewSessionAffordance.menu` on the Mac; a second implementation on this side would drift
    /// the first time one of those rules moved. This only chooses how a row looks.
    ///
    /// **A project with no answer yet still gets a row.** That is the request in flight, or a
    /// Mac older than this feature which will never send one — so the fallback is a supported
    /// state, not a placeholder. A project answered with *no* rows is the other thing entirely:
    /// nothing can be launched, and the `+` above is disabled rather than offering a tap that
    /// can only fail.
    @ViewBuilder
    private func newSessionMenu(for project: WireProject) -> some View {
        let options = model.newSessionOptions[project.id]
        if let options, !options.isEmpty {
            // Grouped by agent, in arrival order — `Dictionary(grouping:)` would lose it, and
            // the order is the ⌘N ladder.
            ForEach(agentGroups(in: options), id: \.agent) { group in
                if group.rows.count == 1, group.rows[0].accountName == nil {
                    newSessionRow(project: project, option: group.rows[0], flat: true)
                } else {
                    Menu("New \(group.name) Session") {
                        ForEach(group.rows, id: \.index) { option in
                            newSessionRow(project: project, option: option, flat: false)
                        }
                    }
                }
            }
        } else if options == nil {
            Button {
                model.newSession(inProject: project.id)
            } label: {
                Label("New session", systemImage: "plus")
            }
        }
    }

    /// One row. The tick marks the account a plain tap would use, and **only inside a
    /// submenu**: on an agent's only account it would mark a choice that was never offered —
    /// the same rule, for the same reason, as `SessionSidebar.newSessionMenuRow`.
    @ViewBuilder
    private func newSessionRow(
        project: WireProject, option: WireNewSessionOption, flat: Bool
    ) -> some View {
        let name = flat ? "New \(option.agentName) Session" : (option.accountName ?? option.agentName)
        Button {
            model.newSession(inProject: project.id, agent: option.agent, accountIndex: option.index)
        } label: {
            if !flat, option.isDefault {
                Label(name, systemImage: "checkmark")
            } else {
                Text(name)
            }
        }
    }

    /// The rows an agent at a time, keeping the order they arrived in.
    struct AgentGroup: Equatable {
        let agent: String
        let name: String
        let rows: [WireNewSessionOption]
    }

    /// **Order preserved, never sorted.** Position is what binds an agent to its keyboard chord
    /// on the Mac, so a phone that sorted would quietly disagree with the sidebar about what
    /// ⌘N does. Tested rather than trusted — see `FleetListScreenTests`.
    static func agentGroups(in options: [WireNewSessionOption]) -> [AgentGroup] {
        var order: [String] = []
        var rows: [String: [WireNewSessionOption]] = [:]
        var names: [String: String] = [:]
        for option in options {
            if rows[option.agent] == nil {
                order.append(option.agent)
                names[option.agent] = option.agentName
            }
            rows[option.agent, default: []].append(option)
        }
        return order.map {
            AgentGroup(agent: $0, name: names[$0] ?? $0, rows: rows[$0] ?? [])
        }
    }

    private func agentGroups(in options: [WireNewSessionOption]) -> [AgentGroup] {
        Self.agentGroups(in: options)
    }

    struct UnreadAction: Equatable {
        let title: String        // "Unread" | "Read"
        let systemImage: String  // "circle.fill" | "circle"
        let marksUnread: Bool
    }

    /// The leading swipe button's label and behaviour for one session — the same job as
    /// `agentGroups(in:)` above: a pure decision pulled out of the row so the unit suite can
    /// assert it without rendering the thing that reads it.
    static func unreadAction(for session: WireSession) -> UnreadAction {
        session.isUnread
            ? UnreadAction(title: "Read", systemImage: "circle", marksUnread: false)
            : UnreadAction(title: "Unread", systemImage: "circle.fill", marksUnread: true)
    }

    private func sessionRow(_ session: WireSession) -> some View {
        NavigationLink(value: session.id) {
            row(session)
        }
        .listRowInsets(Self.rowInsets)
        // `allowsFullSwipe: true`, the mirror image of the trailing lane's `false` below —
        // and for the mirror-image reason. Unread/read is a fact, and the same flick that set
        // it puts it back, so the deliberateness a required tap buys the destructive lane is
        // not worth charging for here — with one caveat: nothing here is set optimistically
        // (`FleetModel.swift:234-238`), so a second full swipe undoes the first only once the
        // Mac's `unreadChanged` echo has landed and the button has relabelled itself; fired
        // before that, it repeats the same command instead of reversing it.
        //
        // **Why a toggle, not a bare "Mark as Unread" button.** The read mark is set
        // automatically by `SessionTimelineModel.open()`, which runs the moment a conversation
        // reaches the screen. So without a way to mark read again from this list, the only way
        // to undo an accidental Unread swipe is to open the session, which is the one thing the
        // reader swiped to avoid doing. The toggle makes the gesture its own undo.
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            let unread = Self.unreadAction(for: session)
            Button {
                if unread.marksUnread {
                    model.markUnread(session.id)
                } else {
                    model.markRead(session.id)
                }
            } label: {
                Label(unread.title, systemImage: unread.systemImage)
            }
            .tint(.blue)
            // Second, not first: staying off the full swipe above is correct here, because
            // this opens a text prompt rather than restoring a fact the same gesture undoes.
            Button {
                renaming = Renaming(id: session.id, title: session.title)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            .tint(.indigo)
        }
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
        // Long press, alongside both swipe lanes now — not for anything exclusive to it
        // any more. The trailing lane above still holds exactly one destructive verb and
        // nothing else — that has not changed. A second lane, on the *leading* edge, is a
        // different judgement, made above; the menu stays regardless, because it is the
        // discoverable route — a reader finds it by holding a row — and the place a Mac
        // reader already knows to look.
        //
        // **The items, their order and the divider all mirror `SessionSidebar`'s menu**, and
        // the mirroring is the point rather than a coincidence: this is the same fleet seen
        // from a second screen, and a reader who knows where "Mark as Unread" sits on the Mac
        // should not have to learn a second arrangement to find it here.
        .contextMenu {
            // Plain, not a toggle like the swipe lane's version of this same action above: a
            // menu shows every verb at once and can afford one that only ever means one thing,
            // where a swipe lane spends its one slot for this verb on a no-op half the time if
            // it does not toggle. Matches `SessionSidebar.swift:276` on the Mac, which keeps
            // the same asymmetry for the same reason.
            Button {
                model.markUnread(session.id)
            } label: {
                // The dot the row itself draws when a session is unread, rather than mail's
                // envelope: what this restores is `SessionStatusGlyph`'s fill, and naming it
                // with a different metaphor than the thing it changes is how a menu item ends
                // up meaning something slightly other than what it does.
                Label("Mark as Unread", systemImage: "circle.fill")
            }
            Divider()
            Button {
                // Seeded with the CURRENT title, so the common edit is a word changed rather
                // than a name retyped.
                renaming = Renaming(id: session.id, title: session.title)
            } label: {
                Label("Rename", systemImage: "pencil")
            }
            // **Confirmed, where the swipe lane's Close is not**, and the asymmetry is
            // deliberate rather than an inconsistency. The swipe already spends two separate
            // gestures on the way here — `allowsFullSwipe: false` means the lane opens and
            // then waits to be tapped — so it has the deliberateness built into the gesture.
            // A menu item does not: it is one tap, on a control that opened under the finger
            // that was already resting on the row. So this one asks.
            Button(role: .destructive) {
                closing = Closing(id: session.id, title: session.title)
            } label: {
                Label("Close Session", systemImage: "xmark")
            }
        }
        // `item:` rather than `isPresented:` plus a separate id, for the reason the rename
        // alert takes the same shape: the dialog cannot outlive the session it is about, so
        // a fleet event that removes the row while the prompt is up cannot leave a Close
        // pointed at whatever id took its place.
        .confirmationDialog(
            "Close “\(closing?.title ?? "")”?",
            isPresented: Binding(
                get: { closing != nil },
                set: { if !$0 { closing = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Close Session", role: .destructive) {
                if let closing { model.closeSession(closing.id) }
                closing = nil
            }
            Button("Cancel", role: .cancel) { closing = nil }
        } message: {
            // **Recoverable, and it names where.** A close from the phone runs the same
            // `SessionStore.closeSession` a local one does, which records the whole session —
            // id and pinned conversation included — so the Mac's "Reopen Closed Session"
            // rebuilds this tab *on the same conversation* rather than starting a fresh one.
            // Saying so is the difference between a reader deciding this is reversible and a
            // reader deciding not to risk it; saying it without naming the Mac would be a
            // promise this screen cannot keep, because there is no reopen from here.
            Text("The agent stops. You can bring it back with Reopen Closed Session on your "
                 + "Mac, and it resumes this conversation.")
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
            // Gated on `activity` existing, not just on the flag: a fresh pairing (or a
            // relaunch) can seed `hasBackgroundWork` from the Mac's snapshot before the first
            // registry tick reports an `activity`, and a badge beside an empty status column
            // would claim something about a tab this build cannot yet vouch for — the same
            // reasoning `SessionStatusGlyph`'s own `nil` branch is built on.
            if session.hasBackgroundWork, session.activity != nil {
                Image(systemName: "terminal.fill")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.green)
                    .accessibilityHidden(true)   // `SessionStatusGlyph.label` already says it
            }
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
