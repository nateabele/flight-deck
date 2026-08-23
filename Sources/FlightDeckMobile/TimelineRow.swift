import FleetKit
import SwiftUI

/// One timeline item, as a row. **A stub: Task 5 gives it the terminal idiom** — the kind's
/// own treatment, the tool name, the error tint and the truncation marker. What is here is
/// the minimum `SessionTimelineScreen` needs to render a conversation at all.
///
/// `summary` first and `text` only as a fallback, which is the rule that field states: a tool
/// call's `text` is pretty-printed JSON and `{` is not a useful row, so the Mac sends a
/// one-line preview beside it. Nil means "the first line of `text` is fine", which is right
/// for every prose kind.
///
/// **The text is rendered, never parsed**, here or in the detail screen. A body is cut at the
/// per-item byte cap wherever that lands — mid-object, mid-string, mid-escape — so a
/// truncated tool input is not parseable JSON by design, and a row that tried to decode it
/// would show nothing for exactly the largest inputs.
struct TimelineRow: View {
    let item: TimelineItem

    var body: some View {
        Text(item.body.summary ?? item.body.text)
            .font(.system(.body, design: .monospaced))
            .lineLimit(3)
    }
}
