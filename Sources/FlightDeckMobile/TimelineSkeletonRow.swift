import FleetKit
import SwiftUI

/// A spilled-but-not-yet-rehydrated row, drawn as a skeleton so it is never blank.
///
/// The full body was swapped to disk to keep a single giant session under its memory ceiling
/// (see `TimelineFeed.spill`), leaving the first-line preview resident on `item.body.text`. That
/// preview is what a reader sees for the instant before the row rehydrates from disk on
/// approach — local and fast, so ordinarily there is no loading state at all. The subtle
/// "loading" line appears only when a wire re-fetch is genuinely in flight, the one case a spill
/// record was purged.
struct TimelineSkeletonRow: View {
    let item: TimelineItem
    /// True only when a wire fallback for this row's range is in flight.
    var isFetching: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(item.body.text)
                .font(.body)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .redacted(reason: .placeholder)
            if isFetching {
                Label("Loading full text", systemImage: "arrow.down.circle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(item.body.text.isEmpty ? "Loading message" : item.body.text)
    }
}
