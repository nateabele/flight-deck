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
    @State private var intent = ""
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

    init(store: SessionStore, repo: Repo) {
        self.store = store
        self.repo = repo
        self._intakeService = ObservedObject(wrappedValue: store.intakeService)
    }

    /// Standardized so it matches how `SessionStore` keys flywheel identities — a
    /// differently-spelled path would turn every intake lookup below into a silent miss
    /// (parallel-17-19-contract.md).
    private var projectPath: String { repo.url.standardizedFileURL.path }

    private var intakes: [Intake] { intakeService.intakes(forProject: projectPath) }

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
        .sheet(item: $reviewIntakeID) { id in
            ReleaseReviewView(store: store, intakeID: id, onClose: { reviewIntakeID = nil })
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
                if let id = selectionBinding.wrappedValue, let intake = intakes.first(where: { $0.id == id }) {
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
                           intent: $intent, onTriage: triage)
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
                    IntakeRow(intake: intake, tape: intakeService.tapes[intake.id])
                        .tag(intake.id)
                        .accessibilityIdentifier("intake-row")
                }
            }
            Divider()
            IntakeComposer(intent: $intent, onTriage: triage)
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
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) {
            intakeService.setIntakeListCollapsed(collapse, inProject: projectPath)
        }
    }

    private func triage() {
        intakeService.capture(intent: intent, project: projectPath)
        intent = ""
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
