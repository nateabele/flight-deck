import Combine
import Foundation
import IntakeKit
import os

/// The pill a thread wears on its card and in the index. Resolved threads wear none: their group
/// says it.
enum ThreadPill: Equatable {
    case answering, stale, needsYou

    var text: String {
        switch self {
        case .answering: "answering"
        case .stale: "stale"
        case .needsYou: "needs you"
        }
    }
}

/// One thread as the index lists it.
struct ThreadIndexRow: Equatable, Identifiable {
    let id: ThreadID
    let title: String
    /// "§2 Session lifetime", nil for a thread on the whole plan.
    let section: String?
    /// The second line: the section, then what is waiting ("1 diff", "stale", "asked you 1 question").
    let detail: String
    let pill: ThreadPill?
    let quote: String?
}

/// The index's three groups. `open` is in plan order; the others in the order threads were made.
struct ThreadIndex: Equatable {
    var open: [ThreadIndexRow] = []
    var needsYou: [ThreadIndexRow] = []
    var resolved: [ThreadIndexRow] = []

    /// In display order: what ⌘[ and ⌘] walk.
    var all: [ThreadIndexRow] { open + needsYou + resolved }
}

/// What the rail's Ask card shows for one thread.
struct AskCardModel: Equatable, Identifiable {
    let id: ThreadID
    let title: String
    let pill: ThreadPill?
    /// What the agent is doing now (R2); nil when no turn is running.
    let activity: String?
    /// One line of the latest reply, citations as their labels.
    let excerpt: String?
    let pendingDiffs: Int
    let notes: Int
    let messages: Int
}

/// The conversation header.
struct ThreadHeaderModel: Equatable {
    let title: String
    /// "claude · opus · high": the agent that answers. Read-only access is the runner's (R1).
    let agent: String
    /// "on Refine 2": the version the thread follows.
    let follows: String
    let quote: String?
    let section: String?
    let status: ThreadStatus
    /// The agent answers from the files alone (Grok, OpenCode): said in the header.
    let readsFilesOnly: Bool
}

/// What the store held at one poll. Equatable so a poll that finds nothing new publishes nothing.
/// A thread this panel just opened that ThreadRunner has not folded yet: what the conversation
/// shows meanwhile (the anchor, the words sent, "answering…"), so a send never lands on
/// "No thread open".
struct PendingThread: Equatable {
    let id: ThreadID
    let title: String
    let anchor: ThreadAnchor
    let you: String
}

/// What the conversation column shows.
enum ThreadConversationState: Equatable {
    case thread(ThreadID)
    case pending(PendingThread)
    case newThread(ThreadAnchor)
    case none
}

struct ThreadSnapshot: Equatable {
    var threads: [ThreadRecord] = []
    var turns: [ThreadID: [ThreadTurn]] = [:]
    var diffs: [ThreadID: [ThreadDiff]] = [:]
    var activity: [ThreadID: String] = [:]
    /// The questions each thread asked that no later turn answered, worked out once per poll: the
    /// index, the cards and the pills all ask, several times a body.
    var questions: [ThreadID: [StructuredQuestion]] = [:]
}

/// The agent a new thread asks until the human picks another.
struct ThreadDefaults: Equatable {
    var agent: AgentID = .claude
    var model = "opus"
    var effort = "high"
}

/// The thread panel and the Ask cards, decided without a view: what the index groups are, what a
/// card says, what the open thread is. It reads a `ThreadStoreReading` and sends through
/// `Actions`, so a test drives it with a fake store and recording closures.
///
/// **Why it polls.** `IntakeThreadBinding.reader` is bound once and nothing announces a change, so
/// while the panel or the rail is on screen the model re-reads the store on the app's one
/// `WatchClock`. `refresh()` publishes only when the snapshot differs: a quiet store must not
/// redraw the rail, whose cards are laid out against the editor's scroll position.
@MainActor
final class ThreadPanelModel: ObservableObject {
    /// Every thread operation the UI makes. The defaults refuse, so a model built without a service
    /// (a render, a test of something else) cannot send by accident.
    struct Actions {
        var open: @MainActor (ThreadAnchor, String, String, ThreadDefaults) -> Result<ThreadID, ThreadRefusal>
        var send: @MainActor (ThreadID, String) -> ThreadRefusal?
        var answer: @MainActor (ThreadID, [StructuredAnswer]) -> ThreadRefusal?
        var setAutoAccept: @MainActor (ThreadID, Bool) -> ThreadRefusal?
        var resolve: @MainActor (ThreadID) -> ThreadRefusal?
        var reopen: @MainActor (ThreadID) -> ThreadRefusal?
        var decide: @MainActor (ThreadID, UUID, Bool, String?) -> ThreadRefusal?
        var setAgent: @MainActor (ThreadID, ThreadAgentChoice) -> ThreadRefusal?
        var repropose: @MainActor (ThreadID, UUID) -> ThreadRefusal?

        init(open: @escaping @MainActor (ThreadAnchor, String, String, ThreadDefaults) -> Result<ThreadID, ThreadRefusal> = { _, _, _, _ in .failure(ThreadPanelModel.unavailable) },
             send: @escaping @MainActor (ThreadID, String) -> ThreadRefusal? = { _, _ in ThreadPanelModel.unavailable },
             answer: @escaping @MainActor (ThreadID, [StructuredAnswer]) -> ThreadRefusal? = { _, _ in ThreadPanelModel.unavailable },
             setAutoAccept: @escaping @MainActor (ThreadID, Bool) -> ThreadRefusal? = { _, _ in ThreadPanelModel.unavailable },
             resolve: @escaping @MainActor (ThreadID) -> ThreadRefusal? = { _ in ThreadPanelModel.unavailable },
             reopen: @escaping @MainActor (ThreadID) -> ThreadRefusal? = { _ in ThreadPanelModel.unavailable },
             decide: @escaping @MainActor (ThreadID, UUID, Bool, String?) -> ThreadRefusal? = { _, _, _, _ in ThreadPanelModel.unavailable },
             setAgent: @escaping @MainActor (ThreadID, ThreadAgentChoice) -> ThreadRefusal? = { _, _ in ThreadPanelModel.unavailable },
             repropose: @escaping @MainActor (ThreadID, UUID) -> ThreadRefusal? = { _, _ in ThreadPanelModel.unavailable }) {
            self.open = open
            self.send = send
            self.answer = answer
            self.setAutoAccept = setAutoAccept
            self.resolve = resolve
            self.reopen = reopen
            self.decide = decide
            self.setAgent = setAgent
            self.repropose = repropose
        }

        /// Everything through the intake's binding (`IntakeService+Threads`).
        @MainActor init(_ binding: IntakeThreadBinding) {
            self.init(
                open: { anchor, title, text, d in
                    binding.open(anchor: anchor, title: title, text: text, agent: d.agent, model: d.model, effort: d.effort)
                },
                send: { binding.send($0, text: $1) },
                answer: { binding.answer($0, answers: $1) },
                setAutoAccept: { binding.setAutoAccept($0, $1) },
                resolve: { binding.resolve($0) },
                reopen: { binding.reopen($0) },
                decide: { binding.decideDiff($0, diff: $1, accept: $2, editedMarkdown: $3) },
                setAgent: { binding.setAgent($0, agent: $1.agent, model: $1.model, effort: $1.effort) },
                repropose: { binding.repropose($0, diff: $1) })
        }
    }

    static var unavailable: ThreadRefusal { IntakeService.unavailable }
    static let unavailableNotice = "Threads aren't available yet."
    /// The inspector's own range (`IntakeDetailView`): the panel can't be wider than its column.
    static let widthRange: ClosedRange<CGFloat> = 300...640

    // MARK: Session memory

    /// What the human left open, per intake, for the session: kept past this model and past the
    /// detail view being made again, like `PlanNotesController.otherVersionsExpanded`.
    private struct Memory {
        var open: ThreadID?
        var showing = false
        var width: CGFloat?
    }
    private static var memory: [UUID: Memory] = [:]

    /// For tests: the session starts afresh.
    static func forgetSession() { memory = [:] }

    // MARK: State

    let intakeID: UUID
    private let reader: any ThreadStoreReading
    private let actions: Actions
    private let headings: () -> [String]
    /// The name the rail gives a checkpoint ("Refine 2"); bound by the notes controller.
    var versionLabel: (Int) -> String? = { _ in nil }

    @Published private(set) var snapshot = ThreadSnapshot()
    @Published private(set) var index = ThreadIndex()
    @Published var filter = "" { didSet { if filter != oldValue { rebuildIndex() } } }
    @Published private(set) var selected: ThreadID? { didSet { Self.memory[intakeID, default: Memory()].open = selected } }
    @Published private(set) var isOpen = false { didSet { Self.memory[intakeID, default: Memory()].showing = isOpen } }
    /// The width the panel was last seen at: the inspector's, which the human drags.
    var width: CGFloat? {
        didSet {
            if let w = width, !Self.widthRange.contains(w) { width = min(max(w, Self.widthRange.lowerBound), Self.widthRange.upperBound); return }
            Self.memory[intakeID, default: Memory()].width = width
        }
    }
    @Published private(set) var newThreadAnchor: ThreadAnchor?
    @Published var composer = ""
    /// Threads opened here that the reader does not have yet (`PendingThread`).
    @Published private(set) var pending: [ThreadID: PendingThread] = [:]
    /// The started threads `pendingStalled` holds for, as of the last poll.
    @Published private(set) var stalledStarts: Set<ThreadID> = []

    func pendingThread(_ id: ThreadID) -> PendingThread? { pending[id] }

    /// M1: no runner has folded it in `pendingTimeout` (it died, or the intake left shaping).
    func pendingStalled(_ started: PendingThread) -> Bool {
        guard let since = pendingSince[started.id] else { return false }
        return now().timeIntervalSince(since) > Self.pendingTimeout
    }

    /// Retry on a stalled start: the words go back into a new thread's composer to send again.
    func retryPending(_ id: ThreadID) {
        guard let started = pending.removeValue(forKey: id) else { return }
        pendingSince[id] = nil
        stalledStarts.remove(id)
        beginThread(on: started.anchor)
        composer = started.you
    }

    /// M2: what "You answered" names: each pick's label in the order chosen, then the typed answer.
    func answered(_ thread: ThreadID, turn: ThreadTurn) -> String? {
        guard let answers = turn.answers, !answers.isEmpty else { return nil }
        var questions: [String: StructuredQuestion] = [:]
        for earlier in turns(thread) where earlier.seq < turn.seq {
            for case .askQuestion(let q) in earlier.actions { questions[q.id] = q }
        }
        var parts: [String] = []
        for answer in answers {
            let labels = answer.selected.map { id in questions[answer.questionID]?.options.first { $0.id == id }?.label ?? id }
            parts += labels
            if let other = answer.other?.trimmingCharacters(in: .whitespacesAndNewlines), !other.isEmpty {
                parts.append(parts.isEmpty ? other : "and \(other)")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// The conversation column: the open thread once the reader has it, the one just started
    /// until then, a new thread being composed, or nothing.
    var conversation: ThreadConversationState {
        if let anchor = newThreadAnchor { return .newThread(anchor) }
        guard let selected else { return .none }
        if record(selected) != nil { return .thread(selected) }
        if let started = pending[selected] { return .pending(started) }
        return .none
    }
    /// A refusal or failure to show under the composer; cleared by the next thing that works.
    @Published private(set) var notice: String?
    /// The answers being picked for the open question, by question id.
    @Published var answerDrafts: [String: StructuredAnswer] = [:]
    @Published private var autoAcceptOverrides: [ThreadID: (value: Bool, at: Date)] = [:]
    private var drafts: [ThreadID?: String] = [:]

    private var clock: WatchClock?
    /// The clock the model polls on by itself while the plan has pending diffs (B-I1); the views'
    /// `start(on:)` may name another.
    private let pollClock: WatchClock
    /// Registered on a clock because the plan has pending diffs, whether or not a view watches.
    private var watchesForDiffs = false
    private let now: () -> Date
    /// When each started thread was sent, for `pendingStalled`.
    private var pendingSince: [ThreadID: Date] = [:]
    /// A started thread no runner has folded after this long says so, with Retry (M1).
    static let pendingTimeout: TimeInterval = 60

    /// The app's one poll clock is `SessionStore.watchClock`, which a view cannot reach; this one
    /// only runs while a rail or panel is on screen, and sleeps otherwise.
    static let sharedClock = WatchClock()

    /// What a new thread asks, and the agents the header menu offers: the intake's own
    /// (`IntakeThreadBinding.defaults`, `.menu`), read when needed so a settings change shows.
    private let defaultsProvider: @MainActor () -> ThreadDefaults
    private let modelMenu: @MainActor () -> [ThreadAgentChoice]

    init(intakeID: UUID, reader: any ThreadStoreReading, actions: Actions = Actions(),
         headings: @escaping () -> [String] = { [] },
         defaultsProvider: @escaping @MainActor () -> ThreadDefaults = { ThreadDefaults() },
         modelMenu: @escaping @MainActor () -> [ThreadAgentChoice] = { [] },
         pollClock: WatchClock = ThreadPanelModel.sharedClock, now: @escaping () -> Date = Date.init) {
        self.pollClock = pollClock
        self.now = now
        self.defaultsProvider = defaultsProvider
        self.modelMenu = modelMenu
        self.intakeID = intakeID
        self.reader = reader
        self.actions = actions
        self.headings = headings
        let remembered = Self.memory[intakeID]
        selected = remembered?.open
        isOpen = remembered?.showing ?? false
        width = remembered?.width
    }

    var isComposingNewThread: Bool { newThreadAnchor != nil }

    /// Threads not yet resolved: the "(n)" in the rail's header.
    var liveCount: Int { snapshot.threads.filter { $0.status != .resolved }.count }

    // MARK: Polling

    /// Reads the store now and on every beat of `clock` until the matching `stop()`. Counted: the
    /// rail and the panel each start it when they appear, and swapping one for the other must not
    /// stop the polling while either is still on screen.
    func start(on given: WatchClock? = nil) {
        let clock = given ?? pollClock
        watchers += 1
        if let current = self.clock, current !== clock { current.remove(self) }
        self.clock = clock
        clock.add(self) { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        refresh()
    }

    func stop() {
        watchers = max(watchers - 1, 0)
        guard watchers == 0 else { return }
        clock?.remove(self)
        clock = nil
        syncDiffWatch()
    }

    /// B-I1: the plan draws the proposals, and needs them current even with the rail and panel off
    /// screen (the inspector closed, or on Rounds). So while any diff is pending the model stays on
    /// a clock by itself, and lets go once none is, unless a view still watches.
    private func syncDiffWatch() {
        let wants = !pendingDiffsInPlan.isEmpty
        if wants, clock == nil {
            pollClock.add(self) { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
            clock = pollClock
            watchesForDiffs = true
        } else if !wants, watchesForDiffs, watchers == 0 {
            clock?.remove(self)
            clock = nil
            watchesForDiffs = false
        } else if watchers > 0 {
            watchesForDiffs = false
        }
    }

    /// How many views have asked for the polling and not yet let go of it.
    private var watchers = 0

    func refresh() {
        let records = reader.threads()
        var next = ThreadSnapshot(threads: records)
        for record in records {
            next.turns[record.id] = reader.turns(record.id)
            next.diffs[record.id] = reader.diffs(record.id)
            if let live = reader.activity(record.id) { next.activity[record.id] = live }
        }
        for record in records { next.questions[record.id] = Self.unansweredQuestions(next.turns[record.id] ?? []) }
        if next != snapshot { snapshot = next }
        // A started thread the runner has folded is shown as itself from now on.
        let folded = pending.keys.filter { id in records.contains { $0.id == id } }
        if !folded.isEmpty { for id in folded { pending[id] = nil; pendingSince[id] = nil } }
        // Published only when it changes, so the view turns "answering…" into Retry at the minute
        // even though nothing on disk moved.
        let stalled = Set(pending.values.filter(pendingStalled).map(\.id))
        if stalled != stalledStarts { stalledStarts = stalled }
        settleOverrides()
        syncDiffWatch()
        rebuildIndex()
    }

    /// The runner has caught up with a switch, or it is clear it won't: stop holding it.
    private func settleOverrides() {
        let now = Date()
        let kept = autoAcceptOverrides.filter { id, held in
            guard now.timeIntervalSince(held.at) < 10,
                  let record = snapshot.threads.first(where: { $0.id == id }) else { return false }
            return record.autoAccept != held.value
        }
        if kept.count != autoAcceptOverrides.count { autoAcceptOverrides = kept }
    }

    // MARK: Reading

    func turns(_ id: ThreadID) -> [ThreadTurn] { snapshot.turns[id] ?? [] }
    func diffs(_ id: ThreadID) -> [ThreadDiff] { snapshot.diffs[id] ?? [] }
    func record(_ id: ThreadID) -> ThreadRecord? { snapshot.threads.first { $0.id == id } }

    /// The questions the agent asked that no later turn answered (worked out once per poll).
    func openQuestions(_ id: ThreadID) -> [StructuredQuestion] { snapshot.questions[id] ?? [] }

    private static func unansweredQuestions(_ all: [ThreadTurn]) -> [StructuredQuestion] {
        guard let at = all.lastIndex(where: { turn in turn.actions.contains { if case .askQuestion = $0 { true } else { false } } }),
              !all[(at + 1)...].contains(where: { $0.answers != nil }) else { return [] }
        return all[at].actions.compactMap { if case .askQuestion(let q) = $0 { q } else { nil } }
    }

    func pendingDiffs(_ id: ThreadID) -> [ThreadDiff] { diffs(id).filter { $0.state == .pending } }

    /// The diffs the plan should draw: pending ones from every thread still open.
    var pendingDiffsInPlan: [ThreadDiff] {
        snapshot.threads.filter { $0.status != .resolved }.flatMap { pendingDiffs($0.id) }
    }

    private func needsYou(_ record: ThreadRecord) -> Bool {
        if record.status == .needsYou { return true }
        guard record.status != .stale, record.status != .resolved else { return false }
        return !pendingDiffs(record.id).isEmpty || !openQuestions(record.id).isEmpty
    }

    private func pill(_ record: ThreadRecord) -> ThreadPill? {
        switch record.status {
        case .answering: .answering
        case .stale: .stale
        case .resolved: nil
        case .open, .needsYou: needsYou(record) ? .needsYou : nil
        }
    }

    func card(for id: ThreadID) -> AskCardModel? {
        guard let record = record(id) else { return nil }
        let turns = turns(id)
        let notes = turns.reduce(0) { $0 + $1.actions.filter { if case .addNote = $0 { true } else { false } }.count }
        let messages = turns.reduce(0) { $0 + ($1.you == nil ? 0 : 1) + ($1.reply == nil ? 0 : 1) }
        let reply = turns.last { $0.reply != nil }?.reply
        return AskCardModel(id: id, title: record.title, pill: pill(record), activity: snapshot.activity[id],
                            excerpt: reply.map(ThreadCitation.plain), pendingDiffs: pendingDiffs(id).count,
                            notes: notes, messages: messages)
    }

    func header(for id: ThreadID) -> ThreadHeaderModel? {
        guard let record = record(id) else { return nil }
        let follows = versionLabel(record.followsCheckpoint) ?? "checkpoint \(record.followsCheckpoint)"
        let quote = record.anchor.note?.quote
        return ThreadHeaderModel(title: record.title, agent: "\(record.agent.rawValue) · \(record.model) · \(record.effort)",
                                 follows: "on \(follows)", quote: quote?.isEmpty == false ? quote : nil,
                                 section: record.anchor.note?.section.map(Self.sectionLabel), status: record.status,
                                 readsFilesOnly: HeadlessCommand.threadReadsFilesOnly(record.agent))
    }

    /// The agents and models the header menu offers.
    var agentChoices: [ThreadAgentChoice] { modelMenu() }

    /// Moves a thread to another agent or model; the runner answers its next turn with it.
    func setAgent(_ id: ThreadID, _ choice: ThreadAgentChoice) { run(actions.setAgent(id, choice)) }

    func autoAccept(_ id: ThreadID) -> Bool {
        autoAcceptOverrides[id]?.value ?? record(id)?.autoAccept ?? false
    }

    // MARK: Index

    /// "§2 Session lifetime" for "## 2. Session lifetime"; an unnumbered heading is its words.
    static func sectionLabel(_ heading: String) -> String {
        let label = ConvergenceSeries.label(heading)
        let name = HeatmapModel.name(heading)
        return name.isEmpty ? label : "\(label) \(name)"
    }

    private func rebuildIndex() {
        let order = headings().map { $0.trimmingCharacters(in: .whitespaces) }
        let words = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        func position(_ record: ThreadRecord) -> Int {
            guard let section = record.anchor.note?.section?.trimmingCharacters(in: .whitespaces) else { return Int.max }
            return order.firstIndex(of: section) ?? Int.max - 1
        }
        var next = ThreadIndex()
        let ordered = snapshot.threads.enumerated().sorted { a, b in
            (position(a.element), a.offset) < (position(b.element), b.offset)
        }.map(\.element)
        for record in ordered {
            let quote = record.anchor.note?.quote
            if !words.isEmpty, !record.title.lowercased().contains(words), quote?.lowercased().contains(words) != true { continue }
            let row = row(for: record, quote: quote)
            if record.status == .resolved { next.resolved.append(row) }
            else if needsYou(record) { next.needsYou.append(row) }
            else { next.open.append(row) }
        }
        // Waiting and finished threads read oldest first; only Open is by plan position.
        next.needsYou.sort { created($0.id) < created($1.id) }
        next.resolved.sort { created($0.id) < created($1.id) }
        if next != index { index = next }
    }

    private func created(_ id: ThreadID) -> Date { record(id)?.createdAt ?? .distantPast }

    private func row(for record: ThreadRecord, quote: String?) -> ThreadIndexRow {
        let section = record.anchor.note?.section.map(Self.sectionLabel)
        var parts = [section ?? "Whole plan"]
        let diffs = pendingDiffs(record.id).count
        let questions = openQuestions(record.id).count
        if record.status == .stale { parts.append("stale") }
        else if record.status == .resolved { parts.append(diffs == 0 && !turns(record.id).contains { !$0.actions.isEmpty } ? "answered, no change" : "resolved") }
        else if questions > 0 { parts.append("asked you \(questions) question\(questions == 1 ? "" : "s")") }
        else if diffs > 0 { parts.append("\(diffs) diff\(diffs == 1 ? "" : "s")") }
        return ThreadIndexRow(id: record.id, title: record.title, section: section, detail: parts.joined(separator: " · "),
                              pill: pill(record), quote: quote)
    }

    // MARK: Navigation

    /// Opens the panel on `id`.
    func open(_ id: ThreadID) {
        stashDraft()
        newThreadAnchor = nil
        selected = id
        isOpen = true
        notice = nil
        composer = drafts[id] ?? ""
        answerDrafts = [:]
    }

    /// Opens the panel on a new thread about `anchor`, the composer empty and waiting.
    func beginThread(on anchor: ThreadAnchor) {
        stashDraft()
        // A new thread asks nothing yet: picks left from the last thread's question must not ride along.
        answerDrafts = [:]
        newThreadAnchor = anchor
        isOpen = true
        notice = nil
        composer = drafts[ThreadID?.none] ?? ""
    }

    func close() {
        stashDraft()
        isOpen = false
    }

    /// What ⌘[ and ⌘] mean: -1 and +1, only with ⌘ held.
    static func switchStep(key: String, command: Bool) -> Int? {
        guard command else { return nil }
        switch key {
        case "[": return -1
        case "]": return 1
        default: return nil
        }
    }

    /// ⌘[ and ⌘]: the neighbour in display order, wrapping.
    func switchThread(by step: Int) {
        let rows = index.all
        guard !rows.isEmpty else { return }
        let at = rows.firstIndex { $0.id == selected && !isComposingNewThread }
        let next = at.map { ($0 + step + rows.count) % rows.count } ?? (step > 0 ? 0 : rows.count - 1)
        open(rows[next].id)
    }

    private func stashDraft() {
        let key: ThreadID? = isComposingNewThread ? nil : selected
        drafts[key] = composer.isEmpty ? nil : composer
    }

    // MARK: Sending

    /// A short title from a first message: its first line, held to 60 characters.
    static func title(from text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        guard line.count > 60 else { return line }
        return line.prefix(59).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// ⌘↩, or ⌘⇧↩ with `andResolve`. A refusal keeps what was typed.
    func send(andResolve: Bool = false) {
        let text = composer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let thread: ThreadID
        if let anchor = newThreadAnchor {
            switch actions.open(anchor, Self.title(from: text), text, defaultsProvider()) {
            case .failure(let refusal): return fail(refusal)
            case .success(let id):
                thread = id
                pending[id] = PendingThread(id: id, title: Self.title(from: text), anchor: anchor, you: text)
                pendingSince[id] = now()
                newThreadAnchor = nil
                drafts[ThreadID?.none] = nil
                selected = id
            }
        } else if let current = selected {
            if let refusal = actions.send(current, text) { return fail(refusal) }
            thread = current
        } else {
            return
        }
        composer = ""
        drafts[thread] = nil
        notice = nil
        if andResolve, let refusal = actions.resolve(thread) { fail(refusal) }
        refresh()
    }

    func resolve(_ id: ThreadID) { run(actions.resolve(id)) }
    func reopen(_ id: ThreadID) { run(actions.reopen(id)) }
    /// ✓ or ✗. `editedMarkdown` is the plan as the human changed the proposal into (Accept edited).
    func decide(_ diff: ThreadDiff, accept: Bool, editedMarkdown: String? = nil) {
        let refusal = actions.decide(diff.thread, diff.id, accept, editedMarkdown)
        // A ✓ or ✗ is the one panel action whose effect lands elsewhere (the plan), so it says
        // in the log that it ran and how it ended: the evidence a "pressed, nothing happened"
        // report needs.
        Self.logger.notice("decide diff=\(diff.id, privacy: .public) accept=\(accept) edited=\(editedMarkdown != nil) refusal=\(refusal?.code ?? "none", privacy: .public)")
        #if DEBUG
        // Under the UI fixture only: a file the UI test's host keeps, so a smoke run shows whether
        // the action ran and how it ended without reading the system log.
        if let root = PlanningUIFixture.active?.root {
            let line = "decide diff=\(diff.id.uuidString) accept=\(accept) refusal=\(refusal?.code ?? "none")\n"
            let url = root.appendingPathComponent("decide-breadcrumbs.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(Data(line.utf8)); try? handle.close()
            } else { try? Data(line.utf8).write(to: url) }
        }
        #endif
        run(refusal)
    }
    private static let logger = Logger(subsystem: "dev.flightdeck.FlightDeck", category: "threads")
    func repropose(_ diff: ThreadDiff) { run(actions.repropose(diff.thread, diff.id)) }

    func setAutoAccept(_ id: ThreadID, _ on: Bool) {
        if let refusal = actions.setAutoAccept(id, on) { return fail(refusal) }
        autoAcceptOverrides[id] = (on, Date())
        notice = nil
    }

    /// The picks for the open question, in the order it was asked.
    func submitAnswers(_ id: ThreadID) {
        let answers = openQuestions(id).compactMap { answerDrafts[$0.id] }
        guard !answers.isEmpty else { return }
        run(actions.answer(id, answers)) { self.answerDrafts = [:] }
    }

    private func run(_ refusal: ThreadRefusal?, then done: () -> Void = {}) {
        if let refusal { return fail(refusal) }
        notice = nil
        done()
        refresh()
    }

    private func fail(_ refusal: ThreadRefusal) { notice = Self.words(for: refusal) }

    /// A refusal in plain words, as `CommandCopy` words the phone's: the code is the contract, not
    /// something to read out. An unknown code keeps its code in brackets, for whoever is diagnosing.
    static func words(for refusal: ThreadRefusal) -> String {
        switch refusal.code {
        case IntakeService.threadsUnavailable: unavailableNotice
        case "unknown_thread": "That thread is gone."
        case "unknown_diff", "diff_not_pending": "That edit is no longer waiting for an answer."
        case "diff_stale", "stale_diff": "A round rewrote that passage, so the edit no longer applies. Ask the thread to propose it again."
        case "empty_message", "empty_note": "Write something first."
        case "not_allowed": "That isn't possible right now."
        case "unknown_intake", "intake_moved_on": "This intake has moved on."
        case "no_agents", "no_agent": "No agent is available on this Mac to answer."
        case "thread_resolved": "That thread is resolved. Reopen it to ask again."
        case "diff_decided": "That edit was already answered the other way."
        case "write_failed": "Flight Deck couldn't save that. Check the disk, then try again."
        case "unknown_checkpoint": "That version of the plan is gone. Select the passage again in the current one."
        case "unknown_block": "That passage is no longer in the plan. Select it again."
        case "stale_questions": "Those questions were already answered or replaced."
        case "out_of_scope": "Flight Deck doesn't allow that from here."
        default: "Flight Deck couldn't do that (\(refusal.code))."
        }
    }
}
