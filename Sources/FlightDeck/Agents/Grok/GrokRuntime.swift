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

    init(clock: WatchClock? = nil) {
        self.clock = clock
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
                               onEvent: { subscribers.emit($0) })
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
    private weak var clock: WatchClock?

    private var events = TailCursor()
    private var updates = TailCursor()
    private var summaryStamp: Date?
    private var registryStamp: Date?
    /// Whether grok's process registry last listed this session. nil until first read.
    private var registered: Bool?
    private var fold = GrokStatusFold()
    private var reported: SessionActivity?
    private var announcedLive = false
    private var lastManualTitle: String?
    private var isPolling = false

    init(transcript: URL, conversationID: UUID, clock: WatchClock? = nil,
         onEvent: @escaping (AgentEvent) -> Void) {
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
                       registryStamp: registryStamp)
    }

    private func apply(_ scan: GrokScan) {
        directory = scan.directory
        events = scan.events
        updates = scan.updates
        summaryStamp = scan.summaryStamp
        registryStamp = scan.registryStamp

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
            }
            report()
            discrete.forEach(onEvent)
        }
        if announcedLive { report() }
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
    }

    /// One state-bearing line, in file order within each file — events first, then updates.
    /// The two files are written by one process within milliseconds of each other; nothing
    /// here depends on their relative order beyond one poll.
    enum Step: Sendable, Equatable {
        case event(type: String, outcome: String?)
        case question(GrokStatusFold.QuestionSignal)
        case signals([AgentOutputSignal])
    }

    var directory: URL
    var events: TailCursor
    var updates: TailCursor
    var summaryStamp: Date?
    var summary: GrokSessionFiles.Summary?
    var registryStamp: Date?
    /// Whether `active_sessions.json` lists this session; nil when the file did not change.
    var registered: Bool?
    var steps: [Step] = []
    var sawLines = false

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
