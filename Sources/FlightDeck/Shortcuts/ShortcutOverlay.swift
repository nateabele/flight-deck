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
            // Spelled `"/"` + ⇧⌘, NOT `"?"` + ⌘. The `"?"` spelling is the exact key equivalent
            // of the system's Help-menu search field, which AppKit inserts when the Help menu
            // opens — and with that twin present, this item was drawn with no shortcut at all.
            // `"/"` + shift is a distinct key equivalent, so it draws as ⇧⌘/, and AppKit still
            // matches the physical ⌘⇧/ press: `TabNavigationCommands`' `"["` + ⇧⌘ items rely on
            // the same shift-on-punctuation matching and fire today.
            .keyboardShortcut("/", modifiers: [.command, .shift])
        }
    }
}

/// The ⌘⇧/ sheet: a glass command-bar panel in the style of Raycast and Spotlight (layout A,
/// 2026-09-28). Dark material over a light scrim, so the terminal stays readable behind it — the
/// overlay is a glance, and a heavy dim reads as a modal dialog, which it is not.
struct ShortcutOverlay: View {
    let groups: [ShortcutGroup]
    let dismiss: () -> Void
    @State private var query = ""
    @State private var highlighted: ShortcutItem.ID?
    @State private var keyMonitor: Any?
    @State private var gridHeight: CGFloat = 0
    @FocusState private var filterFocused: Bool

    private var shown: [ShortcutGroup] { ShortcutCatalog.filter(groups, query: query) }
    private var columns: [[ShortcutGroup]] { ShortcutCatalog.twoColumns(shown) }
    /// ↑↓ order: down the left column, then down the right — the order the eye reads them in.
    private var readingOrder: [ShortcutItem.ID] {
        columns.flatMap { $0.flatMap { $0.items.map(\.id) } }
    }
    private var shownCount: Int { shown.reduce(0) { $0 + $1.items.count } }

    private static let corner = RoundedRectangle(cornerRadius: 16, style: .continuous)
    private static let hairline = Color.white.opacity(0.08)
    /// Fits Flight Deck's whole menu (24 shortcuts in 2026-09) without scrolling.
    private static let maxGridHeight: CGFloat = 560

    var body: some View {
        ZStack {
            Color.black.opacity(0.28)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture(perform: dismiss)
            panel
        }
        .onAppear {
            filterFocused = true
            highlighted = readingOrder.first
            installArrowKeys()
        }
        .onDisappear(perform: removeArrowKeys)
        .onChange(of: query) { highlighted = readingOrder.first }
        .onExitCommand(perform: dismiss)
    }

    private var panel: some View {
        VStack(spacing: 0) {
            searchBar
            Self.hairline.frame(height: 0.5)
            if shown.isEmpty {
                emptyState
            } else {
                // Sized to the measured grid, capped: a ScrollView (and `ViewThatFits`, tried
                // first) takes all the height it is offered, which left a filtered list centred
                // in a tall empty panel. Measuring lets the panel hug short content and scroll
                // only when there is more than fits.
                ScrollViewReader { proxy in
                    ScrollView {
                        grid.background {
                            // Reported straight from the reader: a `PreferenceKey` set in
                            // here never reached a handler outside the ScrollView, leaving
                            // the frame at its 1pt starting height.
                            GeometryReader { geometry in
                                Color.clear
                                    .onAppear { gridHeight = geometry.size.height }
                                    .onChange(of: geometry.size.height) {
                                        gridHeight = geometry.size.height
                                    }
                            }
                        }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    .frame(height: min(max(gridHeight, 1), Self.maxGridHeight))
                    .onChange(of: highlighted) {
                        if let highlighted { proxy.scrollTo(highlighted) }
                    }
                }
            }
            Self.hairline.frame(height: 0.5)
            footer
        }
        .frame(width: 640)
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                // Tints the glass toward the terminal's near-black, so a bright prompt line behind
                // it cannot wash the text out.
                Color(red: 0.14, green: 0.145, blue: 0.17).opacity(0.55)
            }
        }
        .clipShape(Self.corner)
        .overlay(Self.corner.strokeBorder(.white.opacity(0.16), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.5), radius: 40, y: 20)
        // Always dark, whatever the system appearance: it floats over a terminal, and a light
        // panel over dark text flashes like a dialog.
        .environment(\.colorScheme, .dark)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
            TextField("Search shortcuts…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($filterFocused)
                .onExitCommand(perform: dismiss)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
    }

    private var grid: some View {
        HStack(alignment: .top, spacing: 26) {
            ForEach(Array(columns.enumerated()), id: \.offset) { _, column in
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(column) { group in groupView(group) }
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 2)
        .padding(.bottom, 12)
    }

    private func groupView(_ group: ShortcutGroup) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: ShortcutCatalog.symbol(forGroup: group.title))
                    .font(.system(size: 10.5, weight: .semibold))
                Text(group.title)
                    .font(.system(size: 11, weight: .semibold))
            }
            .foregroundStyle(.secondary)
            .padding(.top, 10)
            .padding(.bottom, 3)

            ForEach(group.items) { item in
                HStack(spacing: 12) {
                    Text(item.title)
                        .font(.system(size: 13))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Keycaps(chord: item.chord)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    highlighted == item.id ? Color.white.opacity(0.08) : .clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
                .padding(.horizontal, -8)
                .contentShape(Rectangle())
                .onHover { if $0 { highlighted = item.id } }
                .id(item.id)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "keyboard")
                .font(.system(size: 26, weight: .light))
            Text("No shortcuts match “\(query)”")
                .font(.system(size: 13))
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, minHeight: 150)
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Text("\(shownCount) shortcut\(shownCount == 1 ? "" : "s")")
            Spacer()
            HStack(spacing: 5) { Keycaps(caps: ["↑", "↓"]); Text("move") }
            HStack(spacing: 5) { Keycaps(caps: ["esc"]); Text("close") }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 18)
        .padding(.vertical, 9)
        .background(Color.black.opacity(0.12))
    }

    /// ↑↓ through a local monitor rather than `.onKeyPress`: the focused filter field's editor
    /// takes arrow keys first (as move-to-start/end of line), so a SwiftUI key handler on the
    /// field or the panel never sees them. Only the bare arrows are taken — ⌃⌘←/→ and anything
    /// else with a modifier still reach the menu.
    private func installArrowKeys() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]) else {
                return event
            }
            switch event.keyCode {
            case 125: moveHighlight(by: 1); return nil
            case 126: moveHighlight(by: -1); return nil
            default: return event
            }
        }
    }

    /// Paired with `installArrowKeys`: a monitor left installed would keep eating ↑↓ in the
    /// terminal after the overlay closed.
    private func removeArrowKeys() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }

    private func moveHighlight(by delta: Int) {
        let order = readingOrder
        guard !order.isEmpty else { return }
        guard let current = highlighted, let index = order.firstIndex(of: current) else {
            highlighted = delta > 0 ? order.first : order.last
            return
        }
        highlighted = order[min(max(index + delta, 0), order.count - 1)]
    }
}

/// A chord drawn as separate keycaps — ⌥ ⇧ ⌘ V — the way Raycast and the macOS keyboard
/// viewer show a shortcut, instead of one run-together label.
private struct Keycaps: View {
    let caps: [String]

    init(chord: String) { caps = ShortcutCatalog.keycaps(for: chord) }
    init(caps: [String]) { self.caps = caps }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(caps.enumerated()), id: \.offset) { _, cap in
                Text(cap)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary.opacity(0.85))
                    .padding(.horizontal, cap.count > 1 ? 5 : 0)
                    .frame(minWidth: 18, minHeight: 18)
                    .background(.white.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .strokeBorder(.white.opacity(0.10), lineWidth: 0.5))
            }
        }
    }
}
