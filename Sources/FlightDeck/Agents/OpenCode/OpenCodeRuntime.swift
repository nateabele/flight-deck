import Foundation
import IntakeKit
import OSLog

/// The observation half of an OpenCode account: one event stream, fanned out to tabs.
///
/// One per account, like codex's, because one `opencode serve` per account emits every
/// session's events on one stream. A source per CONVERSATION (keyed by its derived UUID), with
/// the tabs subscribed to it — the `AgentRuntime` contract: a value match selects the source,
/// identity selects the tabs.
///
/// **A conversation is a TREE here, not a session.** A subagent runs in a child session and
/// raises its permission requests there (see `OpenCodeSignal`), so the runtime keeps a
/// child→root map — filled from `session.created`, and by asking the server when a child it
/// never saw created turns up — and routes a child's activity onto its root's tab:
///
/// - a child's open request makes the tab `waiting`, exactly as the parent's own would;
/// - a child running or finishing moves the tab's sub-agent count;
/// - a child's turn ending, erroring or being named means nothing for the tab, and is dropped.
@MainActor
final class OpenCodeRuntime: AgentRuntime {
    private struct Source {
        let subscribers: SubscriberList
        let session: String
        let mirror: URL?
        /// Requests open anywhere in this tree. Non-empty means `waiting`, whatever the
        /// root's own `session.status` says — OpenCode keeps reporting the blocked turn `busy`.
        var openRequests: Set<String> = []
        var busyChildren: Set<String> = []
        var syncing = false
        var syncAgain = false
    }

    private var sources: [UUID: Source] = [:]
    /// Child session → root session, for every child seen in a tree this runtime watches.
    private var roots: [String: String] = [:]
    private let server: OpenCodeServing
    /// The transport behind the runtime's own requests (status, pending requests, a child's
    /// parent). A seam for tests, like `OpenCodeAdapter.transport`.
    var transport: @MainActor (OpenCodeEndpoint) -> OpenCodeHTTP = {
        URLSessionOpenCodeHTTP(baseURL: $0.url, password: $0.password)
    }
    private let searchIndex: () -> SearchIndex?
    private let projectPath: (UUID) -> String?
    private let workingDirectory: (UUID) -> String?
    private var stream: OpenCodeEventStream?
    /// Signals from sessions whose root is being looked up, in arrival order, replayed once it
    /// is known — so a request's `asked` and a fast `replied` cannot be applied out of order.
    private var awaitingRoot: [String: [(OpenCodeSignal, String?)]] = [:]
    private var lastRevive = Date.distantPast
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.flightdeck.FlightDeck",
        category: "opencode"
    )

    init(
        server: OpenCodeServing,
        searchIndex: @escaping () -> SearchIndex? = { nil },
        projectPath: @escaping (UUID) -> String? = { _ in nil },
        workingDirectory: @escaping (UUID) -> String? = { _ in nil }
    ) {
        self.server = server
        self.searchIndex = searchIndex
        self.projectPath = projectPath
        self.workingDirectory = workingDirectory
    }

    func attach(
        _ binding: AgentBinding, for tab: UUID, onEvent: @escaping (AgentEvent) -> Void
    ) -> AttachmentToken {
        let id = binding.conversationID
        let token = AttachmentToken(conversationID: id, tab: tab)
        if let existing = sources[id] {
            existing.subscribers.add(token, onEvent)
            return token
        }
        let subscribers = SubscriberList()
        subscribers.add(token, onEvent)
        // A binding with no mirror path names no OpenCode session (a tab restored from a
        // corrupted record): it still gets a source, so detach is symmetric, and hears nothing.
        guard let session = OpenCodeIdentity.sessionID(fromTranscript: binding.transcriptURL) else {
            sources[id] = Source(subscribers: subscribers, session: "", mirror: nil)
            return token
        }
        sources[id] = Source(subscribers: subscribers, session: session, mirror: binding.transcriptURL)
        startStreamIfNeeded()
        sync(id)
        return token
    }

    func detach(_ token: AttachmentToken) {
        let id = token.conversationID
        guard let source = sources[id] else { return }
        source.subscribers.remove(token)
        guard source.subscribers.isEmpty else { return }
        sources[id] = nil
        roots = roots.filter { $0.value != source.session }
        if sources.values.allSatisfy({ $0.session.isEmpty }) {
            stream?.stop()
            stream = nil
        }
    }

    private func startStreamIfNeeded() {
        if stream == nil {
            stream = OpenCodeEventStream(
                endpoint: { [weak self] in self?.server.endpoint },
                onBatch: { [weak self] in self?.handle($0) },
                onConnect: { [weak self] in self?.resynchronize() },
                onDisconnect: { [weak self] in self?.reviveServerIfNeeded() }
            )
        }
        stream?.start()
    }

    /// The stream dropped while tabs are attached. If the server itself died, start it again:
    /// `OpenCodeServer.start` is a no-op for a healthy server, and otherwise brings one up on the
    /// SAME port, which is where every attached TUI is already trying to reconnect. Throttled,
    /// because a stream that cannot connect retries on its own backoff.
    private func reviveServerIfNeeded() {
        guard sources.values.contains(where: { !$0.session.isEmpty }),
              Date().timeIntervalSince(lastRevive) > 5
        else { return }
        lastRevive = Date()
        let server = self.server
        Task { @MainActor in
            do {
                try await server.start()
            } catch {
                Self.logger.error("could not revive the OpenCode server: \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// After a (re)connect: anything that happened while the stream was down was not
    /// delivered — including after a Flight Deck relaunch, when the server kept running and a
    /// tab may be blocked on a request raised while nobody was listening. So re-read the
    /// mirrors, every watched session's status, and the requests pending in each tree.
    private func resynchronize() {
        for id in sources.keys { sync(id) }
        Task { [weak self] in
            await self?.reconcileRequests()
            await self?.refreshStatuses()
        }
    }

    /// Brings `openRequests` and the mirror in line with what the server says is pending: a
    /// request this runtime never saw asked is logged now (so the phone and `PromptService`
    /// can name it), and one it thinks is open that the server no longer has — answered while
    /// disconnected, or dropped by a server restart — is closed, so the tab cannot stay
    /// `waiting` on a dialog that does not exist.
    private func reconcileRequests() async {
        guard let endpoint = server.endpoint else { return }
        let client = OpenCodeClient(http: transport(endpoint))
        var directories: [String: [UUID]] = [:]
        for (id, source) in sources where !source.session.isEmpty {
            directories[workingDirectory(id) ?? "", default: []].append(id)
        }
        for (directory, ids) in directories where !directory.isEmpty {
            guard let pending = try? await client.pendingRequestObjects(directory: directory) else { continue }
            let asked = pending.permissions.map { ("permission.asked", $0) } + pending.questions.map { ("question.asked", $0) }
            var pendingByRoot: [UUID: [(String, [String: Any])]] = [:]
            for (type, request) in asked {
                guard let session = request["sessionID"] as? String else { continue }
                var root: String? = conversation(forRoot: session) != nil ? session : roots[session]
                if root == nil { root = await resolveRoot(of: session, directory: directory) }
                guard let root, let id = conversation(forRoot: root), ids.contains(id) else { continue }
                if root != session { roots[session] = root }
                pendingByRoot[id, default: []].append((type, request))
            }
            for id in ids {
                guard var source = sources[id] else { continue }
                let current = pendingByRoot[id] ?? []
                let currentIDs = Set(current.compactMap { $0.1["id"] as? String })
                let written = Self.loggedRequests(in: source.mirror)
                for (type, request) in current {
                    guard let requestID = request["id"] as? String else { continue }
                    if !written.open.contains(requestID) {
                        for case .prompt(_, let line) in OpenCodeEventMapper.signals(type: type, properties: request) {
                            append(line, to: source.mirror)
                        }
                    }
                    source.openRequests.insert(requestID)
                }
                for stale in source.openRequests.subtracting(currentIDs) {
                    source.openRequests.remove(stale)
                    append(OpenCodeEventMapper.encode([
                        "type": "prompt.resolved", "id": stale, "outcome": "gone",
                        "time": OpenCodeEventMapper.millis(Date()),
                    ]), to: source.mirror)
                }
                // Requests the mirror still shows open that the server no longer has — written
                // by an earlier run that never saw them answered.
                for stale in written.open.subtracting(currentIDs) where !source.openRequests.contains(stale) {
                    append(OpenCodeEventMapper.encode([
                        "type": "prompt.resolved", "id": stale, "outcome": "gone",
                        "time": OpenCodeEventMapper.millis(Date()),
                    ]), to: source.mirror)
                }
                sources[id] = source
                if !source.openRequests.isEmpty { source.subscribers.emit(.activity(.waiting)) }
            }
        }
    }

    /// Request ids the mirror shows asked and not yet resolved.
    private static func loggedRequests(in mirror: URL?) -> (open: Set<String>, all: Set<String>) {
        guard let mirror, let text = try? String(contentsOf: mirror, encoding: .utf8) else { return ([], []) }
        var open: Set<String> = []
        var all: Set<String> = []
        for line in text.split(separator: "\n") where line.contains("\"prompt.") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = object["id"] as? String
            else { continue }
            all.insert(id)
            if object["type"] as? String == "prompt.asked" { open.insert(id) } else { open.remove(id) }
        }
        return (open, all)
    }

    private func refreshStatuses() async {
        guard let endpoint = server.endpoint else { return }
        let client = OpenCodeClient(http: transport(endpoint))
        var byDirectory: [String: [UUID]] = [:]
        for (id, source) in sources where !source.session.isEmpty {
            byDirectory[workingDirectory(id) ?? "", default: []].append(id)
        }
        for (directory, ids) in byDirectory where !directory.isEmpty {
            guard let statuses = try? await client.statuses(directory: directory) else { continue }
            for id in ids {
                guard let source = sources[id] else { continue }
                // `/session/status` lists only sessions that are NOT idle — an absent entry is
                // idle (probed: `{}` with nothing running).
                let activity: SessionActivity = statuses[source.session] == nil ? .idle : .busy
                if source.openRequests.isEmpty { source.subscribers.emit(.activity(activity)) }
            }
            for id in ids {
                guard let session = sources[id]?.session,
                      let info = try? await client.session(session, directory: directory),
                      !info.title.isEmpty, !info.title.hasPrefix("New session - ")
                else { continue }
                sources[id]?.subscribers.emit(.title(info.title))
            }
        }
    }

    // MARK: - Routing

    func handle(_ batch: OpenCodeEventBatch) {
        for signal in batch.signals { handle(signal, directory: batch.directory) }
    }

    private func conversation(forRoot session: String) -> UUID? {
        let id = OpenCodeIdentity.conversationID(forSession: session)
        return sources[id] == nil ? nil : id
    }

    private func handle(_ signal: OpenCodeSignal, directory: String?) {
        let session = Self.session(of: signal)
        if let id = conversation(forRoot: session) {
            apply(signal, toRoot: id)
            return
        }
        if let root = roots[session], let id = conversation(forRoot: root) {
            apply(signal, toChildOf: id, child: session)
            return
        }
        if case .created(let child, let parent?) = signal {
            // A child of a watched root, or of one of its children.
            let root = conversation(forRoot: parent) != nil ? parent : roots[parent]
            if let root { roots[child] = root }
            return
        }
        // A session we have never seen: a child created before this runtime was watching (a
        // restart mid-turn), or nothing of ours at all. Worth one question to the server only
        // for the signals that would change a tab — a request opening or closing — and those
        // are held in arrival order while it is asked, so a fast `replied` cannot be applied
        // before its `asked`.
        guard case .prompt = signal, let directory else { return }
        if awaitingRoot[session] != nil {
            awaitingRoot[session]?.append((signal, directory))
            return
        }
        awaitingRoot[session] = [(signal, directory)]
        Task { [weak self] in
            guard let self else { return }
            let root = await self.resolveRoot(of: session, directory: directory)
            let held = self.awaitingRoot.removeValue(forKey: session) ?? []
            guard let root else { return }
            self.roots[session] = root
            for (signal, directory) in held { self.handle(signal, directory: directory) }
        }
    }

    private func resolveRoot(of session: String, directory: String) async -> String? {
        guard let endpoint = server.endpoint else { return nil }
        let client = OpenCodeClient(http: transport(endpoint))
        var current = session
        for _ in 0..<8 {
            guard let info = try? await client.session(current, directory: directory),
                  let parent = info.parentID
            else { return nil }
            if conversation(forRoot: parent) != nil { return parent }
            current = parent
        }
        return nil
    }

    private func apply(_ signal: OpenCodeSignal, toRoot id: UUID) {
        guard var source = sources[id] else { return }
        switch signal {
        case .activity(_, let activity):
            if activity == .waiting || !source.openRequests.isEmpty {
                source.subscribers.emit(.activity(.waiting))
            } else {
                source.subscribers.emit(.activity(activity))
            }
        case .turnEnded:
            // A turn that ended took every request it was blocked on with it — an Esc-rejected
            // permission ends the turn, and a server-side abort drops pending requests.
            source.openRequests.removeAll()
            source.busyChildren.removeAll()
            sources[id] = source
            syncSoon(id)
            source.subscribers.emit(.subagentCount(0))
            source.subscribers.emit(.activity(.idle))
            source.subscribers.emit(.turnEnded)
            return
        case .turnAborted:
            source.subscribers.emit(.turnAborted)
        case .apiError(_, let error):
            source.subscribers.emit(.apiError(error))
        case .title(_, let title):
            source.subscribers.emit(.title(title))
        case .created:
            break
        case .messageSettled:
            // New history clears a stale error, the way claude's next record does.
            source.subscribers.emit(.apiError(nil))
            sources[id] = source
            syncSoon(id)
            return
        case .prompt(_, let line):
            record(line, in: &source)
            sources[id] = source
            append(line, to: source.mirror)
            return
        }
        sources[id] = source
    }

    private func apply(_ signal: OpenCodeSignal, toChildOf id: UUID, child: String) {
        guard var source = sources[id] else { return }
        switch signal {
        case .activity(_, .waiting):
            source.subscribers.emit(.activity(.waiting))
        case .activity(_, .busy):
            source.busyChildren.insert(child)
            source.subscribers.emit(.subagentCount(source.busyChildren.count))
        case .activity(_, .idle):
            source.busyChildren.remove(child)
            source.subscribers.emit(.subagentCount(source.busyChildren.count))
        case .created(let grandchild, _):
            roots[grandchild] = source.session
        case .prompt(_, let line):
            record(line, in: &source)
            append(line, to: source.mirror)
        default:
            // A child's own turn ending, failing, or being titled is not the tab's.
            break
        }
        sources[id] = source
    }

    /// Tracks which requests are open, and moves the tab off `waiting` when the last closes.
    private func record(_ line: String, in source: inout Source) {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let requestID = object["id"] as? String
        else { return }
        if object["type"] as? String == "prompt.asked" {
            source.openRequests.insert(requestID)
            source.subscribers.emit(.activity(.waiting))
        } else if source.openRequests.remove(requestID) != nil, source.openRequests.isEmpty {
            source.subscribers.emit(.activity(.busy))
        }
    }

    private static func session(of signal: OpenCodeSignal) -> String {
        switch signal {
        case .activity(let s, _), .turnEnded(let s), .turnAborted(let s), .apiError(let s, _),
             .title(let s, _), .created(let s, _), .messageSettled(let s), .prompt(let s, _):
            return s
        }
    }

    // MARK: - Mirror

    private func append(_ line: String, to mirror: URL?) {
        guard let mirror else { return }
        do {
            try OpenCodeMirror.append(line, to: mirror)
        } catch {
            Self.logger.error("mirror append failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// A sync now, and one more shortly after.
    ///
    /// **The trailing pass is insurance, and it is labelled as such.** What IS measured is that
    /// OpenCode writes rows in more than one step — a user message's row lands before its parts
    /// (see `OpenCodeMirror`, rule 1) — so an event can describe a state another connection
    /// cannot read yet. Whether any event that triggers a sync can arrive ahead of the row it
    /// describes has NOT been caught happening: the live failure first blamed on that turned out
    /// to be OpenCode's bash tool reporting `(no output)`. The pass costs one read of rows that
    /// are already there, and it is what keeps a mirror from staying one message behind until
    /// the next turn if such an ordering ever does occur.
    private func syncSoon(_ id: UUID) {
        sync(id)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 750_000_000)
            self?.sync(id)
        }
    }

    /// Brings one conversation's mirror up to date, off the main actor, one sync at a time per
    /// conversation — a second request while one is running is folded into one more pass.
    private func sync(_ id: UUID) {
        guard var source = sources[id], let mirror = source.mirror, !source.session.isEmpty else { return }
        guard !source.syncing else {
            source.syncAgain = true
            sources[id] = source
            return
        }
        guard let database = server.databaseURL else { return }
        source.syncing = true
        source.syncAgain = false
        sources[id] = source
        let session = source.session
        Task { [weak self] in
            let appended = await Task.detached {
                (try? OpenCodeMirror.sync(sessionID: session, database: database, mirror: mirror)) ?? []
            }.value
            guard let self else { return }
            self.index(appended, of: id, mirror: mirror)
            self.scanForSignals(appended, of: id)
            guard var current = self.sources[id] else { return }
            current.syncing = false
            let again = current.syncAgain
            self.sources[id] = current
            if again { self.sync(id) }
        }
    }

    /// Guard blocks and `BLOCKED:` lines in freshly mirrored messages (Flight Control's contested
    /// detection), through the one channel every agent's report takes — as claude's transcript
    /// tail, codex's rollout and grok's updates already do.
    private func scanForSignals(_ lines: [String], of id: UUID) {
        let signals = lines.flatMap { line -> [AgentOutputSignal] in
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return [] }
            return AgentOutputScan.signals(line: line, record: record)
        }
        guard !signals.isEmpty else { return }
        sources[id]?.subscribers.emit(.outputSignals(signals))
    }

    /// Streams freshly mirrored messages into ⌘K, as `CodexRuntime` does for its rollouts.
    private func index(_ lines: [String], of id: UUID, mirror: URL) {
        guard !lines.isEmpty, let index = searchIndex(), let path = projectPath(id),
              let workingDirectory = workingDirectory(id)
        else { return }
        let conversation = id.uuidString.lowercased()
        let messages = lines.flatMap {
            OpenCodeSearchCorpus.indexedMessages(inLine: $0, conversationID: conversation, at: 0)
        }
        guard !messages.isEmpty else { return }
        let ref = TranscriptRef(
            url: mirror, projectPath: path, accountHome: AgentID.opencode.builtInHome,
            workingDirectory: workingDirectory, conversationID: conversation, agent: .opencode,
            provenance: nil, indexedName: nil, modified: Date()
        )
        try? index.ingest(messages, for: ref, offset: nil)
    }

    /// Test seam: runs a mirror sync for every source and waits for none of it.
    func syncAllForTesting() { for id in sources.keys { sync(id) } }

    /// Test seam: the request reconciliation a (re)connect runs, awaited.
    func reconcileRequestsForTesting() async { await reconcileRequests() }
}
