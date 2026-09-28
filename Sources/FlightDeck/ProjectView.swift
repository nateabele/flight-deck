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

    private var intakeSplitView: some View {
        HSplitView {
            VStack(alignment: .leading, spacing: 8) {
                Text(repo.displayName).font(.title3.weight(.semibold))
                Text("Intakes").font(.headline).foregroundStyle(.secondary)
                List(selection: selectionBinding) {
                    ForEach(intakes) { intake in
                        HStack(spacing: 8) {
                            IntakeStatePill(intake: intake, tape: intakeService.tapes[intake.id])
                            Text(intake.intent).lineLimit(1).truncationMode(.tail)
                        }
                        .tag(intake.id)
                        .accessibilityIdentifier("intake-row")
                    }
                }
                Divider()
                Text("Describe what you want…").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $intent)
                    .font(.body)
                    .frame(minHeight: 60, maxHeight: 120)
                    .border(.separator)
                    .accessibilityIdentifier("intake-intent-field")
                Button("Triage") {
                    intakeService.capture(intent: intent, project: projectPath)
                    intent = ""
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(intent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding(16)
            .frame(minWidth: 280, idealWidth: 320, maxWidth: 420)

            Group {
                if let id = selectionBinding.wrappedValue, let intake = intakes.first(where: { $0.id == id }) {
                    // Keyed on the intake's id, not just present: selecting a different row
                    // must reset `IntakeDetailView`'s own `@State` (answer drafts, the chosen
                    // preset), which a same-identity re-render would otherwise carry over.
                    IntakeDetailView(service: intakeService, intake: intake, onOpenReview: { reviewIntakeID = id },
                                     showsInspector: inspectorBinding)
                        .id(intake.id)
                } else {
                    Text("Select an intake").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 320)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
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
}
