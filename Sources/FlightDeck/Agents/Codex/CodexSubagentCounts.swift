import Foundation

/// Folds native descendant metadata independently of terminal rendering and rollout history.
struct CodexSubagentCounts {
    private struct Node {
        var parent: UUID?
        var active: Bool
        var revision: Int
    }
    private var nodes: [UUID: Node] = [:]
    private(set) var revision = 0

    mutating func receive(_ method: String, params: [String: Any]) -> Bool {
        if method == "thread/started", let thread = params["thread"] as? [String: Any] {
            return record(thread)
        }
        if let raw = params["threadId"] as? String, let id = UUID(uuidString: raw) {
            if method == "thread/status/changed" {
                set(id, active: Self.active(params["status"] as? [String: Any]))
                return true
            }
            if ["turn/completed", "thread/closed", "thread/archived"].contains(method) {
                set(id, active: false)
                return true
            }
            if method == "turn/started" { set(id, active: true); return true }
        }
        guard method == "item/started" || method == "item/completed",
              let item = params["item"] as? [String: Any] else { return false }
        let sender = (item["senderThreadId"] as? String ?? params["threadId"] as? String).flatMap(UUID.init(uuidString:))
        if item["type"] as? String == "subAgentActivity",
           let sender, let raw = item["agentThreadId"] as? String, let child = UUID(uuidString: raw) {
            switch item["kind"] as? String {
            case "started": set(child, parent: sender, active: true)
            case "completed", "interrupted": set(child, parent: sender, active: false)
            default: break
            }
            return true
        }
        guard item["type"] as? String == "collabAgentToolCall" else { return false }
        let tool = item["tool"] as? String
        let receivers = (item["receiverThreadIds"] as? [String] ?? []).compactMap(UUID.init(uuidString:))
        if tool == "spawnAgent", let sender {
            for child in receivers {
                set(child, parent: sender, active: item["status"] as? String == "inProgress" ? true : nil)
            }
        }
        if let states = item["agentsStates"] as? [String: [String: Any]] {
            for (raw, state) in states {
                guard let child = UUID(uuidString: raw), nodes[child]?.parent != nil else { continue }
                switch state["status"] as? String {
                case "pendingInit", "running": set(child, active: true)
                case "completed", "interrupted", "errored", "shutdown", "notFound": set(child, active: false)
                default: break
                }
            }
        }
        if tool == "closeAgent", item["status"] as? String == "completed" {
            for child in receivers where nodes[child]?.parent != nil { set(child, active: false) }
        }
        return true
    }

    /// Apply only complete snapshots. Events received after the query started win over its
    /// older metadata, so a fast completion cannot be resurrected by an in-flight list reply.
    mutating func reconcile(root: UUID, threads: [[String: Any]], through cutoff: Int) {
        let present = Set(threads.compactMap { ($0["id"] as? String).flatMap(UUID.init(uuidString:)) })
        let missing = nodes.keys.filter { !present.contains($0) && descends($0, from: root) }
        for id in missing where nodes[id]!.revision <= cutoff { set(id, active: false) }
        for thread in threads {
            guard let raw = thread["id"] as? String, let id = UUID(uuidString: raw),
                  nodes[id].map({ $0.revision <= cutoff }) ?? true else { continue }
            _ = record(thread)
        }
    }

    func count(for root: UUID) -> Int {
        nodes.reduce(0) { $0 + ($1.value.active && descends($1.key, from: root) ? 1 : 0) }
    }

    @discardableResult
    private mutating func record(_ thread: [String: Any]) -> Bool {
        guard let raw = thread["id"] as? String, let id = UUID(uuidString: raw) else { return false }
        let source = thread["source"] as? [String: Any]
        let subagent = source?["subAgent"] as? [String: Any]
        let spawn = subagent?["thread_spawn"] as? [String: Any]
        let parent = (thread["parentThreadId"] as? String ?? spawn?["parent_thread_id"] as? String).flatMap(UUID.init(uuidString:))
        set(id, parent: parent, active: Self.active(thread["status"] as? [String: Any]))
        return true
    }

    private mutating func set(_ id: UUID, parent: UUID? = nil, active: Bool?) {
        guard parent != id else { return }
        let previous = nodes[id]
        let parent = parent ?? previous?.parent
        let active = active ?? previous?.active ?? false
        // Even an unchanged completion is a fresh observation: a query begun before it
        // must not resurrect the child from an older active snapshot.
        revision += 1
        nodes[id] = Node(parent: parent, active: active, revision: revision)
    }

    private func descends(_ id: UUID, from root: UUID) -> Bool {
        guard id != root else { return false }
        var current = id
        var seen: Set<UUID> = [id]
        while let parent = nodes[current]?.parent, seen.insert(parent).inserted {
            if parent == root { return true }
            current = parent
        }
        return false
    }

    private static func active(_ status: [String: Any]?) -> Bool? {
        switch status?["type"] as? String {
        case "active": return true
        case "idle", "notLoaded", "systemError": return false
        default: return nil
        }
    }
}
