import Foundation
import HostKit

/// Each session's cloud budget: `infra-budgets.json`, apart from the ledger it is counted
/// against. A budget is keyed by session id only, so it outlives the tab's process (a resume,
/// a relaunch) and goes on being enforced on that session's machines after the tab is closed.
@MainActor
final class SessionBudgets {
    private(set) var budgets: [SessionBudget]
    private let file: VersionedJSONFile<SessionBudget>

    init(fileURL: URL) {
        file = VersionedJSONFile(url: fileURL, key: "budgets")
        budgets = file.load()
    }

    func budget(for session: UUID) -> SessionBudget? { budgets.first { $0.session == session } }

    /// Sets the cap, keeping the window a budget already has; a first budget starts at `now`.
    @discardableResult
    func set(_ session: UUID, capUSD: Double, now: Date) throws -> SessionBudget {
        try store(SessionBudget(session: session, capUSD: capUSD, since: budget(for: session)?.since ?? now))
    }

    /// A fresh window from `now`: what was spent before it no longer counts. `capUSD` nil keeps
    /// the cap; nil when there is neither a cap given nor one to keep.
    func renew(_ session: UUID, capUSD: Double?, now: Date) throws -> SessionBudget? {
        guard let cap = capUSD ?? budget(for: session)?.capUSD else { return nil }
        return try store(SessionBudget(session: session, capUSD: cap, since: now))
    }

    func clear(_ session: UUID) throws {
        let next = budgets.filter { $0.session != session }
        guard next != budgets else { return }
        try file.write(next)
        budgets = next
    }

    /// In-memory state changes only once the write succeeded, as `InfraRegistry.upsert`.
    private func store(_ b: SessionBudget) throws -> SessionBudget {
        var next = budgets.filter { $0.session != b.session }
        next.append(b)
        try file.write(next)
        budgets = next
        return b
    }
}
