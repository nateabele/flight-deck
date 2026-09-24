import CoreGraphics
import Foundation

/// Layered DAG layout over a dependency graph: pure geometry, no I/O, no SwiftUI, so it is
/// trivially unit-testable and composable by the Canvas overlay and camera (later tasks).
/// Coordinates are keyed by `contentHash` — a hash of topology only, never status — so a
/// status-only re-poll (the common case: the graph itself rarely changes) reduces to the
/// same node set at the same positions and the overlay never visibly jumps.
struct DependencyGraphLayout: Equatable {
    struct Node: Equatable {
        let id: String
        let rank: Int
        let position: CGPoint
    }

    let nodes: [String: Node]
    let contentHash: Int
    let rootCauseID: String?

    /// Ranks every bead by longest path from a rank-0 source (no incoming edge in `edges`),
    /// so a node reachable through more than one path (the diamond's join) sinks to its
    /// deepest rank and is placed exactly once, never once per incoming path.
    static func layout(beadIDs: [String], edges: [FlywheelProjection.DepEdge],
                        statusByBead: [String: AgentStatus], nodeSize: CGSize, spacing: CGSize) -> DependencyGraphLayout {
        // Longest-path rank via topological relaxation: repeatedly push a node's rank to
        // max(incoming source rank + 1) until nothing changes. Bounded by node count so a
        // cyclic input (which shouldn't occur for real dependency data) can't loop forever.
        var rank: [String: Int] = Dictionary(uniqueKeysWithValues: beadIDs.map { ($0, 0) })
        let sortedEdges = edges.sorted { ($0.from, $0.to) < ($1.from, $1.to) }
        let iterationCap = max(beadIDs.count, 1)
        for _ in 0..<iterationCap {
            var changed = false
            for edge in sortedEdges {
                guard let fromRank = rank[edge.from] else { continue }
                let candidate = fromRank + 1
                if (rank[edge.to] ?? 0) < candidate {
                    rank[edge.to] = candidate
                    changed = true
                }
            }
            if !changed { break }
        }

        // Within-rank order is lexicographic by bead id, so position is a pure function of
        // topology (never insertion order or status) — required for contentHash stability.
        let sortedIDs = beadIDs.sorted()
        var rankGroups: [Int: [String]] = [:]
        for id in sortedIDs {
            rankGroups[rank[id] ?? 0, default: []].append(id)
        }

        var nodes: [String: Node] = [:]
        for (r, ids) in rankGroups {
            for (index, id) in ids.enumerated() {
                let x = CGFloat(index) * (nodeSize.width + spacing.width)
                let y = CGFloat(r) * (nodeSize.height + spacing.height)
                nodes[id] = Node(id: id, rank: r, position: CGPoint(x: x, y: y))
            }
        }

        var hasher = Hasher()
        hasher.combine(sortedIDs)
        for edge in sortedEdges {
            hasher.combine(edge.from)
            hasher.combine(edge.to)
        }
        let contentHash = hasher.finalize()

        let rootCauseID = Self.rootCause(edges: sortedEdges, rank: rank, statusByBead: statusByBead)

        return DependencyGraphLayout(nodes: nodes, contentHash: contentHash, rootCauseID: rootCauseID)
    }

    /// Among `.stalled` nodes, the greatest-rank one reachable (following edge direction)
    /// from some `.blocked` node — the deepest actionable cause on the critical path, as
    /// opposed to the blocked node itself (which is a symptom, not the thing to unblock).
    private static func rootCause(edges: [FlywheelProjection.DepEdge], rank: [String: Int],
                                   statusByBead: [String: AgentStatus]) -> String? {
        let blockedSources = statusByBead.filter { $0.value == .blocked }.map(\.key)
        guard !blockedSources.isEmpty else { return nil }

        var adjacency: [String: [String]] = [:]
        for edge in edges {
            adjacency[edge.from, default: []].append(edge.to)
        }

        var reachable: Set<String> = []
        var queue = blockedSources
        var visited: Set<String> = Set(blockedSources)
        while let current = queue.popLast() {
            for next in adjacency[current] ?? [] {
                reachable.insert(next)
                if !visited.contains(next) {
                    visited.insert(next)
                    queue.append(next)
                }
            }
        }

        let candidates = statusByBead.filter { $0.value == .stalled && reachable.contains($0.key) }
        return candidates.keys.max { lhs, rhs in
            let lhsRank = rank[lhs] ?? 0
            let rhsRank = rank[rhs] ?? 0
            if lhsRank != rhsRank { return lhsRank < rhsRank }
            return lhs < rhs
        }
    }
}
