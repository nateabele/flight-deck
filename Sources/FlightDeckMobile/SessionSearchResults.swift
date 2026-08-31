import FleetKit
import SwiftUI

/// The search results content, swapped in for the fleet list's projects and sections whenever
/// `SessionSearchModel.query` is non-empty.
///
/// **A plain `View`, drawn straight into the caller's `List`.** Not a `List` of its own: this
/// only ever appears inside `FleetListScreen`'s existing one, so the searchable field, the
/// pull-to-refresh gesture and the row insets stay the ONE list's, rather than two lists
/// disagreeing about them.
///
/// **Every row is a `Button`, never a `NavigationLink`.** Activating a `.conversation` or
/// `.project` result is a round trip to the Mac before there is anywhere to push, so the row
/// itself cannot carry a destination — and `FleetListScreen.row`'s own doc comment is the
/// standing warning against pairing a link with any second way to notice a tap: that combination
/// is what broke every row on a real device three times. A `Button` is the one recogniser here,
/// the same as the project header's `+`.
struct SessionSearchResults: View {
    let results: [SearchResult]
    let footer: SessionSearchModel.Footer?
    let onTap: (SearchResult) -> Void

    var body: some View {
        if results.isEmpty {
            emptyState
        } else {
            ForEach(results) { result in
                row(result)
                    .listRowInsets(FleetListScreen.rowInsets)
            }
            if let footer {
                footerRow(footer)
            }
        }
    }

    // MARK: Rows

    @ViewBuilder
    private func row(_ result: SearchResult) -> some View {
        if result.isContinuation {
            continuationRow(result)
        } else {
            switch result.kind {
            case .session, .project:
                nameRow(result)
            case .conversation:
                conversationRow(result)
            }
        }
    }

    /// A session or a project: title, underlined where the query matched, and the project it
    /// lives in underneath. Icon mirrors the desktop overlay's own `SearchResultRow` so the two
    /// screens agree on what a session versus a project looks like.
    private func nameRow(_ result: SearchResult) -> some View {
        Button {
            onTap(result)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: result.kind == .project ? "folder" : "chevron.right")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(Self.highlighted(result.title, ranges: result.highlightedRanges))
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.primary)
                    if result.kind != .project {
                        Text(result.projectName).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// A transcript hit: name, then `project · relative time`, then the two-sentinel snippet —
    /// the three lines the brief asks for, in that order.
    private func conversationRow(_ result: SearchResult) -> some View {
        Button {
            onTap(result)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "text.alignleft")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 2) {
                    Text(result.title)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.primary)
                    Text("\(result.projectName) · \(Self.relative(result.recency))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if let snippet = result.snippet {
                        Text(SearchSnippet.attributed(snippet))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// The second or third match from the SAME conversation: indented, and headless — the
    /// heading directly above it already carries the name, project and time. Repeating them
    /// would read as the same session listed over and over, which is what grouping in
    /// `SearchRanker` exists to prevent.
    private func continuationRow(_ result: SearchResult) -> some View {
        Button {
            onTap(result)
        } label: {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .frame(width: 20)
                    .padding(.top, 2)
                if let snippet = result.snippet {
                    Text(SearchSnippet.attributed(snippet))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.leading, 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: Footer

    /// What the results alone cannot say, appended below them. `.empty` never reaches here —
    /// `SessionSearchModel.apply` only sets it when `results` is also empty, which is the OTHER
    /// branch of `body` — but the switch stays exhaustive rather than force-unwrapping that.
    @ViewBuilder
    private func footerRow(_ footer: SessionSearchModel.Footer) -> some View {
        switch footer {
        case .offline(let macName):
            Label("Only names searched — connect to \(macName) for message history.",
                  systemImage: "wifi.slash")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .indexing(let done, let total):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Indexing \(done) of \(total) conversations")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        case .empty:
            EmptyView()
        }
    }

    /// The whole screen when there is nothing to list yet — never a bare "No results" while the
    /// phone genuinely does not know that. See `emptyNotice(for:)`, which is what a test drives
    /// this through without a window.
    @ViewBuilder
    private var emptyState: some View {
        switch Self.emptyNotice(for: footer) {
        case .waiting:
            EmptyView()
        case .offline(let macName):
            ContentUnavailableView(
                "Only names searched",
                systemImage: "wifi.slash",
                description: Text("Connect to \(macName) to search message history too.")
            )
        case .indexing(let done, let total):
            ContentUnavailableView(
                "Indexing…",
                systemImage: "clock.arrow.circlepath",
                description: Text("\(done) of \(total) conversations read so far.")
            )
        case .noResults:
            ContentUnavailableView.search
        }
    }

    /// What the empty screen says, as a pure function of the footer alone — the shape a test
    /// can assert without rendering anything.
    ///
    /// **`.waiting`, not `.noResults`, when there is no footer at all.** With no name matches
    /// and no reply from the Mac yet — the debounce still running, or a query FTS5 cannot even
    /// match — silence is the honest answer; a "No Results" that can still turn into a hit a
    /// beat later is the same false claim `.offline` guards against, just with worse timing
    /// instead of no connection.
    enum EmptyNotice: Equatable {
        case waiting
        case offline(String)
        case indexing(done: Int, total: Int)
        case noResults
    }

    static func emptyNotice(for footer: SessionSearchModel.Footer?) -> EmptyNotice {
        switch footer {
        case .none: return .waiting
        case .offline(let macName): return .offline(macName)
        case .indexing(let done, let total): return .indexing(done: done, total: total)
        case .empty: return .noResults
        }
    }

    // MARK: Formatting

    /// The query's matched span, underlined — not bold: bold is the desktop overlay's own
    /// emphasis for the same ranges, and the two screens are different enough surfaces (a
    /// touch list against a hovering panel) that copying its exact styling is not the goal
    /// here, only the same evidence.
    static func highlighted(_ text: String, ranges: [Range<String.Index>]) -> AttributedString {
        var attributed = AttributedString(text)
        for range in ranges {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed)
            else { continue }
            attributed[lower..<upper].underlineStyle = .single
        }
        return attributed
    }

    private static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named))
    }
}
