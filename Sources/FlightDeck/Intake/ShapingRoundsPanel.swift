import IntakeKit
import SwiftUI

/// The Rounds editor of an intake that is already shaping, as its inspector shows it: the
/// saved config, or the unsaved edit the service holds (`IntakeService.roundConfigDrafts`),
/// with Save and Revert. Editable only between rounds; while one runs the same panel shows
/// disabled under "Pause to change agents." A change applies from the next round, because the
/// runner reads the config once per start — and a play pressed over an unsaved edit saves it
/// first (`IntakeService.send`), so the round it starts runs what the panel shows.
struct ShapingRoundsPanel: View {
    @ObservedObject var service: IntakeService
    let intake: Intake

    var body: some View {
        if let saved = intake.roundConfig {
            let editing = service.roundConfigEditing(intake.id)
            let draft = service.roundConfigDrafts[intake.id]
            VStack(alignment: .leading, spacing: 12) {
                Text(Self.statusLine(editing: editing, unsaved: draft != nil))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("rounds-status")
                if let refusal = service.roundConfigRefusals[intake.id] {
                    Text(refusal)
                        .font(.callout)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("rounds-refusal")
                }
                if draft != nil, editing == .editable {
                    HStack(spacing: 8) {
                        Spacer()
                        Button("Revert") { [service, id = intake.id] in service.setRoundConfigDraft(id, nil) }
                            .accessibilityIdentifier("rounds-revert")
                        // No ⌘S: the plan editor beside this panel is where a save chord would
                        // be expected to land.
                        Button("Save") { [service, id = intake.id] in service.commitRoundConfigDraft(id) }
                            .accessibilityIdentifier("rounds-save")
                    }
                }
                RoundConfigEditor(preset: intake.chosenPreset ?? .featurePlan,
                                  config: Binding(get: { draft ?? saved },
                                                  set: { [service, id = intake.id] in service.setRoundConfigDraft(id, $0) }),
                                  available: service.availableModels(), accounts: service.planningAccounts(),
                                  codexListedModels: CodexRoutingCatalog.shared.cachedModelIDs,
                                  shaping: service.shapingEdit(intake.id), readOnly: editing == .readOnly)
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("inspector-rounds-shaping")
        }
    }

    /// The line over the panel: why it is locked, or when an edit takes effect.
    static func statusLine(editing: DetailLayout.RoundsEditing, unsaved: Bool) -> String {
        switch editing {
        case .readOnly: unsaved ? "\(IntakeService.pauseToEdit) Your unsaved changes are kept." : IntakeService.pauseToEdit
        case .editable:
            unsaved ? "Unsaved. Changes apply from the next round; pressing play saves them."
                    : "Changes apply from the next round."
        }
    }
}
