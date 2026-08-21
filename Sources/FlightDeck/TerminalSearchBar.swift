import SwiftUI

/// Shows the find bar while the surface has an active search, and nothing otherwise.
///
/// A separate view from `TerminalSearchBar` so that observing `surface` (whose
/// `@Published searchState` decides visibility) is separated from observing the
/// `SearchState` itself (whose `needle`/`total`/`selected` drive the bar's contents).
/// Both are `ObservableObject`s, and `@ObservedObject` cannot bind an optional.
struct SearchOverlay: View {
    @ObservedObject var surface: Ghostty.SurfaceView

    var body: some View {
        if let state = surface.searchState {
            TerminalSearchBar(surface: surface, state: state)
        }
    }
}

/// The find bar shown over the terminal when a search is active.
///
/// **Why this exists.** `Ghostty.SurfaceView.SearchState` and the whole libghostty search
/// pipeline were already vendored in: setting `searchState.needle` runs the search (the
/// surface's `didSet` debounces it and issues `search:<needle>`), and libghostty reports
/// progress back through the `SEARCH_TOTAL` / `SEARCH_SELECTED` actions. What was missing was
/// any way for a person to type a needle or read the match count — so ⌘F did nothing visible.
/// This view is that missing half.
///
/// Clearing `searchState` on the surface is what ends the search: its `didSet` issues
/// `end_search` for us, so dismissing here does not need to talk to libghostty directly.
struct TerminalSearchBar: View {
    @ObservedObject var surface: Ghostty.SurfaceView
    @ObservedObject var state: Ghostty.SurfaceView.SearchState

    @FocusState private var needleFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Find", text: $state.needle)
                .textFieldStyle(.plain)
                .focused($needleFocused)
                .frame(minWidth: 160)
                // Enter advances to the next match, matching the platform find bar.
                .onSubmit { step(forward: true) }

            Text(matchSummary)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 64, alignment: .trailing)

            Divider().frame(height: 16)

            Button { step(forward: false) } label: {
                Image(systemName: "chevron.up")
            }
            .help("Find Previous")
            .disabled(!hasMatches)

            Button { step(forward: true) } label: {
                Image(systemName: "chevron.down")
            }
            .help("Find Next")
            .disabled(!hasMatches)

            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Shared with `ToolOverlay` so the two panels that stack in this corner keep one
        // treatment: Liquid Glass on macOS 26+, the previous material/border/shadow below it.
        .floatingChrome()
        .padding(8)
        .onAppear { needleFocused = true }
        // ⌘F while the bar is already open re-focuses the field rather than opening a
        // second one, which is what `START_SEARCH` posts when `searchState` is non-nil.
        .onReceive(NotificationCenter.default.publisher(for: .ghosttySearchFocus)) { note in
            guard (note.object as? Ghostty.SurfaceView) === surface else { return }
            needleFocused = true
        }
    }

    private var hasMatches: Bool { (state.total ?? 0) > 0 }

    /// `selected` is a 0-based index from libghostty; humans count from 1.
    private var matchSummary: String {
        guard let total = state.total else { return "" }
        guard total > 0 else { return "No results" }
        guard let selected = state.selected else { return "\(total)" }
        return "\(selected + 1) of \(total)"
    }

    private func step(forward: Bool) {
        guard hasMatches else { return }
        surface.performBindingAction(forward ? "navigate_search:next" : "navigate_search:previous")
    }

    private func dismiss() {
        surface.searchState = nil
        Ghostty.moveFocus(to: surface)
    }
}
