import Foundation
import IntakeKit

/// grok's runtime: one `GrokSessionWatcher` per attached conversation, shared by every tab on
/// it — `ClaudeRuntime`'s shape, because grok's state is per-session files, not a per-account
/// server.
@MainActor
final class GrokRuntime: AgentRuntime {
    private struct Source {
        let subscribers: SubscriberList
        let watcher: GrokSessionWatcher?
    }

    private var sources: [UUID: Source] = [:]
    private let clock: WatchClock?
    /// Where a session's text goes for ⌘K, and which project and directory it is filed under:
    /// `ClaudeRuntime`'s three closures, keyed by conversation and re-read on every batch for the
    /// same reasons (the index is wired in late; a tab can move project or into a worktree).
    private let searchIndex: () -> SearchIndex?
    private let projectPath: (UUID) -> String?
    private let workingDirectory: (UUID) -> String?

    init(clock: WatchClock? = nil,
         searchIndex: @escaping () -> SearchIndex? = { nil },
         projectPath: @escaping (UUID) -> String? = { _ in nil },
         workingDirectory: @escaping (UUID) -> String? = { _ in nil }) {
        self.clock = clock
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
        let watcher = binding.transcriptURL.map {
            GrokSessionWatcher(transcript: $0, conversationID: id, clock: clock,
                               onEvent: { subscribers.emit($0) },
                               // Passed unconditionally, for `ClaudeRuntime.attach`'s reason: a
                               // session attached before search is wired would otherwise never
                               // become searchable. The cost is nil here — `GrokScan` already
                               // decodes every `updates.jsonl` line for question signals.
                               onMessages: { [weak self] url, messages in
                                   self?.index(messages, from: url, conversationID: id)
                               })
        }
        sources[id] = Source(subscribers: subscribers, watcher: watcher)
        watcher?.start()
        return token
    }

    func detach(_ token: AttachmentToken) {
        guard let source = sources[token.conversationID] else { return }
        source.subscribers.remove(token)
        guard source.subscribers.isEmpty else { return }
        source.watcher?.stop()
        sources[token.conversationID] = nil
    }

    private func index(_ messages: [IndexedMessage], from url: URL, conversationID id: UUID) {
        guard let index = searchIndex(), let path = projectPath(id),
              let workingDirectory = workingDirectory(id)
        else { return }
        let ref = TranscriptRef(
            url: url, projectPath: path, accountHome: AgentID.grok.builtInHome,
            workingDirectory: workingDirectory, conversationID: id.uuidString.lowercased(),
            // nil: a tab is an interactive TUI session, never the headless kind the backfill
            // marks automated.
            agent: .grok, provenance: nil, indexedName: nil, modified: Date()
        )
        // `offset: nil` — see `SearchIndex.ingest`. This watcher starts a pre-existing file at
        // its end, so its position is never the backfill's resume point.
        try? index.ingest(messages, for: ref, offset: nil)
    }

    /// Test seam mirroring `ClaudeRuntime.drainForTesting()`.
    func drainForTesting() {
        for source in sources.values { source.watcher?.drain() }
    }
}

/// Tails one grok session's `events.jsonl` and `updates.jsonl`, and watches its
/// `summary.json`, folding them into `AgentEvent`s. See `GrokStatusFold` for why these files
/// and not a hook.
///
/// Threading and scheduling mirror `CodexRolloutWatcher`: the reads run off the main actor on
/// the shared `WatchClock`, and only the fold hops back.
@MainActor
final class GrokSessionWatcher {
    private var directory: URL
    private let sessionsRoot: URL
    private let conversationID: UUID
    private let onEvent: (AgentEvent) -> Void
    /// The prompts and replies this pass read, with the file they came from (the directory can
    /// move from the computed guess to where grok really wrote it; see `GrokScan.read`).
    private let onMessages: (URL, [IndexedMessage]) -> Void
    private weak var clock: WatchClock?

    private var events = TailCursor()
    private var updates = TailCursor()
    private var summaryStamp: Date?
    private var registryStamp: Date?
    private var children: [String: GrokScan.Child] = [:]
    private var finishedChildren: Set<String> = []
    /// Whether grok's process registry last listed this session. nil until first read.
    private var registered: Bool?
    private var fold = GrokStatusFold()
    private var reported: SessionActivity?
    private var announcedLive = false
    private var lastManualTitle: String?
    private var isPolling = false

    init(transcript: URL, conversationID: UUID, clock: WatchClock? = nil,
         onEvent: @escaping (AgentEvent) -> Void,
         onMessages: @escaping (URL, [IndexedMessage]) -> Void = { _, _ in }) {
        self.onMessages = onMessages
        directory = transcript.deletingLastPathComponent()
        sessionsRoot = GrokSessionFiles.sessionsRoot(ofTranscript: transcript)
        self.conversationID = conversationID
        self.clock = clock
        self.onEvent = onEvent
    }

    func start() { clock?.add(self) { [weak self] in self?.poll() } }
    func stop() { clock?.remove(self) }

    private func poll() {
        guard !isPolling else { return }
        isPolling = true
        let input = scanInput()
        Task { [weak self] in
            let scan = await Task.detached(priority: .utility) { GrokScan.read(input) }.value
            guard let self else { return }
            self.apply(scan)
            self.isPolling = false
        }
    }

    /// Synchronous pass, so tests need no clock.
    func drain() { apply(GrokScan.read(scanInput())) }

    private func scanInput() -> GrokScan.Input {
        GrokScan.Input(directory: directory, sessionsRoot: sessionsRoot, conversationID: conversationID,
                       events: events, updates: updates, summaryStamp: summaryStamp,
                       registryStamp: registryStamp, children: children,
                       finishedChildren: finishedChildren)
    }

    private func apply(_ scan: GrokScan) {
        directory = scan.directory
        events = scan.events
        updates = scan.updates
        summaryStamp = scan.summaryStamp
        registryStamp = scan.registryStamp
        children = scan.children
        finishedChildren = scan.finishedChildren

        // grok's process registry (`active_sessions.json`) lists a session from launch to exit
        // (probed, SIGHUP included), so it is the liveness signal for a session that has not
        // written a turn yet — a fresh `grok -s` writes NO events line until its first prompt
        // (verified live), and a tab with no status is one the phone will not type into.
        if let listed = scan.registered, listed != registered {
            let wasListed = registered == true
            registered = listed
            if listed, !announcedLive {
                announcedLive = true
                onEvent(.lifecycle(.live))
            } else if !listed, wasListed {
                // The TUI exited and the tab is back at its shell: nothing to type into.
                announcedLive = false
                onEvent(.lifecycle(.absent))
            }
        }
        // Any line at all is grok up and writing: the analogue of codex's first rollout line
        // (`CodexRolloutWatcher.apply`), and the same gate — a file that predates the watcher
        // is read from its end, so a restored session stays `.unknown` until grok writes.
        if scan.sawLines && !announcedLive {
            announcedLive = true
            onEvent(.lifecycle(.live))
        }
        for step in scan.steps {
            var discrete: [AgentEvent] = []
            switch step {
            case .event(let type, let outcome): discrete = fold.apply(eventType: type, outcome: outcome)
            case .question(let signal): fold.apply(signal)
            case .signals(let signals): discrete = [.outputSignals(signals)]
            case .childPermissions(let count): fold.apply(childPermissions: count)
            }
            report()
            discrete.forEach(onEvent)
        }
        if announcedLive { report() }
        if !scan.messages.isEmpty {
            onMessages(scan.directory.appendingPathComponent(GrokSessionFiles.transcriptName), scan.messages)
        }
        if let summary = scan.summary, summary.isManual, summary.title != lastManualTitle {
            lastManualTitle = summary.title
            onEvent(.title(summary.title))
        }
    }

    /// Activity is reported on change only, idle included: the first line after attach
    /// settles a status for a tab that had none.
    private func report() {
        let now = fold.activity
        guard now != reported else { return }
        reported = now
        onEvent(.activity(now))
    }
}

/// Where one tailed file has been read to. `TailReader`'s two fields, as a value.
struct TailCursor: Sendable, Equatable {
    var offset: UInt64 = 0
    var hasChosenStart = false
}

/// One look at a grok session's files. Pure and `Sendable`, for `CodexScan`'s reason.
struct GrokScan: Sendable {
    struct Input: Sendable {
        let directory: URL
        let sessionsRoot: URL
        let conversationID: UUID
        let events: TailCursor
        let updates: TailCursor
        let summaryStamp: Date?
        var registryStamp: Date? = nil
        var children: [String: Child] = [:]
        var finishedChildren: Set<String> = []
    }

    /// One running subagent, as the last poll left it. Its `events.jsonl` is re-read only when
    /// its modification date moves.
    struct Child: Sendable, Equatable {
        var directory: URL?
        var stamp: Date?
        var holdsPermission = false
    }

    /// One state-bearing line, in file order within each file — events first, then updates.
    /// The two files are written by one process within milliseconds of each other; nothing
    /// here depends on their relative order beyond one poll.
    enum Step: Sendable, Equatable {
        case event(type: String, outcome: String?)
        case question(GrokStatusFold.QuestionSignal)
        case signals([AgentOutputSignal])
        /// How many running subagents hold a permission card (`GrokSubagents`). Emitted on every
        /// poll of a session that has a `subagents/` directory, last, so it reflects this poll.
        case childPermissions(Int)
    }

    var directory: URL
    var events: TailCursor
    var updates: TailCursor
    var summaryStamp: Date?
    var summary: GrokSessionFiles.Summary?
    var registryStamp: Date?
    /// Whether `active_sessions.json` lists this session; nil when the file did not change.
    var registered: Bool?
    var children: [String: Child] = [:]
    var finishedChildren: Set<String> = []
    var steps: [Step] = []
    var sawLines = false
    /// `updates.jsonl`'s new prompts and replies, by `GrokSearchCorpus`'s rule — so a live row is
    /// the row the backfill would write for the same line.
    var messages: [IndexedMessage] = []

    static func read(_ input: Input) -> GrokScan {
        var directory = input.directory
        let eventsURL = { directory.appendingPathComponent(GrokSessionFiles.eventsName) }
        // The computed directory is a guess made before grok ran (see `GrokSessionFiles`).
        // Until anything has been read, a session found elsewhere under `sessions/` wins.
        if !input.events.hasChosenStart || input.events.offset == 0,
           !FileManager.default.fileExists(atPath: eventsURL().path),
           let found = GrokSessionFiles.existingSessionDirectory(
               root: input.sessionsRoot, conversationID: input.conversationID) {
            directory = found
        }

        var scan = GrokScan(directory: directory, events: input.events, updates: input.updates,
                            summaryStamp: input.summaryStamp, registryStamp: input.registryStamp)
        scan.finishedChildren = input.finishedChildren

        let registry = GrokSessionFiles.registryURL(sessionsRoot: input.sessionsRoot)
        let registryStamp = (try? registry.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        if registryStamp != input.registryStamp {
            scan.registryStamp = registryStamp
            scan.registered = GrokSessionFiles.isRegistered(
                input.conversationID, registryData: (try? Data(contentsOf: registry)) ?? Data("[]".utf8))
        }

        let eventTail = TailReader.read(url: eventsURL(), offset: input.events.offset,
                                        hasChosenStart: input.events.hasChosenStart)
        scan.events = TailCursor(offset: eventTail.offset, hasChosenStart: eventTail.hasChosenStart)
        for line in eventTail.lines {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = record["type"] as? String else { continue }
            scan.steps.append(.event(type: type, outcome: record["outcome"] as? String))
        }

        let updateTail = TailReader.read(url: directory.appendingPathComponent(GrokSessionFiles.transcriptName),
                                         offset: input.updates.offset, hasChosenStart: input.updates.hasChosenStart)
        scan.updates = TailCursor(offset: updateTail.offset, hasChosenStart: updateTail.hasChosenStart)
        let corpus = GrokSearchCorpus()
        let name = input.conversationID.uuidString.lowercased()
        for (line, offset) in zip(updateTail.lines, updateTail.lineOffsets) {
            scan.messages += corpus.indexedMessages(inLine: line, conversationID: name, at: Int(offset))
        }
        for line in updateTail.lines {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            if let signal = GrokStatusFold.questionSignal(inUpdateRecord: record) {
                scan.steps.append(.question(signal))
            }
            let signals = AgentOutputScan.signals(line: line, record: record)
            if !signals.isEmpty { scan.steps.append(.signals(signals)) }
        }
        scan.sawLines = !eventTail.lines.isEmpty || !updateTail.lines.isEmpty

        // Subagents' cards, which only their own files mark (see `GrokSubagents`). One directory
        // listing per poll, and only for a session that has ever spawned one.
        let subagents = directory.appendingPathComponent(GrokSubagents.directoryName, isDirectory: true)
        if FileManager.default.fileExists(atPath: subagents.path) {
            let listing = GrokSubagents.children(ofSessionDirectory: directory, skipping: input.finishedChildren)
            scan.finishedChildren.formUnion(listing.finished)
            for id in listing.running {
                var child = input.children[id] ?? Child()
                if child.directory == nil {
                    child.directory = GrokSubagents.childDirectory(id, sessionsRoot: input.sessionsRoot)
                }
                if let dir = child.directory {
                    let events = dir.appendingPathComponent(GrokSessionFiles.eventsName)
                    let stamp = (try? events.resourceValues(forKeys: [.contentModificationDateKey]))?
                        .contentModificationDate
                    if stamp != child.stamp {
                        child.stamp = stamp
                        child.holdsPermission = (try? Data(contentsOf: events))
                            .map(GrokSubagents.holdsPermission(eventsData:)) ?? false
                    }
                }
                scan.children[id] = child
            }
            scan.steps.append(.childPermissions(scan.children.values.filter(\.holdsPermission).count))
        }

        let summaryURL = directory.appendingPathComponent(GrokSessionFiles.summaryName)
        let stamp = (try? summaryURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
        if let stamp, stamp != input.summaryStamp {
            scan.summaryStamp = stamp
            scan.summary = (try? Data(contentsOf: summaryURL)).flatMap(GrokSessionFiles.summary(fromData:))
        }
        return scan
    }
}
