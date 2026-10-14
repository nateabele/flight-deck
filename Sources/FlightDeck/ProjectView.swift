import IntakeKit
import SwiftUI

/// `.sheet(item:)` needs `Identifiable`; Foundation's `UUID` doesn't carry that conformance
/// on its own. Used only by `ProjectView`'s release-review sheet below.
extension UUID: Identifiable {
    public var id: UUID { self }
}

/// The per-project detail view a project row opens. This plan gives it the Intakes list;
/// the Beads tab arrives with the next plan.
struct ProjectView: View {
    @ObservedObject var store: SessionStore
    let repo: Repo

    /// `ProjectView` otherwise only observes `store`, which never republishes when an
    /// intake's state changes — that lives on `IntakeService`'s own `@Published`. Observing
    /// it directly (rather than reading through `store.intakeService` in the body) is what
    /// makes triage/release progress redraw the list and detail pane live.
    @ObservedObject private var intakeService: IntakeService
    /// The composer's unsent request. Seeded from, and written back to, `IntakeService`
    /// (`setDraft`), because this view's `@State` resets on every switch to another project or
    /// tab and back — local state for typing, the service for keeping it.
    @State private var intent: String
    /// The composer in the detail pane (`ExpandedIntakeComposer`) instead of at the list's foot,
    /// kept by the service alongside the draft. One draft (`intent`) behind both.
    @State private var composerExpanded: Bool
    /// Both the sheet's presentation and its content, same shape as
    /// `DevicesSettingsTab.pairingWindow` — see the `.sheet(item:)` below.
    @State private var reviewIntakeID: UUID?
    // Mirrors `ProjectHeaderRow`'s two confirmation flags and drives the same
    // `.flywheelEnableConfirmations` modifier — see that row's `flywheelStatus` doc comment
    // for why the probe result these gate on is memoized rather than read live.
    @State private var showingFlywheelConfirmation = false
    @State private var showingFlywheelSetupConfirmation = false
    @State private var probedFlywheelStatus: FlywheelStatus?
    /// The expanded list's width, dragged at its trailing edge (`IntakesColumnEdge`) within
    /// `paneWidths` — view state, as the `HSplitView` divider's position it replaces was.
    @State private var paneWidth: CGFloat = 320
    private static let paneWidths: ClosedRange<CGFloat> = 280...420
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.undoManager) private var undoManager
    /// The plan action waiting on the human's say-so — Move to Trash always, Archive only while
    /// a round runs (anything else archives at once: it is reversible, and ⌘Z undoes it).
    @State private var confirming: PlanConfirmation?
    /// Whether the Intakes list has keyboard focus: ⌃⌘A and ⌘⌫ act on its selected plan only
    /// then, so ⌘⌫ in the request field or the plan editor still deletes text, not a plan.
    @FocusState private var listFocused: Bool

    private enum PlanConfirmation: Identifiable {
        case stopAndArchive(UUID), trash(UUID)
        var id: UUID { switch self { case .stopAndArchive(let id), .trash(let id): id } }
    }

    init(store: SessionStore, repo: Repo) {
        self.store = store
        self.repo = repo
        self._intakeService = ObservedObject(wrappedValue: store.intakeService)
        let project = repo.url.standardizedFileURL.path
        self._intent = State(initialValue: store.intakeService.draft(forProject: project))
        self._composerExpanded = State(initialValue: store.intakeService.composerExpanded(forProject: project))
    }

    /// Standardized so it matches how `SessionStore` keys flywheel identities — a
    /// differently-spelled path would turn every intake lookup below into a silent miss
    /// (parallel-17-19-contract.md).
    private var projectPath: String { repo.url.standardizedFileURL.path }

    /// The list's rows: the active plans, plus the archived ones under Show Archived.
    private var intakes: [Intake] { intakeService.listedIntakes(forProject: projectPath) }

    /// Binds the List's selection through `IntakeService` instead of local `@State` — the bug
    /// this fixes is that `@State`: switching to another project's row and back gives this
    /// view a fresh identity (it's keyed by `Repo`), so SwiftUI reset the selection along with
    /// it. The service is per-project already and outlives the view, so it doesn't.
    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { intakeService.selection(forProject: projectPath) },
            set: { intakeService.select($0, inProject: projectPath) }
        )
    }

    /// The detail pane's trailing inspector (spec §3): hidden by default, toggled from the
    /// toolbar or ⌥⌘I, and opened by the awaiting-choice body's Edit in Inspector and the notes.
    /// Bound through `IntakeService` for the reason the selection is: as `@State` here it closed
    /// whenever the human went to another project or tab and came back.
    private var inspectorBinding: Binding<Bool> {
        Binding(
            get: { intakeService.inspectorShown(forProject: projectPath) },
            set: { intakeService.setInspectorShown($0, inProject: projectPath) }
        )
    }

    /// Whether the Intakes list is collapsed to its rail — per project, through `IntakeService`
    /// for the reason the selection and the inspector are.
    private var listCollapsed: Bool { intakeService.intakeListCollapsed(forProject: projectPath) }

    /// Same predicate `ProjectHeaderRow`'s context-menu item reads — `FlywheelEnablement`
    /// is the one place that answers "has this project opted in", so the empty-state switch
    /// below and the header's menu item can never disagree about a project.
    private var isFlywheelEnabled: Bool {
        FlywheelEnablement.isEnabled(store.preferences?.projectSettings(repo.url.path))
    }

    /// Same on-demand probe formula `ProjectHeaderRow.flywheelStatus` resolves, over this
    /// view's own memoized `probedFlywheelStatus` rather than that row's — the two views
    /// never coexist for the same project, but each still needs its own `@State` slot to
    /// memoize into.
    private var flywheelStatus: FlywheelStatus {
        FlywheelEnableResolution.status(for: repo.url, store: store, cached: probedFlywheelStatus)
    }

    var body: some View {
        let _ = RenderProbe.hit("project")
        Group {
            if isFlywheelEnabled {
                intakeSplitView
            } else {
                disabledEmptyState
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("project-view")
        .onAppear { probeFlywheelStatusIfNeeded() }
        .onChange(of: intent) { _, text in intakeService.setDraft(text, inProject: projectPath) }
        .onChange(of: composerExpanded) { _, expanded in intakeService.setComposerExpanded(expanded, inProject: projectPath) }
        .sheet(item: $reviewIntakeID) { id in
            ReleaseReviewView(store: store, intakeID: id, onClose: { reviewIntakeID = nil })
        }
        .alert(confirmationTitle, isPresented: Binding(
            get: { confirming != nil }, set: { if !$0 { confirming = nil } }
        ), presenting: confirming) { confirmation in
            switch confirmation {
            case .stopAndArchive(let id):
                Button("Stop and Archive") { archive(id) }
                // Cancel is the default (Return) for a destructive confirmation, per the HIG.
                Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
            case .trash(let id):
                Button("Move to Trash", role: .destructive) { trash(id) }
                Button("Cancel", role: .cancel) {}.keyboardShortcut(.defaultAction)
            }
        } message: { confirmation in
            switch confirmation {
            case .stopAndArchive:
                Text("A round is running. It stops first; the plan and its history stay on disk.")
            case .trash(let id):
                Text(intakeService.isRoundRunning(id)
                     ? "Its drafts, notes and round history go with it. The running round stops first."
                     : "Its drafts, notes and round history go with it.")
            }
        }
        .flywheelEnableConfirmations(
            repo: repo, store: store, status: flywheelStatus,
            showingEnableConfirmation: $showingFlywheelConfirmation,
            showingSetupConfirmation: $showingFlywheelSetupConfirmation
        )
    }

    /// A project that hasn't opted in gets no intake form at all — triaging into a bead
    /// graph that doesn't exist yet would just produce intakes nothing can ever release.
    /// Styled like `RootView`'s no-session state (`ContentUnavailableView` + one action)
    /// rather than the split intake layout, since there is nothing here to split.
    private var disabledEmptyState: some View {
        ContentUnavailableView {
            // The splash art (`Assets.xcassets/FlightControlSplash`) replaces the refresh
            // glyph the SF Symbol initializer would draw here — `ContentUnavailableView`
            // applies its own big-icon-over-title layout to whatever `Label` it's handed, so
            // swapping the icon view is enough; the title keeps the same styling as before.
            // `bundle: Bundle(for: SessionStore.self)` rather than the default `Bundle.main`:
            // under `scripts/test-unit.sh` the main bundle is the `xctest` tool, not
            // "Flight Deck.app" — same seam `ClaudePluginLocation` and `SessionDaemon.bundledBinary`
            // exist for — and `Bundle(for:)` on a class this module compiles resolves to the
            // real app bundle either way, so this is correct in the shipped app too.
            Label {
                Text("Flight Control Not Enabled")
            } icon: {
                Image("FlightControlSplash", bundle: Bundle(for: SessionStore.self))
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: 200, maxHeight: 200)
                    .accessibilityLabel("Flight Control")
            }
        } description: {
            Text("Enable Flight Control to describe work here, triage it against the task graph, and release tasks to the swarm.")
        } actions: {
            Button("Enable Flight Control…") {
                if flywheelStatus.isFlywheelProject {
                    showingFlywheelConfirmation = true
                } else {
                    showingFlywheelSetupConfirmation = true
                }
            }
        }
        // Fill the viewport so the message centers in it. `body` pins its content to
        // `.topLeading` (right for the intake layout), and `ContentUnavailableView` only
        // takes its intrinsic size — so without this it sat in the top-left corner instead of
        // centered the way `RootView`'s no-session state is.
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("project-flywheel-disabled")
    }

    /// Runs the FileManager-backed probe at most once per view mount — see
    /// `ProjectHeaderRow.probeFlywheelStatusIfNeeded`'s doc comment for the render-cost this
    /// avoids; this view's `body` isn't read from a `.contextMenu` closure, but memoizing it
    /// the same way keeps a resize/selection-change re-render from re-statting the repo.
    private func probeFlywheelStatusIfNeeded() {
        guard probedFlywheelStatus == nil, store.flywheelSuggestion(for: repo.url) == nil else { return }
        probedFlywheelStatus = FlywheelProjectProbe.status(of: repo.url)
    }

    /// The Intakes column over the detail pane, rather than beside it in an `HSplitView`: the
    /// column animates its width when it collapses to its rail, and the detail must not follow
    /// it frame by frame. The detail is laid out once, at the final width, the moment the toggle
    /// flips (`.animation(nil, value:)` below) — the column then slides over the part it is about
    /// to uncover, or out over the part it is about to cover. Resizing the detail with the column
    /// re-laid its whole SwiftUI tree every frame and restarted the plan editor's whole-plan pass
    /// on each (`PlanNSTextView.fitContainer`); `ProjectViewIntakeListLiveTests` pins one width
    /// change per toggle. The split view's draggable divider is kept by `IntakesColumnEdge`.
    private var intakeSplitView: some View {
        let collapsed = listCollapsed
        return ZStack(alignment: .topLeading) {
            Group {
                if composerExpanded {
                    ExpandedIntakeComposer(intent: $intent, onTriage: triage, onCollapse: { composerExpanded = false })
                } else if let id = selectionBinding.wrappedValue, let intake = intakes.first(where: { $0.id == id }) {
                    // Keyed on the intake's id, not just present: selecting a different row
                    // must reset `IntakeDetailView`'s own `@State` (answer drafts, the chosen
                    // preset), which a same-identity re-render would otherwise carry over.
                    IntakeDetailView(service: intakeService, intake: intake, onOpenReview: { reviewIntakeID = id },
                                     onRunTasks: { tasks in
                                         store.requestSwarmLaunch(project: repo.url.standardizedFileURL.path,
                                                                  filter: .intake(id: intake.id, tasks: tasks),
                                                                  title: repo.displayName)
                                     },
                                     showsInspector: inspectorBinding)
                        .id(intake.id)
                } else {
                    Text("Select an intake").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 320)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.leading, collapsed ? IntakeRail.width : paneWidth)
            .animation(nil, value: collapsed)

            intakesColumn(collapsed: collapsed)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                // The trailing counterpart of the list toggle (`listToggle`): `.primaryAction`
                // puts it at the window's far right, over the inspector column when that is open
                // — measured in `ProjectViewIntakeListLiveTests`, since the placement's docs say
                // "leading" for macOS and the split view overrides them.
                //
                // ⌥⌘I is Ghostty's terminal-inspector chord, but only while a terminal has
                // focus — and none is on screen here: `RootView` shows this view in place of
                // the terminal. So a toolbar shortcut, live only while this view is, rather
                // than a menu item, whose key equivalent `MenuKeyEquivalents` would offer ahead
                // of Ghostty's binding (it is not `performable`) and take the chord from every
                // terminal in the app.
                let shown = inspectorBinding.wrappedValue
                Button {
                    // Read at the press, never `shown`: the chord's action is kept from an
                    // earlier body pass, and a captured value re-opened on every ⌥⌘I.
                    inspectorBinding.wrappedValue.toggle()
                } label: {
                    Label(shown ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing")
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                .help(shown ? "Hide the inspector (⌥⌘I)" : "Show the inspector (⌥⌘I)")
                .accessibilityIdentifier("intake-inspector-toggle")
            }
        }
    }

    /// The Intakes list, or its rail. The width animates; each state's content keeps its own
    /// width and is clipped by the moving edge while the two cross-fade, so neither re-wraps
    /// through the widths in between. The one toggle rides the trailing edge in both states.
    private func intakesColumn(collapsed: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            if collapsed {
                IntakeRail(intakes: intakes, tapes: intakeService.tapes, selection: selectionBinding,
                           intent: $intent, onTriage: triage, onExpand: { composerExpanded = true })
                    .transition(.opacity)
            } else {
                expandedList
                    .frame(width: paneWidth)
                    .transition(.opacity)
            }
        }
        .frame(width: collapsed ? IntakeRail.width : paneWidth, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .clipped()
        // Opaque: the column draws over the detail pane while it slides (`intakeSplitView`).
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .topTrailing) {
            listToggle(collapsed: collapsed).padding(.top, 12).padding(.trailing, 12)
        }
        .overlay(alignment: .trailing) {
            IntakesColumnEdge(width: $paneWidth, range: Self.paneWidths, resizable: !collapsed)
        }
        // The column's own animation, scoped to the column. The toggle must not wrap its state
        // change in `withAnimation`: that makes the animation ambient, and on macOS 15 the
        // detail pane's `.animation(nil, value:)` (`intakeSplitView`) did not stop it taking the
        // padding change frame by frame (nine widths in one toggle, the plan editor re-laid on
        // each). With no ambient animation there is nothing for the detail to opt out of.
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: collapsed)
    }

    private var expandedList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(repo.displayName).font(.title3.weight(.semibold))
                // Clear of the list toggle, which sits at this line's trailing end.
                .padding(.trailing, 32)
                .lineLimit(1)
            Text("Intakes").font(.headline).foregroundStyle(.secondary)
            List(selection: selectionBinding) {
                ForEach(intakes) { intake in
                    IntakeRow(intake: intake, tape: intakeService.tapes[intake.id],
                              archived: intakeService.isArchived(intake.id))
                        .tag(intake.id)
                        .accessibilityIdentifier("intake-row")
                        .contextMenu { planActions(intake.id) }
                }
            }
            .focused($listFocused)
            .background { if listFocused { planShortcuts } }
            listFooter
            Divider()
            if composerExpanded {
                // Never two live editors on one draft.
                Text("Editing in the main view")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
                    .accessibilityIdentifier("intake-composer-placeholder")
            } else {
                IntakeComposer(intent: $intent, onTriage: triage, onExpand: { composerExpanded = true })
            }
        }
        .padding(16)
    }

    /// Collapses the list to its rail and back — the leading counterpart of the inspector's
    /// toolbar toggle. In the column rather than the toolbar: the toolbar's leading end already
    /// holds the window's own sidebar toggle, and two sidebar glyphs side by side there would
    /// leave the human guessing which list each one hides.
    ///
    /// ⌥⌘S, Notes' chord for its folder list (⌃⌘S, the standard Show Sidebar, is the session
    /// sidebar's): not in libghostty's macOS defaults (`vendor/ghostty/src/config/Config.zig`)
    /// nor on any menu here, and a view shortcut, live only while this view is on screen — the
    /// same reasoning as ⌥⌘I's below.
    private func listToggle(collapsed: Bool) -> some View {
        Button(action: toggleList) {
            Image(systemName: "sidebar.leading")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .keyboardShortcut("s", modifiers: [.command, .option])
        .help(collapsed ? "Expand Intakes (⌥⌘S)" : "Collapse Intakes (⌥⌘S)")
        .accessibilityLabel(collapsed ? "Expand Intakes" : "Collapse Intakes")
        .accessibilityIdentifier("intake-list-toggle")
    }

    private func toggleList() {
        // Read at the press, as the inspector toggle does: the chord's action is kept from an
        // earlier body pass, and a captured value would re-apply the same state on every ⌥⌘S.
        let collapse = !intakeService.intakeListCollapsed(forProject: projectPath)
        intakeService.setIntakeListCollapsed(collapse, inProject: projectPath)
    }

    // MARK: - Archive and Move to Trash

    /// The selected plan's actions — the row context menu and the footer's action menu both draw
    /// these, so the two can never offer different things. The shortcuts are live through
    /// `planShortcuts`, only while the list has focus; here they are labels. The context menu
    /// shows them (its menu exists only while open); the footer's pull-down does not, since a
    /// pop-up button offers its menu's key equivalents while closed, and ⌘⌫ in the request field
    /// would then ask to trash the selected plan.
    @ViewBuilder private func planActions(_ id: UUID, showsShortcuts: Bool = true) -> some View {
        if intakeService.isArchived(id) {
            Button("Unarchive") { intakeService.unarchive(id) }
        } else {
            Button("Archive") { requestArchive(id) }
                .keyboardShortcut(showsShortcuts ? KeyboardShortcut("a", modifiers: [.control, .command]) : nil)
                .disabled(!intakeService.canArchive(id))
        }
        Button("Move to Trash…") { confirming = .trash(id) }
            .keyboardShortcut(showsShortcuts ? KeyboardShortcut(.delete, modifiers: .command) : nil)
            .disabled(!intakeService.canArchive(id))
        Divider()
        Button("Show in Finder") {
            NSWorkspace.shared.activateFileViewerSelecting([intakeService.directory(id)])
        }
    }

    /// ⌃⌘A (Mail's Archive) and ⌘⌫ (Finder's Move to Trash), as zero-size buttons that exist
    /// only while the list has focus. View shortcuts rather than menu items: a menu item's key
    /// equivalent is offered ahead of Ghostty's bindings (`MenuKeyEquivalents`), so ⌘⌫ would
    /// stop deleting to line start in every terminal; and the menu bar never rebuilds from
    /// SwiftUI state (ARCHITECTURE.md). Neither chord is bound by a menu here or by libghostty's
    /// performable defaults (⌘⌫ is its terminal-only delete-line).
    private var planShortcuts: some View {
        ZStack {
            Button("Archive Plan") {
                if let id = selectionBinding.wrappedValue {
                    if intakeService.isArchived(id) { intakeService.unarchive(id) } else { requestArchive(id) }
                }
            }
            .keyboardShortcut("a", modifiers: [.control, .command])
            Button("Move Plan to Trash") {
                if let id = selectionBinding.wrappedValue, intakeService.canArchive(id) { confirming = .trash(id) }
            }
            .keyboardShortcut(.delete, modifiers: .command)
        }
        .frame(width: 0, height: 0)
        .opacity(0)
        .accessibilityHidden(true)
    }

    /// Show Archived, and an action menu for the selected plan — the footer's controls, under
    /// the list they act on.
    private var listFooter: some View {
        HStack(spacing: 8) {
            Toggle("Show Archived", isOn: Binding(
                get: { intakeService.showsArchived(forProject: projectPath) },
                set: { intakeService.setShowsArchived($0, inProject: projectPath) }
            ))
            .toggleStyle(.checkbox)
            .controlSize(.small)
            .accessibilityIdentifier("intake-show-archived")
            Spacer()
            Menu {
                if let id = selectionBinding.wrappedValue { planActions(id, showsShortcuts: false) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(selectionBinding.wrappedValue == nil)
            .help("Actions for the selected plan")
            .accessibilityLabel("Plan Actions")
            .accessibilityIdentifier("intake-plan-actions")
        }
    }

    private var confirmationTitle: String {
        switch confirming {
        case .stopAndArchive: return "Stop and archive?"
        case .trash(let id):
            let title = intakeService.intakes.first { $0.id == id }.map { IntakeTitle(intent: $0.intent).title } ?? "this plan"
            return "Move “\(title)” to the Trash?"
        case nil: return ""
        }
    }

    /// Archives at once unless a round is running, which asks first — stopping a round is the
    /// one part of archiving that ⌘Z can't take back.
    private func requestArchive(_ id: UUID) {
        guard intakeService.canArchive(id) else { return }
        if intakeService.isRoundRunning(id) { confirming = .stopAndArchive(id) } else { archive(id) }
    }

    private func archive(_ id: UUID) {
        let service = intakeService
        let project = projectPath
        guard service.archive(id, inProject: project) else { return }
        undoManager?.registerUndo(withTarget: service) { service in
            service.unarchive(id)
            service.select(id, inProject: project)
        }
        undoManager?.setActionName("Archive Plan")
    }

    private func trash(_ id: UUID) {
        intakeService.moveToTrash(id, inProject: projectPath)
    }

    private func triage() {
        intakeService.capture(intent: intent, project: projectPath)
        intent = ""
        composerExpanded = false
    }
}

/// The Intakes column's trailing hairline, and while the list is expanded the handle that
/// resizes it — the divider `HSplitView` used to give it. Dragged in the global space: the
/// handle moves with the edge it drags, so local coordinates would chase themselves.
private struct IntakesColumnEdge: View {
    @Binding var width: CGFloat
    let range: ClosedRange<CGFloat>
    let resizable: Bool
    @State private var dragOrigin: CGFloat?

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1)
            .overlay {
                if resizable {
                    Color.clear
                        .frame(width: 9)
                        .contentShape(Rectangle())
                        .columnResizePointer()
                        .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { drag in
                                let origin = dragOrigin ?? width
                                dragOrigin = origin
                                width = min(max(origin + drag.translation.width, range.lowerBound), range.upperBound)
                            }
                            .onEnded { _ in dragOrigin = nil })
                        .accessibilityHidden(true)
                }
            }
    }
}

private extension View {
    /// The column-resize pointer where the system has one to give (macOS 15); the arrow before.
    @ViewBuilder func columnResizePointer() -> some View {
        if #available(macOS 15.0, *) { pointerStyle(.columnResize) } else { self }
    }
}
