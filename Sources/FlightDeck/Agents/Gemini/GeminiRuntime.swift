import Foundation

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
/// - **title**: `annotations/<id>.pbtxt`.
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
    }

    private weak var clock: WatchClock?
    private let paths: GeminiPaths
    private let roots: (UUID) -> [pid_t]
    private let observer: GeminiObserver
    private var subscribers: [Subscriber] = []
    private var isPolling = false

    init(clock: WatchClock?, paths: GeminiPaths, roots: @escaping (UUID) -> [pid_t],
         observer: GeminiObserver? = nil) {
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
        let work = subscribers.map { ($0.token, $0.binding.conversationID, roots($0.tab)) }
        let observer = self.observer
        Task { [weak self] in
            let results = await Task.detached(priority: .utility) {
                work.map { ($0.0, observer.observe(bound: $0.1, roots: $0.2)) }
            }.value
            guard let self else { return }
            self.isPolling = false
            for (token, observation) in results { self.apply(observation, to: token) }
        }
    }

    /// Synchronous pass, so tests need no expectations.
    func drain() {
        for subscriber in subscribers {
            apply(observer.observe(bound: subscriber.binding.conversationID, roots: roots(subscriber.tab)),
                  to: subscriber.token)
        }
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
