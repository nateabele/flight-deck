import SwiftUI

extension Notification.Name {
    /// Posted by the ⌘⇧/ menu item. A `Commands` struct has no route to `RootView`'s state —
    /// the same shape `SearchCommands` uses for ⌘K.
    static let flightDeckToggleShortcuts = Notification.Name("flightDeckToggleShortcuts")
}

/// Help ▸ Keyboard Shortcuts. No `.disabled(...)`: a disabled `NSMenuItem` does not fire its
/// key equivalent, and the item must also close the overlay it opened.
struct ShortcutOverlayCommands: Commands {
    var body: some Commands {
        CommandGroup(before: .help) {
            Button("Keyboard Shortcuts") {
                NotificationCenter.default.post(name: .flightDeckToggleShortcuts, object: nil)
            }
            // ⌘⇧/ spelled as ⌘? — the spelling macOS uses for its own Help-search chord, which
            // AppKit matches against shift+/ on a US layout. `"/"` + `.shift` is not reliably
            // matched, because the event's shifted character is "?". This shadows Help search
            // on purpose (spec, 2026-09-27).
            .keyboardShortcut("?", modifiers: .command)
        }
    }
}

struct ShortcutOverlay: View {
    let groups: [ShortcutGroup]
    let dismiss: () -> Void
    @State private var query = ""
    @FocusState private var filterFocused: Bool

    private var shown: [ShortcutGroup] { ShortcutCatalog.filter(groups, query: query) }

    var body: some View {
        ZStack {
            Color.black.opacity(0.35)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
            panel
        }
        .onAppear { filterFocused = true }
        .onExitCommand(perform: dismiss)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter shortcuts", text: $query)
                    .textFieldStyle(.plain)
                    .focused($filterFocused)
                    .onExitCommand(perform: dismiss)
                Text("esc").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .overlay(RoundedRectangle(cornerRadius: 4).stroke(.quaternary))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))

            if shown.isEmpty {
                Text("No shortcuts match").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 28, alignment: .top),
                                        GridItem(.flexible(), alignment: .top)],
                              alignment: .leading, spacing: 14) {
                        ForEach(shown) { group in groupView(group) }
                    }
                }
                .frame(maxHeight: 460)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
        .frame(width: 600)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(.white.opacity(0.12)))
        .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
    }

    private func groupView(_ group: ShortcutGroup) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(group.title.uppercased())
                .font(.system(size: 10.5, weight: .semibold)).tracking(0.6)
                .foregroundStyle(.secondary)
            ForEach(group.items) { item in
                HStack {
                    Text(item.title).lineLimit(1)
                    Spacer(minLength: 12)
                    Text(item.chord).font(.system(size: 12)).monospacedDigit()
                        .padding(.horizontal, 5)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 4))
                }
            }
        }
    }
}
