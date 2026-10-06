import FleetKit
import Foundation

/// A claude agent id as it appears in `subagents/agent-<id>.jsonl`. Checked before an id from
/// the wire or a hook is joined onto a path: the phone's `timeline.page(agent:)` and
/// `prompt.answer(agent:)` would otherwise let `../` read any file this user can.
enum SubagentID {
    static func isValid(_ id: String) -> Bool {
        id.range(of: "^a[0-9a-f]{6,40}$", options: .regularExpression) != nil
    }
}

struct SubagentMeta: Equatable, Sendable {
    let type: String
    let description: String
    let parentID: String?
}

struct SubagentNode: Equatable, Sendable {
    enum State: Equatable, Sendable { case running, blocked(callID: String), done }
    let id: String
    let parentID: String?
    let type: String
    let description: String
    var state: State
    let modified: Date
}

/// One conversation's background agents, at every depth, rebuilt from files so it survives a
/// Flight Deck relaunch (the transcript fold it supplements starts at end of file on attach).
struct SubagentTree: Equatable, Sendable {
    var nodes: [SubagentNode]
    static let empty = SubagentTree(nodes: [])

    /// What `subagentCount` means: depth-1 agents still working. A blocked one is working.
    var liveTopLevelCount: Int {
        nodes.filter { $0.parentID == nil && $0.state != .done }.count
    }

    func node(_ id: String) -> SubagentNode? { nodes.first { $0.id == id } }

    func marking(blocked agentID: String, call: String) -> SubagentTree {
        SubagentTree(nodes: nodes.map { node in
            guard node.id == agentID else { return node }
            var copy = node
            copy.state = .blocked(callID: call)
            return copy
        })
    }

    /// Root-first ids down to `id`, for expanding the path to a blocked agent.
    func path(to id: String) -> [String] {
        var path: [String] = []
        var cursor = node(id)
        while let current = cursor, !path.contains(current.id) {
            path.insert(current.id, at: 0)
            cursor = current.parentID.flatMap(node)
        }
        return path
    }

    /// `keepDoneSince`: done agents last written before it are dropped, so the tree shows what
    /// is running plus what finished since the user last spoke, not the conversation's history.
    static func build(
        metas: [String: SubagentMeta],
        states: [String: (SubagentNode.State, Date)],
        keepDoneSince: Date?
    ) -> SubagentTree {
        var kept: [SubagentNode] = []
        for (id, (state, modified)) in states {
            // A file without its meta (or the reverse) is mid-creation: skip until both exist.
            guard let meta = metas[id] else { continue }
            if state == .done, let keepDoneSince, modified < keepDoneSince { continue }
            kept.append(SubagentNode(id: id, parentID: meta.parentID, type: meta.type,
                                     description: meta.description, state: state,
                                     modified: modified))
        }
        let ids = Set(kept.map(\.id))
        let rooted = kept.map { node -> SubagentNode in
            guard let parent = node.parentID, !ids.contains(parent) else { return node }
            return SubagentNode(id: node.id, parentID: nil, type: node.type,
                                description: node.description, state: node.state,
                                modified: node.modified)
        }
        return SubagentTree(nodes: rooted.sorted { ($0.modified, $0.id) < ($1.modified, $1.id) })
    }
}

/// The popover's rows: every node depth-first by `parentID`, nothing collapsed.
enum SubagentOutline {
    static func rows(_ tree: SubagentTree) -> [(node: SubagentNode, depth: Int)] {
        var out: [(node: SubagentNode, depth: Int)] = []
        var seen = Set<String>()
        func walk(_ node: SubagentNode, _ depth: Int) {
            // `seen` stops a parent cycle in corrupt meta files from recursing forever.
            guard seen.insert(node.id).inserted else { return }
            out.append((node, depth))
            for child in tree.nodes where child.parentID == node.id { walk(child, depth + 1) }
        }
        for root in tree.nodes where root.parentID == nil { walk(root, 0) }
        return out
    }
}

enum SubagentFiles {
    static func meta(at url: URL) -> SubagentMeta? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["agentType"] as? String
        else { return nil }
        return SubagentMeta(type: type, description: obj["description"] as? String ?? "",
                            parentID: obj["parentAgentId"] as? String)
    }

    /// Done when the newest conversational item is assistant text with nothing after it: 268 of
    /// 268 finished files on 2026-10-05 ended that way. Everything else is running — including
    /// an open call, which only attribution may call blocked.
    static func state(ofTail lines: [SourceLine]) -> SubagentNode.State {
        let items = lines.flatMap {
            ClaudeTimelineMapper.items(inLine: $0.text, at: $0.offset, sidechain: true)
        }
        guard let last = items.last else { return .running }
        return last.kind == .assistantText ? .done : .running
    }
}
