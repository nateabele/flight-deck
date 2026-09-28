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

    var body: some View {
        let title = IntakeTitle(intent: intake.intent)
        VStack(alignment: .leading, spacing: 4) {
            IntakeStatePill(intake: intake, tape: tape)
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
        .accessibilityElement(children: .combine)
    }
}
