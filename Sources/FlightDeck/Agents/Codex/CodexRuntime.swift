import Foundation
import IntakeKit

/// Codex's observation half: rollout events, names, and live approval-dialog status.
///
/// Modern shared-daemon connections supply authoritative status and pending requests.
/// Rollout watchers remain responsible for history, errors and turn completion, and for
/// legacy standalone TUIs that cannot rejoin the daemon. Local menus use the live screen.
///
/// The shape mirrors `ClaudeRuntime`: one watcher per tab over a per-conversation file, plus
/// one shared watcher — one per codex account, not one for the whole app — over that
/// account's `session_index.jsonl`, fanned out by conversation id.
@MainActor
final class CodexRuntime: AgentRuntime {
    /// Reads only existing surfaces; observing a prompt must not wake a sleeping terminal.
    var readViewport: (UUID) -> String? = { _ in nil }
    var nativeDialogs: CodexNativeDialogs? {
        didSet {
            guard nativeDialogs !== oldValue else { return }
            subagentCounts = CodexSubagentCounts()
            for (id, source) in sources {
                source.nativeRequest?.cancel()
                source.nativeRequest = nil
                source.nativeSubscribed = false
                source.nativeStatus = false
                source.nextNativeRefresh = .distantPast
                if let count = source.subagentCount, count != 0 {
                    source.subagentCount = 0
                    source.subscribers.emit(.subagentCount(0))
                }
                oldValue?.unobserve(id)
                nativeDialogs?.observe(id)
                refreshNativeStatus(id, source: source)
            }
        }
    }
    var now: () -> Date = Date.init
    @MainActor
    private final class Source {
        let subscribers = SubscriberList()
        var watcher: CodexRolloutWatcher?
        var tabs: Set<UUID> = []
        var turnActivity: SessionActivity?
        var rolloutActivity: SessionActivity?
        var waitingOnScreen = false
        var nativeStatus = false
        var nativeSubscribed = false
        var nativeRequest: Task<Void, Never>?
        var nativeRequestID: UUID?
        var nextNativeRefresh = Date.distantPast
        var subagentCount: Int?

        func receive(_ event: AgentEvent) {
            if case .activity(let activity) = event {
                rolloutActivity = activity
                guard !nativeStatus else { return }
                turnActivity = activity
                subscribers.emit(.activity(waitingOnScreen ? .waiting : activity))
            } else {
                subscribers.emit(event)
            }
        }
    }

    private var sources: [UUID: Source] = [:]
    private var subagentCounts = CodexSubagentCounts()
    private let clock: WatchClock?
    private let indexURL: URL
    /// Where a conversation's text goes for ⌘K search. A closure rather than a stored
    /// reference, and re-read on every message batch rather than once at `attach` time —
    /// same reasoning as `ClaudeRuntime`'s own property: the index does not exist yet for the
    /// first few seconds of a real launch, and is nil in every test, where nothing ever wires
    /// it in at all.
    private let searchIndex: () -> SearchIndex?
    /// Which project a thread currently belongs to, for the same `ingest(_:for:offset:)`
    /// call. Looked up live rather than captured at `attach` time so a tab moved to another
    /// project mid-life keeps crediting the project it actually belongs to now.
    private let projectPath: (UUID) -> String?
    /// Where a thread's agent is working right now, for the same `ingest` call — the literal
    /// directory, which follows the tab into a worktree while `projectPath` stays put. A
    /// sibling closure rather than a stored value for the same reason as `projectPath`.
    private let workingDirectory: (UUID) -> String?

    /// Built on first attach and dropped with the last one, so a user with no codex tabs
    /// never has a watcher ticking over codex's index.
    private var names: CodexNameWatcher?

    init(
        clock: WatchClock? = nil, indexURL: URL = CodexNameWatcher.defaultIndexURL,
        searchIndex: @escaping () -> SearchIndex? = { nil },
        projectPath: @escaping (UUID) -> String? = { _ in nil },
        workingDirectory: @escaping (UUID) -> String? = { _ in nil }
    ) {
        self.clock = clock
        self.indexURL = indexURL
        self.searchIndex = searchIndex
        self.projectPath = projectPath
        self.workingDirectory = workingDirectory
    }

    /// Subscribes `tab` to `binding`'s thread, starting a watcher if this is the first
    /// subscriber. A second tab on the same thread joins the existing source rather than
    /// replacing it — which is what the old `attachments[id] = …` did, stopping the first
    /// tab's watcher and leaving the store to compensate with a value-matched fan-out.
    func attach(
        _ binding: AgentBinding, for tab: UUID, onEvent: @escaping (AgentEvent) -> Void
    ) -> AttachmentToken {
        let id = binding.conversationID
        let token = AttachmentToken(conversationID: id, tab: tab)

        if let existing = sources[id] {
            // `binding.transcriptURL` is discarded here — the joining subscriber gets the
            // first attacher's watcher, not its own. If two tabs land on one thread with
            // different transcript directories, both end up tailing the first attacher's
            // file, and a later `retarget` of the second tab (SessionStore.retarget) cannot
            // repoint it while the first tab stays attached. Tracked follow-up, not fixed here.
            existing.subscribers.add(token, onEvent)
            existing.tabs.insert(tab)
            // Native reconciliation suppresses unchanged statuses. A joining tab needs the
            // existing value now rather than waiting for the conversation's next transition.
            if existing.waitingOnScreen {
                onEvent(.activity(.waiting))
            } else if let activity = existing.turnActivity {
                onEvent(.activity(activity))
            }
            if let count = existing.subagentCount { onEvent(.subagentCount(count)) }
            return token
        }

        let source = Source()
        nativeDialogs?.observe(id)
        source.tabs.insert(tab)
        let subscribers = source.subscribers
        subscribers.add(token, onEvent)

        var watcher: CodexRolloutWatcher?
        if let url = binding.transcriptURL {
            watcher = CodexRolloutWatcher(
                url: url, conversationID: id, clock: clock,
                onEvent: { [weak source] event in
                    source?.receive(event)
                },
                // `onMessages` is passed unconditionally, never `nil` — see `ClaudeRuntime
                // .attach`'s own comment on this exact point. Deciding at attach time whether
                // to omit this closure would need to know now whether `searchIndex()` will
                // EVER return non-nil, which it cannot, and gating on today's answer would
                // reintroduce the ordering dependency reading it live was meant to avoid: a
                // thread attached before `AppDelegate.startSearch` runs would silently never
                // become searchable, forever, not just late. The cost of leaving it open is
                // bounded the same way, too — `CodexScan.read` decodes every line's JSON
                // regardless (for turn boundaries), so `CodexSearchCorpus
                // .indexedMessages(inObject:)` never re-parses.
                onMessages: { [weak self] messages in
                    guard let self, let index = self.searchIndex(),
                          let path = self.projectPath(id),
                          let workingDirectory = self.workingDirectory(id)
                    else { return }
                    let ref = TranscriptRef(
                        url: url, projectPath: path, accountHome: AgentID.codex.builtInHome,
                        workingDirectory: workingDirectory, conversationID: id.uuidString.lowercased(),
                        agent: .codex,
                        // `nil`, not a guess. A Flight-Deck-driven thread runs in a real
                        // `codex resume` TUI, not `codex exec` — the one value `provenance`
                        // exists to flag (see `SearchRanker`'s `.automated` tier) — but this
                        // runtime never reads the rollout's `session_meta.payload.source`
                        // itself, so claiming any specific string here would be a guess, not
                        // an observation. `nil` is the honest answer, and it is also the
                        // correct one: `SearchRanker` treats nil as `.transcript`, not
                        // `.automated`, so the conversation the user is having right now
                        // ranks above a `codex exec` run instead of below it.
                        provenance: nil, indexedName: nil, modified: Date()
                    )
                    // `offset: nil` — see `SearchIndex.ingest`'s doc comment. This watcher
                    // starts at end-of-file (it exists to catch turn boundaries, not
                    // backlog), so its own read position is never the right number to record
                    // as indexing progress: doing so would make the backfill resume from
                    // there and silently never index this thread's history.
                    try? index.ingest(messages, for: ref, offset: nil)
                }
            )
            watcher?.start()
        }
        source.watcher = watcher
        sources[id] = source
        clock?.add(source) { [weak self, weak source] in
            guard let self, let source else { return }
            self.refreshPromptStatus(source)
            self.refreshNativeStatus(id, source: source)
        }

        // Registered once per thread, not once per tab: a tab still has a name even with no
        // rollout to tail, and the list below is what fans that name out to every subscriber.
        nameWatcher().register(id) { subscribers.emit(.title($0)) }
        refreshNativeStatus(id, source: source)
        return token
    }

    private func refreshNativeStatus(_ id: UUID, source: Source) {
        guard let dialogs = nativeDialogs, source.nativeRequest == nil,
              now() >= source.nextNativeRefresh else { return }
        source.nextNativeRefresh = now().addingTimeInterval(5)
        // A dropped subscription must not leave a working tab idle forever. Read metadata
        // as a backstop; unlike resume, read never loads a standalone TUI's writer-locked
        // conversation. Only join threads already loaded by this shared daemon.
        let requestID = UUID()
        source.nativeRequestID = requestID
        source.nativeRequest = Task { [weak self, weak source] in
            defer {
                if source?.nativeRequestID == requestID { source?.nativeRequest = nil }
            }
            do {
                guard !Task.isCancelled, source != nil else { return }
                let raw = id.uuidString.lowercased()
                let result = try await dialogs.rpc.request("thread/read", ["threadId": raw, "includeTurns": false], timeoutSeconds: 3)
                guard !Task.isCancelled, let self, let source, self.sources[id] === source,
                      self.nativeDialogs === dialogs,
                      let thread = result["thread"] as? [String: Any],
                      let status = thread["status"] as? [String: Any] else { return }
                if status["type"] as? String == "notLoaded" {
                    // The daemon no longer owns this conversation. Keep consuming rollout
                    // activity while native is authoritative so a standalone takeover can
                    // immediately recover its current turn instead of retaining native idle.
                    source.nativeSubscribed = false
                    if source.nativeStatus {
                        source.nativeStatus = false
                        if let activity = source.rolloutActivity {
                            source.turnActivity = activity
                            source.subscribers.emit(.activity(source.waitingOnScreen ? .waiting : activity))
                        }
                    }
                    // An unloaded parent says nothing about children still running. Read
                    // their metadata below without resuming the parent or acquiring its lock.
                } else {
                    guard CodexThreadStatus.activity(from: status) != nil else { return }
                    dialogs.notify("thread/status/changed", params: ["threadId": raw, "status": status])
                    if !source.nativeSubscribed {
                        let joined = try await dialogs.rpc.request("thread/resume", ["threadId": raw, "excludeTurns": true], timeoutSeconds: 3)
                        guard !Task.isCancelled, self.sources[id] === source, self.nativeDialogs === dialogs else { return }
                        source.nativeSubscribed = true
                        if let thread = joined["thread"] as? [String: Any], let status = thread["status"] as? [String: Any] {
                            dialogs.notify("thread/status/changed", params: ["threadId": raw, "status": status])
                        }
                    }
                }
                let cutoff = self.subagentCounts.revision
                var descendants: [[String: Any]] = []
                var cursor: String?
                var cursors: Set<String> = []
                for page in 0..<20 {
                    var params: [String: Any] = ["ancestorThreadId": raw, "sourceKinds": ["subAgent"], "modelProviders": [String](),
                                                 "limit": 100, "useStateDbOnly": true]
                    if let cursor { params["cursor"] = cursor }
                    let response = try await dialogs.rpc.request("thread/list", params, timeoutSeconds: 3)
                    guard !Task.isCancelled, self.sources[id] === source, self.nativeDialogs === dialogs else { return }
                    guard let threads = response["data"] as? [[String: Any]] else {
                        throw CodexRPCError.malformed("thread/list returned no descendant data")
                    }
                    descendants.append(contentsOf: threads)
                    guard let next = response["nextCursor"] as? String else {
                        self.subagentCounts.reconcile(root: id, threads: descendants, through: cutoff)
                        self.publishSubagentCounts(knownRoot: id)
                        return
                    }
                    // Never publish a truncated count as a complete snapshot, nor loop on a
                    // repeated cursor. Live notifications keep the last known count current.
                    guard page < 19, cursors.insert(next).inserted else {
                        throw CodexRPCError.malformed("Codex descendant pagination did not complete")
                    }
                    cursor = next
                }
            } catch {
                // Keep the rollout/screen source on a legacy writer or transient disconnect;
                // the next clock reconciliation retries without restarting its terminal.
            }
        }
    }

    func receiveNativeNotification(_ method: String, params: [String: Any]) {
        guard nativeDialogs != nil, subagentCounts.receive(method, params: params) else { return }
        publishSubagentCounts()
    }

    private func publishSubagentCounts(knownRoot: UUID? = nil) {
        for (id, source) in sources {
            let count = subagentCounts.count(for: id)
            guard source.subagentCount != nil || count > 0 || id == knownRoot,
                  source.subagentCount != count else { continue }
            source.subagentCount = count
            source.subscribers.emit(.subagentCount(count))
        }
    }

    /// Drops one subscriber, and the watcher — plus the shared name watcher's registration —
    /// only when it was the last.
    ///
    /// Stopped explicitly rather than left to the released `Source`: it survives its owner by
    /// its registration on the shared `WatchClock`, and although that registration is weak
    /// and self-prunes, an invariant that holds only because of a retention detail two files
    /// away is not one to lean on.
    func detach(_ token: AttachmentToken) {
        let id = token.conversationID
        guard let source = sources[id] else { return }
        source.subscribers.remove(token)
        source.tabs.remove(token.tab)
        guard source.subscribers.isEmpty else { return }

        source.watcher?.stop()
        source.nativeRequest?.cancel()
        clock?.remove(source)
        sources[id] = nil
        nativeDialogs?.unobserve(id)
        names?.unregister(id)
        if names?.isEmpty == true {
            names?.stop()
            names = nil
        }
    }

    private func nameWatcher() -> CodexNameWatcher {
        if let names { return names }
        let watcher = CodexNameWatcher(url: indexURL, clock: clock)
        watcher.start()
        names = watcher
        return watcher
    }

    /// Test seam mirroring `ClaudeRuntime.drainForTesting()`, so runtime tests need no clock.
    func drainForTesting() {
        for source in sources.values { source.watcher?.drain() }
        names?.drain()
        for (id, source) in sources {
            refreshPromptStatus(source)
            refreshNativeStatus(id, source: source)
        }
    }

    private func refreshPromptStatus(_ source: Source) {
        let viewports = source.tabs.compactMap { readViewport($0) }
        // A missing or torn-down surface is no evidence that the person answered.
        guard !viewports.isEmpty else { return }
        let waiting = viewports.contains { CodexScreenPrompt.read($0) != nil }
        guard waiting != source.waitingOnScreen else { return }
        source.waitingOnScreen = waiting
        source.subscribers.emit(.activity(waiting ? .waiting : source.turnActivity ?? .idle))
    }

    func receiveNativeStatus(thread: UUID, activity: SessionActivity) {
        guard let source = sources[thread] else { return }
        if source.nativeStatus, source.turnActivity == activity { return }
        source.nativeStatus = true
        source.turnActivity = activity
        source.subscribers.emit(.activity(source.waitingOnScreen ? .waiting : activity))
    }
}
