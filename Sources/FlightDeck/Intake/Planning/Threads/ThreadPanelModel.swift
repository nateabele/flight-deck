import Combine
import Foundation
import IntakeKit

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
}

/// What the store held at one poll. Equatable so a poll that finds nothing new publishes nothing.
struct ThreadSnapshot: Equatable {
    var threads: [ThreadRecord] = []
    var turns: [ThreadID: [ThreadTurn]] = [:]
    var diffs: [ThreadID: [ThreadDiff]] = [:]
    var activity: [ThreadID: String] = [:]
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
        var decide: @MainActor (ThreadID, UUID, Bool) -> ThreadRefusal?
        var repropose: @MainActor (ThreadID, UUID) -> ThreadRefusal?

        init(open: @escaping @MainActor (ThreadAnchor, String, String, ThreadDefaults) -> Result<ThreadID, ThreadRefusal> = { _, _, _, _ in .failure(ThreadPanelModel.unavailable) },
             send: @escaping @MainActor (ThreadID, String) -> ThreadRefusal? = { _, _ in ThreadPanelModel.unavailable },
             answer: @escaping @MainActor (ThreadID, [StructuredAnswer]) -> ThreadRefusal? = { _, _ in ThreadPanelModel.unavailable },
             setAutoAccept: @escaping @MainActor (ThreadID, Bool) -> ThreadRefusal? = { _, _ in ThreadPanelModel.unavailable },
             resolve: @escaping @MainActor (ThreadID) -> ThreadRefusal? = { _ in ThreadPanelModel.unavailable },
             reopen: @escaping @MainActor (ThreadID) -> ThreadRefusal? = { _ in ThreadPanelModel.unavailable },
             decide: @escaping @MainActor (ThreadID, UUID, Bool) -> ThreadRefusal? = { _, _, _ in ThreadPanelModel.unavailable },
             repropose: @escaping @MainActor (ThreadID, UUID) -> ThreadRefusal? = { _, _ in ThreadPanelModel.unavailable }) {
            self.open = open
            self.send = send
            self.answer = answer
            self.setAutoAccept = setAutoAccept
            self.resolve = resolve
            self.reopen = reopen
            self.decide = decide
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
                decide: { binding.decideDiff($0, diff: $1, accept: $2) },
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
    var defaults = ThreadDefaults()

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
    /// A refusal or failure to show under the composer; cleared by the next thing that works.
    @Published private(set) var notice: String?
    /// The answers being picked for the open question, by question id.
    @Published var answerDrafts: [String: StructuredAnswer] = [:]
    @Published private var autoAcceptOverrides: [ThreadID: (value: Bool, at: Date)] = [:]
    private var drafts: [ThreadID?: String] = [:]

    private var clock: WatchClock?

    /// The app's one poll clock is `SessionStore.watchClock`, which a view cannot reach; this one
    /// only runs while a rail or panel is on screen, and sleeps otherwise.
    static let sharedClock = WatchClock()

    init(intakeID: UUID, reader: any ThreadStoreReading, actions: Actions = Actions(),
         headings: @escaping () -> [String] = { [] }) {
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

    /// Reads the store now and on every beat of `clock` until `stop()`.
    func start(on clock: WatchClock = ThreadPanelModel.sharedClock) {
        if let current = self.clock, current !== clock { current.remove(self) }
        self.clock = clock
        clock.add(self) { [weak self] in MainActor.assumeIsolated { self?.refresh() } }
        refresh()
    }

    func stop() {
        clock?.remove(self)
        clock = nil
    }

    func refresh() {
        let records = reader.threads()
        var next = ThreadSnapshot(threads: records)
        for record in records {
            next.turns[record.id] = reader.turns(record.id)
            next.diffs[record.id] = reader.diffs(record.id)
            if let live = reader.activity(record.id) { next.activity[record.id] = live }
        }
        if next != snapshot { snapshot = next }
        settleOverrides()
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

    /// The questions the agent asked that no later turn answered.
    func openQuestions(_ id: ThreadID) -> [StructuredQuestion] {
        let all = turns(id)
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
                                 section: record.anchor.note?.section.map(Self.sectionLabel), status: record.status)
    }

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
        newThreadAnchor = anchor
        isOpen = true
        notice = nil
        composer = drafts[ThreadID?.none] ?? ""
    }

    func close() {
        stashDraft()
        isOpen = false
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
            switch actions.open(anchor, Self.title(from: text), text, defaults) {
            case .failure(let refusal): return fail(refusal)
            case .success(let id):
                thread = id
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
    func decide(_ diff: ThreadDiff, accept: Bool) { run(actions.decide(diff.thread, diff.id, accept)) }
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

    private func fail(_ refusal: ThreadRefusal) {
        notice = refusal.code == IntakeService.threadsUnavailable ? Self.unavailableNotice : "Couldn't do that (\(refusal.code))."
    }
}
