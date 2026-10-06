import FleetKit
import SwiftUI

/// Pure row decisions, testable without rendering.
enum SubagentRows {
    /// Ancestors of a blocked agent start expanded, so the agent asking for you is visible
    /// instead of hiding under a collapsed parent.
    static func autoExpanded(_ nodes: [WireSubagent]) -> Set<String> {
        var open: Set<String> = []
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for node in nodes where node.state == "blocked" {
            var cursor = node.parent.flatMap { byID[$0] }
            while let current = cursor, !open.contains(current.id) {
                open.insert(current.id)
                cursor = current.parent.flatMap { byID[$0] }
            }
        }
        return open
    }

    static func visible(_ nodes: [WireSubagent], expanded: Set<String>)
        -> [(node: WireSubagent, depth: Int)] {
        var rows: [(WireSubagent, Int)] = []
        func walk(_ parent: String?, _ depth: Int) {
            for node in nodes where node.parent == parent {
                rows.append((node, depth))
                if expanded.contains(node.id) { walk(node.id, depth + 1) }
            }
        }
        walk(nil, 0)
        return rows
    }
}

struct SubagentTreeSection: View {
    let nodes: [WireSubagent]
    @State private var expanded: Set<String> = []

    var body: some View {
        Section("Subagents") {
            ForEach(SubagentRows.visible(nodes, expanded: expanded), id: \.node.id) { row in
                HStack(spacing: 6) {
                    if nodes.contains(where: { $0.parent == row.node.id }) {
                        Image(systemName: expanded.contains(row.node.id) ? "chevron.down" : "chevron.right")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    Circle().fill(color(row.node.state)).frame(width: 7, height: 7)
                    Text(row.node.type).font(.footnote.weight(.medium))
                    Text(row.node.description).font(.footnote).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .padding(.leading, CGFloat(row.depth) * 14)
                .contentShape(Rectangle())
                .onTapGesture { toggle(row.node.id) }
                .accessibilityLabel("\(row.node.type), \(row.node.description), \(row.node.state)")
            }
        }
        .onAppear { seed() }
        .onChange(of: nodes) { _, _ in seed() }
    }

    private func seed() { expanded.formUnion(SubagentRows.autoExpanded(nodes)) }
    private func toggle(_ id: String) {
        if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
    private func color(_ state: String) -> Color {
        switch state {
        case "blocked": return .orange
        case "done": return .secondary
        default: return .accentColor
        }
    }
}
