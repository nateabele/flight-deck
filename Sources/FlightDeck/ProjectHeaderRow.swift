import AppKit
import SwiftUI

/// A project's row in the sidebar: disclosure chevron, name, and — when collapsed — how
/// many sessions it holds and the most demanding thing any of them is doing.
///
/// The chevron sits on the leading edge, as it does in the Finder and Xcode navigators,
/// rather than using the hover-revealed trailing "Show"/"Hide" that a system `Section`
/// header draws. It is always visible: collapse state has to be legible at a glance, and
/// with the session rows hidden the chevron is the only thing that says so. The close
/// button is the opposite — destructive, so it stays out of the way until pointed at.
struct ProjectHeaderRow: View {
    @ObservedObject var store: SessionStore
    let repo: Repo
    let onClose: () -> Void

    @State private var isHovered = false
    @State private var showingFlywheelConfirmation = false
    @State private var showingFlywheelSetupConfirmation = false
    // Populated once by `.onAppear` for a plain project with no cached suggestion — see
    // `flywheelStatus`'s doc comment for why this exists at all.
    @State private var probedFlywheelStatus: FlywheelStatus?

    /// Whether this row should draw as the selected project. A pure static function rather than
    /// a computed property so `SidebarSelectionTests` can assert it without standing up a
    /// `SessionStore` or rendering SwiftUI — see `SessionSidebar`'s doc comment for why this row
    /// can no longer rely on `List`'s own selection highlight to answer the same question.
    static func isSelected(repoID: UUID, selectedProjectID: UUID?) -> Bool {
        repoID == selectedProjectID
    }

    private var isSelected: Bool {
        Self.isSelected(repoID: repo.id, selectedProjectID: store.selectedProjectID)
    }

    var body: some View {
        HStack(spacing: 4) {
            // Nothing in this row toggles anything, and that is load-bearing: a `Button` — or
            // a tap gesture, or an `NSViewRepresentable`, or a recognizer on the table —
            // consumes the mouse-down that `List`'s `.onMove` needs to begin a drag, so a
            // toggle placed here kills reordering everywhere it reaches. The chevron alone was
            // once small enough to dodge that — measured at 8×11pt, `.imageScale(.small)` — but
            // it took repeated tries to hit, and widening it to cover the name took the whole
            // row's drag with it. (An older note here blamed `.rotationEffect` for making the
            // expanded chevron a worse target. Rotating a rect transposes it, so the area is
            // identical; the glyph was simply small.)
            //
            // The toggle is `SidebarInputMonitor`'s instead. It watches mouse-DOWN passively —
            // observing it and returning it unchanged, which is what leaves the drag intact —
            // and then decides whether that press was a click only once the press is over. It
            // cannot watch the mouse-up: `NSTableView` swallows that one inside its own tracking
            // loop, where no local monitor can see it. That file's doc comment has the
            // measurements. The upshot here is that only a click landing in the chevron's zone
            // (`SidebarClickIntent.chevronZoneWidth`, measured from the row's leading edge)
            // collapses the row; a click anywhere else on it selects the project instead —
            // `SidebarInputMonitor.selectRow`, wired to `store.selectProject`, opens the
            // per-project view — and a drag anywhere on the row still reorders. Finder and the
            // Xcode navigator toggle from the whole label, so that precedent no longer applies:
            // this row now has two things a click can mean, not one, and only geometry (not a
            // view Finder's chevron has and this one doesn't) can tell them apart.
            //
            // This row is also NOT in `List`'s own selection any more (`.selectionDisabled()`
            // below): a real GUI run proved a selectable header lets `NSTableView` claim its own
            // mouse-down for row-selection tracking regardless of chevron zone, which starves the
            // click-vs-drag decision above and silently opens the project view on what should
            // have been a collapse. Since the List will not draw a highlight for a row it never
            // selects, `isSelected` below draws one by hand instead.
            //
            // For VoiceOver this row is not actuatable, and the context menu's Expand/Collapse
            // is the accessible route to collapsing a project.
            //
            // An earlier version of this comment justified that with "the button that used to be
            // here was `.accessibilityHidden(true)`, so it was never actuatable". That described
            // the chevron-only button from BEFORE this branch; the one actually removed here
            // spanned the chevron and the name and carried no hidden flag, so `children:
            // .combine` may well have unioned an activate action from it. Nobody checked with
            // Accessibility Inspector, and the claim is deleted rather than restated: measured
            // against where this branch started, the row had no actuatable control then either,
            // so there is nothing here that regressed — but that is a reading of two diffs, not
            // an observation of VoiceOver.
            Image(systemName: "chevron.right")
                .imageScale(.small)
                .foregroundStyle(isSelected ? .white : .secondary)
                .rotationEffect(.degrees(repo.isCollapsed ? 0 : 90))
                // Invisible on an empty project, but still occupying its space: collapsing the
                // layout instead would knock every project name out of alignment as sessions
                // come and go.
                //
                // The chevron's ZONE still collapses the row while empty, which the `Button`
                // this replaced did not — it was hit-test-disabled there. Geometry, not this
                // `Image`, is what decides the zone (`SidebarClickIntent.chevronZoneWidth`), so
                // making the glyph invisible does not also disable it. Deliberate: the context
                // menu's Expand/Collapse was never gated on emptiness either, so the row now
                // matches it, and collapsing an empty project does something real — it drops the
                // `.empty` placeholder row, whose whole job is to tell expanded-empty apart from
                // collapsed (see `SidebarRow`). Only the chevron GLYPH has nothing to say,
                // because there is nothing to disclose.
                .opacity(repo.sessions.isEmpty ? 0 : 1)
                // Decorative — the row's own label says "collapsed"/"expanded" in words — and
                // this is the ONLY thing here that may ever be hidden. The row is an
                // `.accessibilityElement(children: .combine)`, and combine needs at least one
                // unhidden descendant to build from: hiding anything that contains the title
                // leaves it with none, and SwiftUI drops the entire element,
                // `.accessibilityIdentifier("project-header")` with it.
                // `testProjectHeadingsReorderByDragging` caught that as "0 project headers
                // found", with an assertion message that blamed the seed flag.
                .accessibilityHidden(true)

            Text(repo.displayName)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? .white : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            // 4, not a reserved grab strip: the whole row is drag surface again now that
            // nothing in it takes the mouse-down.
            Spacer(minLength: 4)

            if repo.isCollapsed {
                Text("\(repo.sessions.count)")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                // Reused rather than reimplemented so the collapsed and expanded renderings
                // of the same state cannot drift apart.
                SessionStatusIcon(status: store.collapsedStatus(forProjectAt: repo.id))
                // Independent of the icon above: `collapsedStatus` filters out idle children,
                // so a project whose only active tab is idle-with-background-work would
                // otherwise go completely silent when collapsed — the same badge a session
                // row draws beside its own (visible) idle dot.
                if store.projectHasBackgroundWork(forProjectAt: repo.id) {
                    BackgroundWorkBadge()
                }
            }

            if isHovered {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("Close Project")
                .accessibilityLabel("Close Project")
                .accessibilityIdentifier("close-project")
            }
        }
        // Hand-drawn selection, now that the row is `.selectionDisabled()` and `List` will not
        // draw one of its own — see `isSelected`'s doc comment. `.selection` is the SDK's own
        // `ShapeStyle` for the system's selection tint, so this tracks light/dark and
        // window-active/inactive the same way a natively-selected row would, without hand-coding
        // a color. Conditioned with `if` rather than an always-present clear fill, so an
        // unselected row draws nothing extra at all.
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(.selection)
            }
        }
        // `.contentShape` stays — it is what makes hover cover the whole row rather than just
        // the drawn content. It is safe on its own; it was the `.onTapGesture` it used to sit
        // beside that killed the drag, not the hit-test shape.
        .contentShape(Rectangle())
        .onHover { isHovered = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovered)
        .animation(.easeOut(duration: 0.12), value: repo.isCollapsed)
        // `.contextMenu`'s content closure is NOT menu-open-only — measured (a build counter
        // inside the closure incremented on every `@Published` re-render, 11 builds for 1
        // mount + 10 state changes with the menu never opened) — so `flywheelStatus`'s on-demand
        // probe has to be memoized here rather than left to run on every render.
        .onAppear { probeFlywheelStatusIfNeeded() }
        .contextMenu {
            Button("New Session") { store.newClaudeTab(in: repo.url) }
            Button(repo.isCollapsed ? "Expand" : "Collapse") { toggle() }
            Divider()
            // A project is a folder, and its path is otherwise only visible in Settings. Both
            // items act on the standardized URL, the same spelling everything else compares.
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([repo.url.standardizedFileURL])
            }
            Button("Copy Path") {
                let pasteboard = NSPasteboard.general
                // A pasteboard write without a clear first appends to whatever is already
                // there under other types, which pastes as the previous contents in some apps.
                pasteboard.clearContents()
                pasteboard.setString(repo.url.standardizedFileURL.path, forType: .string)
            }
            Divider()
            Button("Close Project", role: .destructive, action: onClose)
            Divider()
            // Present for every not-yet-enabled project, not only one the probe detected at
            // add-time: `flywheelStatus` re-probes on demand (cheap FileManager checks) so a
            // plain repo with no cached suggestion still gets offered a path in. Title and
            // action fork on detection — a project already carrying `.beads`/
            // `.agent-mail.yaml` only needs `enableFlywheel`'s guard+hook install, while a
            // plain repo needs `setupFlywheel` to bootstrap those markers first. An
            // already-enabled project shows a disabled label instead of a redundant action.
            // Placed directly above "Configure…" by request.
            if isFlywheelEnabled {
                Button("Flywheel coordination enabled") {}
                    .disabled(true)
            } else if flywheelStatus.isFlywheelProject {
                Button("Enable Flywheel…") { showingFlywheelConfirmation = true }
            } else {
                Button("Setup Flywheel…") { showingFlywheelSetupConfirmation = true }
            }
            // Ellipsis because it opens a window, matching "Configure Tools…". Last rather
            // than above Close Project by request.
            Button("Configure…") {
                PreferencesOpener.open(
                    store.preferences,
                    tab: .projects,
                    project: repo.url.standardizedFileURL.path
                )
            }
            .accessibilityIdentifier("project-configure")
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier("project-header")
        // Confirmation-gated: `enableFlywheel` shells out to `am guard install` and writes a
        // git hook, so the user sees exactly what it is about to do before it runs.
        .confirmationDialog(
            "Enable Flywheel for \"\(repo.displayName)\"?",
            isPresented: $showingFlywheelConfirmation
        ) {
            Button("Enable") { Task { await store.enableFlywheel(for: repo.url) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(flywheelSetupStepsDescription)
        }
        // Same gating as above, for the plain-repo path: `setupFlywheel` additionally runs
        // `br init`/`br agents --add`/`am projects discovery-init` before `enable`'s own
        // steps, so the confirmation lists the bootstrap alongside the install.
        .confirmationDialog(
            "Setup Flywheel for \"\(repo.displayName)\"?",
            isPresented: $showingFlywheelSetupConfirmation
        ) {
            Button("Setup") { Task { await store.setupFlywheel(for: repo.url) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(flywheelInitializeStepsDescription)
        }
    }

    private func toggle() {
        store.setCollapsed(!repo.isCollapsed, forProjectAt: repo.id)
    }

    private var isFlywheelEnabled: Bool {
        store.preferences?.projectSettings(repo.url.path).flywheelEnabled == true
    }

    /// The cached probe (`store.flywheelSuggestion(for:)`) only ever holds a hit for a
    /// project `insertSession` found to already be a flywheel project at add-time — a plain
    /// repo never gets an entry, since the cache exists to drive what to *suggest*, not to
    /// remember every non-hit. The context menu needs the detection either way to choose
    /// between "Enable Flywheel…" and "Setup Flywheel…", so a miss falls back to
    /// `probedFlywheelStatus` — this row's own memoized on-demand probe, populated once by
    /// `.onAppear` (see `probeFlywheelStatusIfNeeded`) rather than re-run here. The live probe
    /// is kept as a last-resort fallback for the brief window before that `.onAppear` fires
    /// (SwiftUI's first `body` pass), not as the steady-state path.
    private var flywheelStatus: FlywheelStatus {
        store.flywheelSuggestion(for: repo.url)
            ?? probedFlywheelStatus
            ?? FlywheelProjectProbe.status(of: repo.url)
    }

    /// Runs the FileManager-backed probe at most once per row mount, into `@State`, instead of
    /// inline from `flywheelStatus`. `flywheelStatus` is read from `.contextMenu`'s content
    /// closure, and that closure is NOT lazy / menu-open-only — SwiftUI rebuilds it on every
    /// `body` evaluation, confirmed with a build counter (11 builds for 1 mount + 10
    /// `@Published` re-renders, menu never opened) — so leaving the probe inline meant a
    /// synchronous disk stat on every re-render of every plain project's row, e.g. once per
    /// keystroke landing in any session under it. Skips the probe outright once the store
    /// already has a cached suggestion, since that always wins over `probedFlywheelStatus` in
    /// `flywheelStatus` anyway.
    private func probeFlywheelStatusIfNeeded() {
        guard probedFlywheelStatus == nil, store.flywheelSuggestion(for: repo.url) == nil else { return }
        probedFlywheelStatus = FlywheelProjectProbe.status(of: repo.url)
    }

    /// What the confirmation dialog tells the user `enableFlywheel` is about to run — the
    /// same steps `FlywheelSetup.enable` will actually perform, since both consult the same
    /// `FlywheelStatus` shape.
    private var flywheelSetupStepsDescription: String {
        let status = flywheelStatus
        var steps: [String] = []
        if !status.guardInstalled { steps.append("Agent Mail commit guard") }
        if !status.beadsSyncHooksInstalled { steps.append("beads sync hook") }
        guard !steps.isEmpty else {
            return "Setup is already complete; this only marks the project as Flywheel-enabled."
        }
        return "Will install: " + steps.joined(separator: ", ") + "."
    }

    /// What the confirmation dialog tells the user `setupFlywheel` is about to run: the
    /// bootstrap `FlywheelSetup.initialize` performs on a plain repo, ahead of the same
    /// guard/hook install `flywheelSetupStepsDescription` lists.
    private var flywheelInitializeStepsDescription: String {
        "Will initialize: beads, agent-mail marker, AGENTS.md. Will install: Agent Mail commit guard, beads sync hook."
    }

    /// The count and the status glyph reach VoiceOver as words here; on screen they are a
    /// bare numeral and an unnamed symbol.
    private var accessibilityLabel: String {
        var parts = [repo.displayName]
        parts.append(repo.sessions.count == 1 ? "1 session" : "\(repo.sessions.count) sessions")
        parts.append(repo.isCollapsed ? "collapsed" : "expanded")
        if repo.isCollapsed {
            if let status = store.collapsedStatus(forProjectAt: repo.id) {
                parts.append(status.tooltip)
            }
            // Independent of `collapsedStatus`, and appended regardless of whether it found
            // anything — this is the one fact that survives every tab going idle.
            if store.projectHasBackgroundWork(forProjectAt: repo.id) {
                parts.append("background command running")
            }
        }
        return parts.joined(separator: ", ")
    }
}
