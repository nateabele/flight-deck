import SwiftUI

/// Turns FTS5's sentinel-marked snippet into an `AttributedString`.
///
/// An unbalanced opening sentinel — which a snippet truncated at FTS5's window boundary can
/// genuinely produce — emphasises nothing and keeps the remaining text, because losing the
/// rest of the line is far worse than losing a highlight.
enum SearchSnippet {
    static func attributed(_ raw: String) -> AttributedString {
        var result = AttributedString()
        var rest = Substring(raw)

        while let open = rest.firstIndex(of: SnippetSentinel.open) {
            result += AttributedString(String(rest[rest.startIndex..<open]))
            let afterOpen = rest.index(after: open)
            guard let close = rest[afterOpen...].firstIndex(of: SnippetSentinel.close) else {
                result += AttributedString(String(rest[afterOpen...]))
                return result
            }
            var marked = AttributedString(String(rest[afterOpen..<close]))
            marked.inlinePresentationIntent = .stronglyEmphasized
            result += marked
            rest = rest[rest.index(after: close)...]
        }
        result += AttributedString(String(rest))
        return result
    }
}

/// The card: query field, result rows, footer.
///
/// Every row is a heading plus two lines, uniform across result kinds. The two lines are the
/// snippet for a transcript hit and the project path for a name match — the row must draw
/// immediately either way and never wait on the index.
struct SearchOverlayView: View {
    @ObservedObject var model: SearchModel
    var onActivate: (SearchResult) -> Void
    var onDismiss: () -> Void

    /// Past this many rows the list scrolls instead of the card growing. Eight is where the
    /// card stops feeling like a menu and starts feeling like a window.
    private static let maximumVisibleRows = 8
    private static let rowHeight: CGFloat = 46

    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            field
            if !model.results.isEmpty {
                Divider()
                list
            }
            if let progress = model.indexingProgress, progress.indexed < progress.total {
                Divider()
                footer(progress)
            }
        }
        .frame(width: 680)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator.opacity(0.6)))
        .shadow(radius: 30, y: 12)
        // The height spring. Driven by the result *count* rather than by the array, so a
        // rerank that returns the same number of rows does not re-animate — animating twice
        // for one keystroke is what makes a panel like this feel cheap.
        .animation(.spring(response: 0.26, dampingFraction: 0.86), value: model.results.count)
        .onAppear { fieldFocused = true }
    }

    private var field: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search sessions and conversations", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 19))
                .focused($fieldFocused)
                .onSubmit { if let result = model.activateSelection() { onActivate(result) } }
            if !model.query.isEmpty {
                Button { model.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(model.results) { result in
                        SearchResultRow(result: result, isSelected: result.id == model.selectedID)
                            .id(result.id)
                            .contentShape(Rectangle())
                            .onTapGesture { onActivate(result) }
                    }
                }
            }
            .frame(height: min(
                CGFloat(model.results.count), CGFloat(Self.maximumVisibleRows)
            ) * Self.rowHeight)
            .onChange(of: model.selectedID) { id in
                guard let id else { return }
                withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(id, anchor: .center) }
            }
        }
    }

    private func footer(_ progress: SearchIndexBuilder.Progress) -> some View {
        // Shown while history is still being read. A search that silently returns nothing
        // is worse than one that says it is still reading — and name results, which are the
        // common case, work the whole time.
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Indexing \(progress.indexed) of \(progress.total) conversations")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 7)
    }
}

/// One result. Heading plus exactly two lines, whatever the result kind.
private struct SearchResultRow: View {
    let result: SearchResult
    let isSelected: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .frame(width: 16)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 7) {
                    Text(highlightedTitle).font(.system(size: 13, weight: .semibold))
                    Text(result.projectName).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }
            Spacer(minLength: 8)
            Text(result.recency, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                .font(.system(size: 10)).foregroundStyle(.tertiary)
                .padding(.top, 3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .frame(height: 46, alignment: .top)
        .background(isSelected ? Color.accentColor.opacity(0.22) : .clear)
    }

    private var symbol: String {
        switch result.kind {
        case .session: return "chevron.right"
        case .project: return "folder"
        case .conversation: return "text.alignleft"
        }
    }

    /// The two lines. A transcript hit shows its snippet; a name match shows where it lives,
    /// which is what distinguishes two sessions with the same name in different worktrees.
    private var detail: AttributedString {
        if let snippet = result.snippet { return SearchSnippet.attributed(snippet) }
        return AttributedString(result.projectPath)
    }

    private var highlightedTitle: AttributedString {
        var attributed = AttributedString(result.title)
        for range in result.highlightedRanges {
            guard let lower = AttributedString.Index(range.lowerBound, within: attributed),
                  let upper = AttributedString.Index(range.upperBound, within: attributed)
            else { continue }
            attributed[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
        }
        return attributed
    }
}
