import FleetKit
import Foundation

/// The desktop's New Session menu, described for a phone — and read back when one is tapped.
///
/// **Both directions go through `NewSessionAffordance.menu`, and that is the whole point.** The
/// rules with edges live there: an agent with no live account contributes no row, order decides
/// the ⌘N ladder, one account is a flat row and several are a submenu, and the tick marks the
/// resolved account only inside a submenu. A second implementation of any of those drifts the
/// first time one moves, so this file translates that function's output and never restates it.
///
/// Pure, and separate from `FleetService`, so the privacy assertion and the stale-index
/// fallback can both be tested without a socket.
enum NewSessionOptionsProjection {

    /// The menu as wire rows, in the order the entries arrived.
    ///
    /// **Order is preserved, never sorted.** Position is what binds an agent to its keyboard
    /// chord on the Mac (`NewSessionAffordance.ladder`), so a phone that sorted its own copy
    /// would quietly disagree with the sidebar about what ⌘N does.
    ///
    /// **`index` is a position, not an id.** An account UUID resolves to a home directory, and
    /// `FleetAccountEmissionTests.testAnAccountsHomeNeverReachesTheWire` asserts that neither
    /// travels. A flat row is always index 0 — it is its agent's only account.
    static func rows(
        for entries: [NewSessionAffordance.MenuEntry],
        name: (UUID) -> String?
    ) -> [WireNewSessionOption] {
        entries.flatMap { entry -> [WireNewSessionOption] in
            switch entry {
            case .agent(let agent, _, let isResolved):
                // A flat row carries no account name: the phone draws "New <Agent> Session",
                // exactly as the sidebar does, and `accountName == nil` is how it knows to.
                return [WireNewSessionOption(
                    agent: agent.rawValue, agentName: agent.displayName,
                    index: 0, accountName: nil, isDefault: isResolved
                )]
            case .submenu(let agent, let rows):
                return rows.enumerated().compactMap { index, row in
                    guard case .agent(_, let account, let isResolved) = row else { return nil }
                    return WireNewSessionOption(
                        agent: agent.rawValue, agentName: agent.displayName,
                        index: index, accountName: name(account) ?? agent.displayName,
                        isDefault: isResolved
                    )
                }
            }
        }
    }

    /// Which account a tapped row means, or **nil when the row no longer makes sense**.
    ///
    /// The index is only meaningful against the account list the Mac resolved at the instant it
    /// answered, and accounts can be added or signed out between the fetch and the tap. The
    /// agent check is the guard: an index whose agent no longer matches is not reinterpreted
    /// against whatever agent now sits at that position, because that is a silent wrong-account
    /// bug — a session opened as a login the reader did not choose, indistinguishable from
    /// having chosen it. `nil` sends the caller to the project's default instead, which is a
    /// visible, recoverable answer.
    static func account(
        forAgent agent: String, index: Int, in entries: [NewSessionAffordance.MenuEntry]
    ) -> UUID? {
        for entry in entries where entry.agent.rawValue == agent {
            switch entry {
            case .agent(_, let account, _):
                // A flat row is an agent's only account, so the only index that can mean
                // anything is 0. Anything else is a menu that has changed shape underneath the
                // phone — an account added since the fetch — and is refused rather than guessed.
                return index == 0 ? account : nil
            case .submenu(_, let rows):
                guard rows.indices.contains(index),
                      case .agent(_, let account, _) = rows[index] else { return nil }
                return account
            }
        }
        return nil
    }
}
