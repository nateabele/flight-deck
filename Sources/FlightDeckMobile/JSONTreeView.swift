import FleetKit
import SwiftUI

/// A tool's JSON body as a tree you can open and close, the way a browser shows a response.
///
/// **Why this exists at all**: `AskUserQuestion`'s input is an object holding an array holding
/// an object holding an array holding objects, with three-hundred-character strings at the
/// leaves. Pretty-printed that is ninety lines whose only remaining structure is indentation,
/// on a screen 393pt wide, and finding the second option's label means counting spaces.
///
/// **A flat `ForEach`, not nested `DisclosureGroup`s.** The picture is the same; what differs
/// is where the state lives. `DisclosureGroup` keeps "is this open" inside SwiftUI, which puts
/// the one decision worth testing — *which* nodes a given document opens on — somewhere no test
/// can reach. `JSONValue.treeRows(expanded:)` makes it an ordinary `Set<String>` this view
/// owns, and `FlightDeckTests` runs the flattening against real bodies.
///
/// **Not monospaced.** Monospace on this screen is reserved for commands, output and diffs,
/// where column alignment is the meaning (see `TimelineRow`) — and it was measured at about 38
/// characters to the line here, which turns one option's description into a grey wall. A tree
/// carries its structure in indentation, weight and tint, so the system font is both the house
/// rule and the legible choice.
struct JSONTreeView: View {
    let document: JSONValue

    /// Which nodes are open. Seeded from the document — two levels, within a row budget — so a
    /// reader lands on a shape rather than on one collapsed line.
    @State private var expanded: Set<String>

    init(document: JSONValue) {
        self.document = document
        _expanded = State(initialValue: document.defaultExpansion())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(document.treeRows(expanded: expanded)) { row in
                JSONTreeRowView(row: row) { toggle(row) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggle(_ row: JSONTreeRow) {
        guard row.isContainer, row.childCount > 0 else { return }
        if expanded.contains(row.id) {
            expanded.remove(row.id)
        } else {
            expanded.insert(row.id)
        }
    }
}

/// One line: an indent, a chevron if it opens, the key, and the value.
private struct JSONTreeRowView: View {
    let row: JSONTreeRow
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                chevron
                label
                value
                Spacer(minLength: 0)
            }
            .padding(.leading, indent)
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // A leaf is not a control, and letting VoiceOver call every one of forty rows a button
        // is forty invitations to activate something that does nothing.
        .disabled(!isOpenable)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(TimelineStyle.accessibilityLabel(forJSON: row))
        .accessibilityAddTraits(isOpenable ? .isButton : [])
    }

    private var isOpenable: Bool { row.isContainer && row.childCount > 0 }

    /// A fixed column whether or not there is a chevron in it, so keys line up down the tree —
    /// the same problem, and the same fix, as `TimelineRow.header`'s symbol column.
    private var chevron: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.secondary)
            .rotationEffect(.degrees(row.isExpanded ? 90 : 0))
            .opacity(isOpenable ? 1 : 0)
            .frame(width: 10, alignment: .center)
    }

    private var label: some View {
        Text(TimelineStyle.jsonLabel(for: row) + ":")
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private var value: some View {
        Text(TimelineStyle.jsonValueText(for: row.value))
            .font(.footnote)
            .foregroundStyle(TimelineStyle.jsonTint(for: row.value))
            // Whole, never clipped. The reason to open this screen is to read the thing, and a
            // silently shortened value here would be the truncation failure `Body.truncatedBytes`
            // exists to prevent, reintroduced by the viewer.
            .multilineTextAlignment(.leading)
            .textSelection(.enabled)
    }

    /// Capped. Five levels of 14pt is 70pt of a 361pt panel, and a document that nests eight
    /// deep would otherwise leave a column two words wide. Past the cap the chevron and the
    /// tint still say what is nested in what.
    private var indent: CGFloat { CGFloat(min(row.depth, 5)) * 14 }
}
