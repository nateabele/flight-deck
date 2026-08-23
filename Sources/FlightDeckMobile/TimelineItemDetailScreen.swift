import FleetKit
import SwiftUI

/// One item in full. The third of spec §7's three screens, and **a stub: Task 6 gives it the
/// whole body, the paired result and the truncation notice.**
///
/// `result` is already threaded through because pairing a call with its output is the
/// screen's reason to exist and the feed is the only place that pairing can be made — see
/// `SessionTimelineScreen.pairedResult(for:in:)`. It is `nil` whenever the answering record
/// is not on screen, which a page boundary is enough to cause.
struct TimelineItemDetailScreen: View {
    let item: TimelineItem
    /// The `.toolResult` that answers `item`, when the feed holds it. Nil for every other
    /// kind, and for a call still running.
    let result: TimelineItem?

    var body: some View {
        ScrollView {
            Text(item.body.text)
                .font(.system(.footnote, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
    }
}
