import FleetKit
import Foundation

/// The reopen stack, described for a phone.
///
/// Pure, and separate from `FleetService`, so the privacy property can be tested without a
/// socket — the same split `NewSessionOptionsProjection` makes.
///
/// **Nothing that resolves to a path travels.** The recorded `Session` carries
/// `pinnedConversationID`, `transcriptDirectory` and `transcriptPath`; none of them are read
/// here. The Mac keeps the whole value and looks it up again by `id` when a reopen comes back,
/// which is what lets the wire row be four fields.
enum ClosedSessionProjection {
    /// In the order given — `ClosedSessionHistory.sessionEntries` is already most-recent-first
    /// and the phone renders arrival order.
    static func rows(for entries: [ClosedSessionHistory.ClosedSession]) -> [WireClosedSession] {
        entries.map { entry in
            WireClosedSession(
                id: entry.session.id,
                title: entry.session.title,
                agent: entry.session.agent.rawValue,
                projectPath: entry.projectPath
            )
        }
    }
}
