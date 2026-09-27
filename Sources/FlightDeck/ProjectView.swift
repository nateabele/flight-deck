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
    @State private var selection: UUID?
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
            Label("Flywheel Not Enabled", systemImage: "arrow.triangle.2.circlepath")
        } description: {
            Text("Enable Flywheel to describe work here, triage it against the bead graph, and release beads to the swarm.")
        } actions: {
            Button("Enable Flywheel…") {
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
                List(selection: $selection) {
                    ForEach(intakes) { intake in
                        HStack(spacing: 8) {
                            IntakeStatePill(intake: intake)
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
                if let id = selection, let intake = intakes.first(where: { $0.id == id }) {
                    // Keyed on the intake's id, not just present: selecting a different row
                    // must reset `IntakeDetailView`'s own `@State` (answer drafts, the chosen
                    // preset), which a same-identity re-render would otherwise carry over.
                    IntakeDetailView(service: intakeService, intake: intake, onOpenReview: { reviewIntakeID = id })
                        .id(intake.id)
                } else {
                    Text("Select an intake").foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(minWidth: 320)
        }
    }
}
