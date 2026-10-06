import AppKit
import SwiftUI

// The Routing popovers need every control in their right column to start AND end on the same
// x. SwiftUI's menu and segmented `Picker` on macOS size to their content and ignore any wider
// frame (checked in the offscreen renders: a fixed or max-width frame only moved them), which
// left the ragged right edge the popovers were redesigned to remove. These are the AppKit
// controls themselves, told not to hug, so they take exactly the width the grid column gives.

/// A pop-up button that fills its proposed width.
struct FillingPopUp<Value: Hashable>: NSViewRepresentable {
    @Binding var selection: Value
    let items: [(value: Value, title: String)]
    let identifier: String

    func makeNSView(context: Context) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.target = context.coordinator
        button.action = #selector(Coordinator.changed(_:))
        button.setContentHuggingPriority(.defaultLow, for: .horizontal)
        button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        button.setAccessibilityIdentifier(identifier)
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.parent = self
        let titles = items.map(\.title)
        if button.itemTitles != titles {
            button.removeAllItems()
            button.addItems(withTitles: titles)
        }
        if let i = items.firstIndex(where: { $0.value == selection }) { button.selectItem(at: i) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: FillingPopUp
        init(_ parent: FillingPopUp) { self.parent = parent }
        @objc func changed(_ sender: NSPopUpButton) {
            let i = sender.indexOfSelectedItem
            guard parent.items.indices.contains(i) else { return }
            parent.selection = parent.items[i].value
        }
    }
}

/// A segmented control whose segments share its proposed width equally. `selection` nil shows no
/// segment selected (an effort the rule leaves to the agent).
struct FillingSegments<Value: Hashable>: NSViewRepresentable {
    @Binding var selection: Value?
    let items: [(value: Value, title: String)]
    let identifier: String

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillEqually
        control.target = context.coordinator
        control.action = #selector(Coordinator.changed(_:))
        control.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setAccessibilityIdentifier(identifier)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        if control.segmentCount != items.count { control.segmentCount = items.count }
        for (i, item) in items.enumerated() where control.label(forSegment: i) != item.title {
            control.setLabel(item.title, forSegment: i)
        }
        let selected = items.firstIndex { $0.value == selection } ?? -1
        if control.selectedSegment != selected { control.selectedSegment = selected }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject {
        var parent: FillingSegments
        init(_ parent: FillingSegments) { self.parent = parent }
        @objc func changed(_ sender: NSSegmentedControl) {
            let i = sender.selectedSegment
            guard parent.items.indices.contains(i) else { return }
            parent.selection = parent.items[i].value
        }
    }
}

extension FillingSegments {
    /// For a choice that is never empty.
    init(selection: Binding<Value>, items: [(value: Value, title: String)], identifier: String) {
        self._selection = Binding(get: { selection.wrappedValue }, set: { if let v = $0 { selection.wrappedValue = v } })
        self.items = items
        self.identifier = identifier
    }
}
