import SwiftUI

/// Whether a project has opted into Flywheel coordination — the one predicate
/// `ProjectHeaderRow`'s context menu and `ProjectView`'s intake-vs-empty-state switch both
/// read, so the two can never disagree about which project shows which UI. Pure: takes the
/// settings record the caller already looked up rather than reaching into
/// `PreferencesStore`/`SessionStore` itself, so it is testable with neither in the loop.
enum FlywheelEnablement {
    static func isEnabled(_ settings: ProjectSettings?) -> Bool {
        settings?.flywheelEnabled == true
    }
}

/// The probe formula both "make this project flywheel" entry points resolve before deciding
/// which confirmation to raise: a project already carrying `.beads`/`.agent-mail.yaml` gets
/// "Enable…" (just the hook install), a plain repo gets "Setup…" (bootstrap first). `cached`
/// is whatever on-demand probe result the caller already has in hand — `ProjectHeaderRow`
/// keeps its own memoized copy rather than routing it through here, since that memoization
/// is about dodging a probe on every `.contextMenu` re-render, a cost this formula itself has
/// no opinion on.
enum FlywheelEnableResolution {
    @MainActor
    static func status(for repo: URL, store: SessionStore, cached: FlywheelStatus?) -> FlywheelStatus {
        store.flywheelSuggestion(for: repo) ?? cached ?? FlywheelProjectProbe.status(of: repo)
    }
}

/// The two confirmation dialogs behind every "make this project flywheel" action, shared so
/// the header's context menu item and the intake empty state's "Enable Flight Control…" button
/// run the literal same flow rather than two copies that could drift on wording or on which of
/// `enableFlywheel`/`setupFlywheel` a given repo actually needs. The caller decides which
/// binding to flip, based on `status.isFlywheelProject`.
struct FlywheelEnableDialogs: ViewModifier {
    let repo: Repo
    @ObservedObject var store: SessionStore
    let status: FlywheelStatus
    @Binding var showingEnableConfirmation: Bool
    @Binding var showingSetupConfirmation: Bool

    func body(content: Content) -> some View {
        content
            // Confirmation-gated: `enableFlywheel` shells out to `am guard install` and writes
            // a git hook, so the user sees exactly what it is about to do before it runs.
            .confirmationDialog(
                "Enable Flight Control for \"\(repo.displayName)\"?",
                isPresented: $showingEnableConfirmation
            ) {
                Button("Enable") { Task { await store.enableFlywheel(for: repo.url) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(setupStepsDescription)
            }
            // Same gating as above, for the plain-repo path: `setupFlywheel` additionally runs
            // `br init`/`br agents --add`/`am projects discovery-init` before `enable`'s own
            // steps, so the confirmation lists the bootstrap alongside the install.
            .confirmationDialog(
                "Set Up Flight Control for \"\(repo.displayName)\"?",
                isPresented: $showingSetupConfirmation
            ) {
                Button("Setup") { Task { await store.setupFlywheel(for: repo.url) } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text(initializeStepsDescription)
            }
    }

    /// What the confirmation dialog tells the user `enableFlywheel` is about to run — the
    /// same steps `FlywheelSetup.enable` will actually perform, since both consult the same
    /// `FlywheelStatus` shape.
    private var setupStepsDescription: String {
        var steps: [String] = []
        if !status.guardInstalled { steps.append("Agent Mail commit guard") }
        if !status.beadsSyncHooksInstalled { steps.append("task sync hook") }
        guard !steps.isEmpty else {
            return "Setup is already complete; this only marks the project as Flight Control–enabled."
        }
        return "Will install: " + steps.joined(separator: ", ") + "."
    }

    /// What the confirmation dialog tells the user `setupFlywheel` is about to run: the
    /// bootstrap `FlywheelSetup.initialize` performs on a plain repo, ahead of the same
    /// guard/hook install `setupStepsDescription` lists.
    private var initializeStepsDescription: String {
        "Will initialize: task workspace, agent-mail marker, AGENTS.md. Will install: Agent Mail commit guard, task sync hook."
    }
}

extension View {
    func flywheelEnableConfirmations(
        repo: Repo, store: SessionStore, status: FlywheelStatus,
        showingEnableConfirmation: Binding<Bool>, showingSetupConfirmation: Binding<Bool>
    ) -> some View {
        modifier(FlywheelEnableDialogs(
            repo: repo, store: store, status: status,
            showingEnableConfirmation: showingEnableConfirmation,
            showingSetupConfirmation: showingSetupConfirmation
        ))
    }
}
