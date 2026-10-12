import IntakeKit
import SwiftUI

/// One row of `ProjectView`'s Intakes list: the state pill as a caption, then the request
/// wrapped to three lines — its title (`IntakeTitle.lead`) in semibold running straight into
/// the rest in secondary, the way Mail's list runs a subject into its preview. One line of
/// intent told two similar requests apart only by their first few words.
struct IntakeRow: View {
    let intake: Intake
    /// The intake's tape while shaping, for the pill's round label (`IntakeStatePill.tape`).
    var tape: Tape? = nil
    /// Shown only under Show Archived: the row dims and carries an "Archived" badge, so an
    /// archived plan can't be mistaken for an active one.
    var archived = false

    var body: some View {
        let title = IntakeTitle(intent: intake.intent)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                IntakeStatePill(intake: intake, tape: tape)
                if archived {
                    Text("Archived")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .overlay(Capsule().strokeBorder(.secondary.opacity(0.6)))
                        .accessibilityIdentifier("intake-archived-badge")
                }
            }
            // A hierarchical style, not `Color.secondary`: it follows the selected row's
            // emphasized (white-on-accent) text, where a fixed gray would read as disabled.
            (Text(title.lead).fontWeight(.semibold)
                + Text(title.rest.isEmpty ? "" : " " + title.rest).foregroundStyle(.secondary))
                .lineLimit(3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // Height follows the text (one to three lines) rather than reserving three: a short
        // request under a reserved block read as a row with something missing.
        .padding(.vertical, 5)
        .opacity(archived ? 0.55 : 1)
        .accessibilityElement(children: .combine)
    }
}
