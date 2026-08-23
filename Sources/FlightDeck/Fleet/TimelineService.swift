import FleetKit
import Foundation

/// Where a tab's conversation is read from.
enum TimelineSource: Equatable {
    case file(agent: AgentID, url: URL)
    /// The tab exists and its agent reports no transcript at all — a codex thread whose
    /// `thread/start` never returned a path. Permanent, unlike a file that is not written yet.
    case noTranscript
    /// No such tab. A phone holding a row the Mac has since closed.
    case unknownSession
}

/// The wire error code a request failed with, verbatim — `err`'s `code` field.
///
/// A one-field wrapper rather than the bare `String` it carries, because `Result`'s failure
/// type must be an `Error` and `String` is not one. `ExpressibleByStringLiteral` keeps every
/// call site and assertion reading as the literal code (`.failure("unreadable")`) rather than
/// as a constructor, which is the only thing the bare `String` was buying.
///
/// The codes and what a client must do with each are documented on `FleetRequestError`.
struct TimelineErrorCode: Error, Equatable, Sendable, ExpressibleByStringLiteral {
    let code: String

    init(stringLiteral code: String) { self.code = code }
}

/// Answers a phone's history request.
///
/// The only type that knows both a `SessionStore` and `TimelineReader`, in the same spirit as
/// `FleetService` being the only type that knows both a store and an `NWListener`: the reader
/// stays testable without a store, the store stays testable without a reader, and the thing
/// that needs both is here where it can be read at once.
///
/// **The read runs off the main actor**, exactly as `TranscriptWatcher.poll()` dispatches
/// `Scan.read`, and for the same reason that type documents: transcript records are large —
/// one assistant record carries whole tool inputs and results — and parsing a page of them on
/// the main thread while an agent is producing output is a visible stall in the Mac's own UI.
/// Only the resolution and the answer are main-actor.
///
/// It reads and never writes, which is why the timeline needed no `FleetEvent` and no change
/// to the replication path. `FleetReplicator`'s DEBUG drift check guards mutation sites that
/// forget to record their event; this adds none.
@MainActor
final class TimelineService {
    private let store: SessionStore

    /// Test seam, in the same shape and for the same reason as `SessionStore.titleResolver`:
    /// the actor boundary in `page(session:anchor:limit:)` is the thing worth asserting, and
    /// no test can stand on both sides of it without a substitutable read. Dispatched rather
    /// than called, so a substituted reader runs off the main actor too and can rendezvous
    /// with main-actor work — closing the tab — that happens while a page is in flight.
    ///
    /// `@Sendable` and free of `self`: what crosses into the detached task below is this
    /// function value and five values, never the service or the store. Arguments in
    /// `TimelineReader.page`'s own order — session, agent, url, anchor, limit — since a
    /// function type cannot carry its labels.
    var reader: @Sendable (UUID, AgentID, URL, TimelineAnchor, Int)
        -> Result<TimelinePage, TimelineReadFailure> = { session, agent, url, anchor, limit in
            TimelineReader.page(
                session: session, agent: agent, url: url, anchor: anchor, limit: limit
            )
        }

    init(store: SessionStore) {
        self.store = store
    }

    /// The failure side is the wire error code — see `TimelineErrorCode`.
    ///
    /// **Resolved once, up front, and never re-checked afterwards.** The tab being closed
    /// while its read is in flight is the ordinary case rather than an edge one — taking the
    /// read off the main actor is precisely what leaves the main actor free to close it — and
    /// a page that was legitimately resolved is still the right answer for the tab that was
    /// asked about. Asking the store again after the read would throw away a page the Mac
    /// already has in hand and report a live conversation as a stale row.
    ///
    /// Nothing is serialized: each call resolves independently and reads through its own file
    /// handle, so two phones (or one phone scrolling while another screen refreshes) are in
    /// flight at once rather than queued behind each other's scan.
    func page(
        session: UUID, anchor: TimelineAnchor, limit: Int
    ) async -> Result<TimelinePage, TimelineErrorCode> {
        let agent: AgentID
        let url: URL
        switch store.timelineSource(of: session) {
        case .file(let resolvedAgent, let resolvedURL):
            agent = resolvedAgent
            url = resolvedURL
        case .noTranscript:
            return .failure("no_transcript")
        case .unknownSession:
            return .failure("unknown_session")
        }

        // Everything above is main-actor; everything inside is not. `Task.detached` rather
        // than `Task`, which would inherit this actor and read on the main thread after all.
        let reader = self.reader
        let read = await Task.detached(priority: .utility) {
            reader(session, agent, url, anchor, limit)
        }.value

        switch read {
        case .success(let page):
            return .success(page)
        case .failure(.unreadable):
            // Showable and retryable, and deliberately the same answer as "no transcript file
            // yet": both render as "no history" and neither lies. See `TimelineReadFailure`.
            return .failure("unreadable")
        }
    }
}
