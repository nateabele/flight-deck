import Foundation
import IntakeKit

/// A project's kinds as the Task kinds pane shows them.
enum KindsLoad: Equatable {
    case loaded([TaskKind])
    case unreadable(String)
}

extension RoutingService {
    func kinds(project: String) -> KindsLoad {
        do { return .loaded(try kindStore.kinds(project: url(project))) }
        catch let error as KindRegistryError { return .unreadable(error.message) }
        catch { return .unreadable("\(error)") }
    }

    /// The kind a block names, as the project's registry resolves it today (a merged kind
    /// answers as the kind it was merged into) — the same lookup the swarm's launch makes, so a
    /// hand-off spills on the kind its launch would have. Nil when the registry cannot be read
    /// or does not know the kind: the caller then does not spill rather than guess.
    func kind(for block: ExecutionBlock, project: URL) -> TaskKind? {
        guard let kinds = try? kindStore.kinds(project: project) else { return nil }
        return KindResolution.resolve(block.kind, in: kinds)
    }

    /// *New* until you open it (spec §6): only planning proposals, which arrive unasked.
    func isNew(_ kind: TaskKind, project: String) -> Bool {
        kind.origin == .planning && !preferences.seenKinds(project: project).contains(kind.id)
    }

    func markSeen(_ id: KindID, project: String) {
        guard !preferences.seenKinds(project: project).contains(id) else { return }
        preferences.markKindsSeen([id], project: project)
        bump()
    }

    /// Renaming changes only the label; the id every block names stays put, so nothing re-routes.
    func rename(_ id: KindID, to name: String, project: String) -> String? {
        do { try kindStore.rename(id, to: name, project: url(project)) }
        catch let error as KindRegistryError { return error.message }
        catch { return "\(error)" }
        bump()
        return nil
    }

    func reweight(_ id: KindID, dimensions: [String: Double], project: String) async -> String? {
        do { try kindStore.reweight(id, dimensions: dimensions, project: url(project)) }
        catch let error as KindRegistryError { return error.message }
        catch { return "\(error)" }
        bump()
        kindNote = await reroute(project: project, affected: id)
        return nil
    }

    func merge(_ id: KindID, into target: KindID, project: String) async -> String? {
        do { try kindStore.merge(id, into: target, project: url(project)) }
        catch let error as KindRegistryError { return error.message }
        catch { return "\(error)" }
        bump()
        kindNote = await reroute(project: project, affected: id)
        return nil
    }

    /// Open tasks per live kind: a task whose kind was merged counts toward the kind it resolves to.
    func openCounts(project: String) async -> [KindID: Int] {
        guard case .success(let rows) = await tasks.openTasks(project: project) else { return [:] }
        let kinds = (try? kindStore.kinds(project: url(project))) ?? []
        var counts: [KindID: Int] = [:]
        for row in rows {
            guard case .success(let block?) = ExecutionBlockCodec.decode(agentContext: row.agentContext) else { continue }
            counts[KindResolution.resolve(block.kind, in: kinds)?.id ?? block.kind, default: 0] += 1
        }
        return counts
    }

    /// Re-routes `affected`'s open, unpinned tasks (spec §5) and says what happened. A read
    /// failure is reported, not swallowed: "re-routed 0" would claim the tasks were checked.
    func reroute(project: String, affected: KindID) async -> String {
        let rows: [TaskContextRow]
        switch await tasks.openTasks(project: project) {
        case .failure(let error): return "Could not read open tasks: \(error.message)"
        case .success(let read): rows = read
        }
        let catalogs = await catalogs()
        let kinds = (try? kindStore.kinds(project: url(project))) ?? []
        let plan = KindReroute.plan(rows: rows, affected: affected, project: url(project), kinds: kinds,
                                    router: makeRouter(), catalogs: catalogs, now: now())
        var written = 0
        var failures: [(id: String, why: String)] = []
        // A task pinned after the read: the writer refuses it, and it is still one we examined.
        var pinnedAtWrite = 0
        for change in plan.changes {
            switch await writer.writeBlock(change.block, id: change.id, project: project) {
            case .written: written += 1
            case .skippedPinned: pinnedAtWrite += 1
            case .failed(let why): failures.append((change.id, why))
            }
        }
        var note = "Re-routed \(written) open task\(written == 1 ? "" : "s")"
        let pinned = plan.skippedPinned.count + pinnedAtWrite
        if pinned > 0 { note += "; \(pinned) pinned left alone" }
        if !plan.invalid.isEmpty { note += "; \(plan.invalid.count) with an invalid block skipped" }
        if !plan.unroutable.isEmpty { note += "; \(plan.unroutable.count) unroutable" }
        if let first = failures.first { note += "; \(failures.count) failed (\(failures.map(\.id).joined(separator: ", "))): \(first.why)" }
        return note
    }
}

extension RoutingService: EncodeRoutingProviding {
    func agentContexts(for steps: [ApplyStep], project: String) async -> [String: String] {
        // An edit-only release has nothing to route, and loading catalogs spawns codex's
        // app-server on first use — so it never loads them.
        let creates = steps.contains { step in
            if case .create = step { return true }
            return false
        }
        guard creates else { return [:] }
        let catalogs = await catalogs()
        let outcome = EncodeRouting.route(steps, project: url(project), registry: kindStore, router: makeRouter(),
                                          catalogs: catalogs, now: now())
        if !outcome.proposed.isEmpty { bump() }
        return outcome.contexts
    }
}
