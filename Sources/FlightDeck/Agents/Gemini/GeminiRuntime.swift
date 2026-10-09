import Foundation
import IntakeKit

/// What one look at an agy tab found. Gathered off the main actor; folded on it.
struct GeminiObservation: Equatable, Sendable {
    /// The conversation a process in the tab's own tree holds open (`GeminiPresence`), or nil
    /// when no agy runs there.
    var held: UUID?
    /// The summaries index's run status for the BOUND conversation.
    var running: Bool
    /// A step of the bound conversation waiting on the user.
    var pending: GeminiPendingCall?
    /// agy's title for the bound conversation.
    var title: String?
}

/// The reads one observation takes, behind one seam so the fold is testable from literals.
struct GeminiObserver: Sendable {
    var held: @Sendable ([pid_t]) -> UUID?
    var running: @Sendable (UUID) -> Bool
    var pending: @Sendable (UUID) -> GeminiPendingCall?
    var title: @Sendable (UUID) -> String?

    static func live(paths: GeminiPaths, presence: GeminiPresenceReading = GeminiPresence()) -> GeminiObserver {
        GeminiObserver(
            held: { presence.heldConversation(underRoots: $0, paths: paths) },
            running: { GeminiSummaries.summary($0, in: paths.summaries)?.isRunning ?? false },
            pending: { GeminiStepStore.pendingCall(in: paths.stepStore($0)) },
            title: { GeminiTitle.read(paths.annotation($0)) }
        )
    }

    func observe(bound: UUID, roots: [pid_t]) -> GeminiObservation {
        let held = held(roots)
        guard held == bound else { return GeminiObservation(held: held, running: false, pending: nil, title: nil) }
        // Only the bound, live conversation is read further: its stores are what the tab shows.
        return GeminiObservation(held: held, running: running(bound), pending: pending(bound), title: title(bound))
    }
}

/// Observes agy tabs WITHOUT installing anything into agy.
///
/// **The hook ruling.** agy has rich hooks, but only through files — the user's global
/// `~/.gemini/config/hooks.json` or a repo's `.agents/hooks.json` — with no per-launch flag or
/// variable (agy-tui-facts §5). Writing either would change every agy the user runs, or pollute
/// their repo. Everything a tab's status needs is already on disk, read-only, so nothing is
/// installed:
///
/// - **identity and liveness**: the presence lock held by the tab's own process tree
///   (`GeminiPresence`), which also follows `/clear` and a resume that minted a new id;
/// - **busy / idle**: the summaries index's `status`, which agy updates live (`RUNNING` within
///   ~0.4 s of a submit, `IDLE` at turn end and after a deny — watched at 4 Hz, 2026-10-08);
/// - **waiting**: a step with status WAITING in the conversation's step store, which appears
///   before the dialog is drawn and changes on the answer;
/// - **title**: `annotations/<id>.pbtxt`;
/// - **⌘K text**: `brain/<id>/.system_generated/logs/transcript_full.jsonl`, tailed on the same
///   beat (`GeminiTranscriptTail`). agy appends a request ~30 ms after it is submitted and a reply
///   when it finishes (probed live on agy 1.3.1, 2026-10-09), so this is as live as claude's own
///   transcript, and new messages are searchable before any backfill.
///
/// What this costs, stated: an Esc interrupt leaves `status` to agy's own transition (hooks
/// would not have helped: an interrupt fires no Stop either), and nothing here classifies an API
/// failure, which is why `GeminiAdapter.turnRecovery` is nil.
@MainActor
final class GeminiRuntime: AgentRuntime {
    private struct Subscriber {
        let token: AttachmentToken
        let tab: UUID
        let binding: AgentBinding
        let onEvent: (AgentEvent) -> Void
        var live = false
        var activity: SessionActivity?
        var title: String?
        /// Where this tab's transcript has been read to for ⌘K. Starts at byte 0, never at the
        /// end: see `GeminiTranscriptTail.start`.
        var transcript = GeminiTranscriptTail.start
    }

    private weak var clock: WatchClock?
    private let paths: GeminiPaths
    private let roots: (UUID) -> [pid_t]
    private let observer: GeminiObserver
    private var subscribers: [Subscriber] = []
    private var isPolling = false

    /// Where a conversation's text goes for ⌘K search. A closure re-read on every batch, for
    /// `ClaudeRuntime.searchIndex`'s reason: the index is wired in after runtimes may already
    /// be watching, and is nil in tests that never wire it.
    private let searchIndex: () -> SearchIndex?
    /// The tab's project and the directory its agent works in, keyed by TAB rather than by
    /// conversation as claude's and codex's are. This runtime always knows the tab, and a tab
    /// mid-`.rebound` has a pin that is changing under it; the tab id does not change.
    private let projectPath: (UUID) -> String?
    private let workingDirectory: (UUID) -> String?

    init(clock: WatchClock?, paths: GeminiPaths, roots: @escaping (UUID) -> [pid_t],
         observer: GeminiObserver? = nil,
         searchIndex: @escaping () -> SearchIndex? = { nil },
         projectPath: @escaping (UUID) -> String? = { _ in nil },
         workingDirectory: @escaping (UUID) -> String? = { _ in nil }) {
        self.searchIndex = searchIndex
        self.projectPath = projectPath
        self.workingDirectory = workingDirectory
        self.clock = clock
        self.paths = paths
        self.roots = roots
        self.observer = observer ?? .live(paths: paths)
    }

    func attach(_ binding: AgentBinding, for tab: UUID, onEvent: @escaping (AgentEvent) -> Void) -> AttachmentToken {
        let token = AttachmentToken(conversationID: binding.conversationID, tab: tab)
        if subscribers.isEmpty { clock?.add(self) { [weak self] in self?.poll() } }
        subscribers.append(Subscriber(token: token, tab: tab, binding: binding, onEvent: onEvent))
        return token
    }

    func detach(_ token: AttachmentToken) {
        subscribers.removeAll { $0.token == token }
        if subscribers.isEmpty { clock?.remove(self) }
    }

    /// One clock beat: read every tab off the main actor, fold on it.
    private func poll() {
        guard !isPolling, !subscribers.isEmpty else { return }
        isPolling = true
        let work = subscribers.map { ($0.token, $0.binding.conversationID, roots($0.tab), transcriptURL(of: $0), $0.transcript) }
        let observer = self.observer
        Task { [weak self] in
            let results = await Task.detached(priority: .utility) {
                work.map { ($0.0, observer.observe(bound: $0.1, roots: $0.2),
                            GeminiTranscriptTail.read($0.3, from: $0.4, conversationID: $0.1)) }
            }.value
            guard let self else { return }
            self.isPolling = false
            for (token, observation, tail) in results {
                self.index(tail, for: token)
                self.apply(observation, to: token)
            }
        }
    }

    /// Synchronous pass, so tests need no expectations.
    func drain() {
        for subscriber in subscribers {
            let tail = GeminiTranscriptTail.read(transcriptURL(of: subscriber), from: subscriber.transcript,
                                                 conversationID: subscriber.binding.conversationID)
            index(tail, for: subscriber.token)
            apply(observer.observe(bound: subscriber.binding.conversationID, roots: roots(subscriber.tab)),
                  to: subscriber.token)
        }
    }

    /// A placeholder binding may carry no URL; agy's layout names the file from the id alone.
    private func transcriptURL(of subscriber: Subscriber) -> URL {
        subscriber.binding.transcriptURL ?? paths.transcript(subscriber.binding.conversationID)
    }

    /// Records how far the tail got and hands what it found to the index.
    ///
    /// Indexed BEFORE the observation is applied: a `.rebound` in that observation detaches this
    /// subscriber, and the lines read for the old binding must not be dropped on the way out.
    private func index(_ tail: GeminiTranscriptTail.Read, for token: AttachmentToken) {
        guard let at = subscribers.firstIndex(where: { $0.token == token }) else { return }
        // Only advance a cursor whose read matched the subscriber it came back to: a re-attach
        // between the read and here starts its own tail, and must not inherit this one's offset.
        guard subscribers[at].transcript == tail.from else { return }
        subscribers[at].transcript = tail.cursor
        let subscriber = subscribers[at]
        guard !tail.messages.isEmpty, let index = searchIndex(),
              let project = projectPath(subscriber.tab),
              let workingDirectory = workingDirectory(subscriber.tab)
        else { return }
        let ref = TranscriptRef(
            url: tail.url, projectPath: project, accountHome: AgentID.gemini.builtInHome,
            workingDirectory: workingDirectory, conversationID: GeminiPaths.name(subscriber.binding.conversationID),
            agent: .gemini, provenance: nil, indexedName: nil, modified: Date()
        )
        // `offset: nil` — see `SearchIndex.ingest`. The backfill keeps its own resume point;
        // the overlap this tail re-reads from byte 0 is a no-op through `message_identity`.
        try? index.ingest(tail.messages, for: ref, offset: nil)
    }

    /// Folds one observation into the tab's state and reports what changed. Events are
    /// collected and delivered last, because `.rebound` makes the store detach and re-attach
    /// this very tab, which mutates `subscribers`.
    func apply(_ observation: GeminiObservation, to token: AttachmentToken) {
        guard let index = subscribers.firstIndex(where: { $0.token == token }) else { return }
        var subscriber = subscribers[index]
        var events: [AgentEvent] = []

        if let held = observation.held, held != subscriber.binding.conversationID {
            // agy is running a conversation the tab is not pinned to: the first submit of a new
            // tab, a `/clear`, or a resume agy answered with a fresh id. Follow it.
            events.append(.rebound(AgentBinding(conversationID: held, transcriptURL: paths.transcript(held))))
        } else {
            let live = observation.held != nil
            if live != subscriber.live {
                subscriber.live = live
                events.append(.lifecycle(live ? .live : .absent))
            }
            let activity: SessionActivity = !live ? .idle
                : observation.pending != nil ? .waiting
                : observation.running ? .busy : .idle
            if activity != subscriber.activity {
                let wasWorking = subscriber.activity == .busy || subscriber.activity == .waiting
                subscriber.activity = activity
                events.append(.activity(activity))
                if activity == .idle, wasWorking { events.append(.turnEnded) }
            }
            if let title = observation.title, title != subscriber.title {
                subscriber.title = title
                events.append(.title(title))
            }
        }
        subscribers[index] = subscriber
        let onEvent = subscriber.onEvent
        for event in events { onEvent(event) }
    }
}

/// One read of a gemini transcript for ⌘K: `TailReader` plus `GeminiSearchCorpus`'s line rule,
/// so live rows are the rows the backfill would write for the same lines.
enum GeminiTranscriptTail {
    struct Read: Sendable {
        let url: URL
        let from: TailCursor
        let cursor: TailCursor
        let messages: [IndexedMessage]
    }

    /// **From byte 0, not from the end** — the opposite of claude's and codex's watchers, which
    /// skip a file that predates them. agy names a new tab's conversation only once the first
    /// request is submitted, and writes that request to this file in the same instant (~30 ms,
    /// probed 2026-10-09); the `.rebound` re-attach therefore always finds it already on disk,
    /// and an end-of-file start would make the first thing the user typed unsearchable until the
    /// next backfill. Re-reading a resumed conversation's history is safe — the index ignores a
    /// message it already holds — and cheap: agy transcripts are tens of KB (largest seen: 71 KB).
    static let start = TailCursor(offset: 0, hasChosenStart: true)

    static func read(_ url: URL, from cursor: TailCursor, conversationID: UUID) -> Read {
        let tail = TailReader.read(url: url, offset: cursor.offset, hasChosenStart: cursor.hasChosenStart)
        let corpus = GeminiSearchCorpus()
        let name = GeminiPaths.name(conversationID)
        let messages = zip(tail.lines, tail.lineOffsets).flatMap { line, offset in
            corpus.indexedMessages(inLine: line, conversationID: name, at: Int(offset))
        }
        return Read(url: url, from: cursor,
                    cursor: TailCursor(offset: tail.offset, hasChosenStart: tail.hasChosenStart),
                    messages: messages)
    }
}
