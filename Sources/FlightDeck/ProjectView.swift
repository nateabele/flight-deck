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

    var body: some View {
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
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("project-view")
        .sheet(item: $reviewIntakeID) { id in
            ReleaseReviewView(store: store, intakeID: id, onClose: { reviewIntakeID = nil })
        }
    }
}
