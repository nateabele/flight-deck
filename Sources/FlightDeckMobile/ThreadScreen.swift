import FleetKit
import MarkdownUI
import SwiftUI

/// What `FlightControlModel` needs to fetch one thread's page: a separate protocol from
/// `IntakeFetching`, so a stub that never reads threads need not implement it.
@MainActor
protocol ThreadFetching: AnyObject {
    func intakeThread(_ id: UUID, threadID: UUID, since: Int?, then: @escaping (Result<WireThreadPage, FleetRequestError>) -> Void)
}

/// One thread's page as the phone has accumulated it. Threads are fetched on demand and never
/// pushed (spec §10), so the screen asks again while it is open.
@MainActor
@Observable
final class ThreadPageModel {
    private(set) var summary: WireThreadSummary?
    private(set) var turns: [WireThreadTurn] = []
    private(set) var diffs: [WirePendingDiff] = []
    /// The Mac does not list this thread (yet): a thread this phone just opened is only a queued
    /// command until ThreadRunner has read it.
    private(set) var notOnMac = false
    private(set) var failed = false

    /// Fetched again from the first turn the Mac had not finished, so a reply that lands later
    /// replaces its empty turn.
    var since: Int? {
        if let open = turns.first(where: { $0.endedAt == nil }) { return open.seq - 1 }
        return turns.last?.seq
    }

    func apply(_ page: WireThreadPage) {
        notOnMac = false; failed = false
        summary = page.thread
        var bySeq = Dictionary(uniqueKeysWithValues: turns.map { ($0.seq, $0) })
        for t in page.turns { bySeq[t.seq] = t }
        turns = bySeq.values.sorted { $0.seq < $1.seq }
        diffs = page.diffs
    }

    func apply(_ error: FleetRequestError) {
        if case .server(code: "unknown_thread") = error { notOnMac = true; failed = false } else { failed = true }
    }

    /// The questions to answer: the newest turn's, while the thread waits on the person.
    var openQuestions: (turn: Int, questions: [WireStructuredQuestion])? {
        guard summary?.status == "needsYou", let last = turns.last, let q = last.questions, !q.isEmpty else { return nil }
        return (last.seq, q)
    }

    func diff(_ id: UUID) -> WirePendingDiff? { diffs.first { $0.id == id } }
}

/// An ask thread: the conversation, the agent's proposed changes with Accept / ✗, its questions
/// inline (P0's `StructuredQuestionForm`, answered through `intake.thread.answer`) and a composer.
struct ThreadScreen: View {
    let intake: UUID
    let threadID: UUID
    let flightControl: FlightControlModel
    @State private var model = ThreadPageModel()
    @State private var requests = LatestRequest()
    @State private var reply = ""
    /// The turn whose questions were answered here: the form stays gone until a newer turn lands.
    @State private var answeredTurn: Int?
    @State private var openDiff: WirePendingDiff?
    @State private var failedDraft: ThreadDraft?

    private var commands: IntakeCommandModel { flightControl.commands(for: intake) }
    private var detail: WireIntakeDetail? { flightControl.detailModel(for: intake).detail }
    private var outbox: ThreadOutbox { flightControl.threadOutbox(for: intake).outbox }
    private var canAsk: Bool { ThreadGate.canAsk(detail: detail) }
    private var resolved: Bool { model.summary?.status == "resolved" }

    var body: some View {
        List {
            if let s = model.summary { header(s) }
            ForEach(model.turns, id: \.seq) { turnSection($0) }
            pendingSection
            if let open = model.openQuestions, answeredTurn != open.turn, canAsk {
                StructuredQuestionForm(
                    title: "\(open.questions.count) question\(open.questions.count == 1 ? "" : "s") from the agent",
                    questions: open.questions, sending: commands.inFlight.contains(.threadAnswer(threadID))
                ) { answers in
                    flightControl.answerThread(threadID, answers: answers, intake: intake) {
                        answeredTurn = open.turn
                        load()
                    }
                }
                .id("\(threadID)-\(open.turn)")
            }
            if model.summary?.status == "answering" || (model.summary == nil && !outbox.pendingMessages(in: threadID).isEmpty) {
                Section { Label("The agent is working…", systemImage: "ellipsis").font(.subheadline).foregroundStyle(.secondary) }
            }
            if model.notOnMac && outbox.pendingMessages(in: threadID).isEmpty {
                Section { Text("This thread is no longer on your Mac.").font(.subheadline).foregroundStyle(.secondary) }
            }
            if model.failed && model.summary == nil {
                Section { Button("Couldn't load. Retry") { load() } }
            }
            if let message = commands.message {
                Section { Text(message).font(.caption).foregroundStyle(.orange) }
            }
        }
        .navigationTitle(model.summary?.title ?? "Ask")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if canAsk, !resolved, model.summary != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Resolve") { flightControl.resolveThread(threadID, intake: intake) { load() } }
                        .disabled(commands.inFlight.contains(.threadResolve(threadID)))
                }
            }
        }
        .safeAreaInset(edge: .bottom) { if canAsk, !resolved { composer } }
        .sheet(item: $openDiff) { diff in
            PhoneDiffSheet(diff: diff, canDecide: PhoneDiffGutter.canDecide(diff, detail: detail),
                           deciding: commands.inFlight.contains(.diffDecide(diff.id)),
                           onDecide: { accept in
                flightControl.decideDiff(diff, accept: accept, intake: intake) { openDiff = nil; load() }
            }, onOpenThread: { openDiff = nil })
        }
        .task { await poll() }
        .intakePresence(id: intake, model: flightControl.detailModel(for: intake), flightControl: flightControl)
    }

    // MARK: - Pieces

    private func header(_ s: WireThreadSummary) -> some View {
        Section {
            if let q = s.anchor?.quote { Text("“\(q)”").font(.subheadline).italic().foregroundStyle(.secondary) }
            else { Text("The whole plan").font(.subheadline).foregroundStyle(.secondary) }
            Text(ThreadStyle.statusWords(s.status)).font(.caption.weight(.semibold)).foregroundStyle(ThreadStyle.statusTone(s.status))
        }
    }

    private func turnSection(_ t: WireThreadTurn) -> some View {
        Section {
            if let you = t.you { bubble(you, mine: true) }
            if let answers = t.answers, !answers.isEmpty {
                Text("You answered " + answers.map { ($0.selected + [$0.other].compactMap { $0 }).joined(separator: ", ") }.joined(separator: " · "))
                    .font(.subheadline)
            }
            if let reply = t.reply, !reply.isEmpty {
                Markdown(reply).markdownTheme(TimelineMarkdown.theme).textSelection(.enabled)
            } else if t.endedAt == nil {
                Text("Working…").font(.subheadline).foregroundStyle(.secondary)
            }
            if let decision = t.decision, !decision.isEmpty {
                Label(decision, systemImage: "checkmark.seal").font(.footnote).foregroundStyle(.secondary)
            }
            ForEach(t.errors, id: \.self) { Text($0).font(.footnote).foregroundStyle(.red) }
            ForEach(t.diffs ?? [], id: \.self) { id in
                if let diff = model.diff(id) { diffRow(diff) }
            }
        }
    }

    /// A change the agent proposed: tapping shows the old text with the decision, as in the reader.
    private func diffRow(_ d: WirePendingDiff) -> some View {
        let decided = outbox.decision(for: d.id)
        let state = decided.map { $0 ? "accepted" : "rejected" } ?? d.state
        return Button { openDiff = d } label: {
            HStack(alignment: .top, spacing: 8) {
                Capsule().fill(state == "pending" ? Color.green : Color.secondary).frame(width: 3)
                VStack(alignment: .leading, spacing: 2) {
                    Text(.init(d.new)).font(.subheadline).lineLimit(3).multilineTextAlignment(.leading)
                    Text(ThreadStyle.diffWords(state)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(minHeight: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Proposed change, \(ThreadStyle.diffWords(state)): \(d.new)")
    }

    private func bubble(_ text: String, mine: Bool) -> some View {
        Text(text).font(.body).frame(maxWidth: .infinity, alignment: .leading)
    }

    /// What was sent and the Mac has not shown yet, and what failed to send.
    @ViewBuilder private var pendingSection: some View {
        let pending = outbox.pendingMessages(in: threadID)
        let failed = outbox.unsent.filter { $0.threadID == threadID }
        if !pending.isEmpty || !failed.isEmpty {
            Section {
                ForEach(pending) { d in
                    VStack(alignment: .leading, spacing: 2) {
                        bubble(d.text, mine: true)
                        Text("Sent. Waiting for your Mac.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                ForEach(failed) { d in
                    VStack(alignment: .leading, spacing: 4) {
                        bubble(d.text, mine: true)
                        let sending = commands.inFlight.contains(.threadSend(d.id))
                        if sending { Text("Not yet sent").font(.caption).foregroundStyle(.secondary) } else {
                            HStack(spacing: 16) {
                                Text("Not sent").font(.caption).foregroundStyle(.secondary)
                                Button { send(d) } label: { Text("Retry").font(.subheadline).frame(minHeight: 44) }
                                Button(role: .destructive) { flightControl.threadOutbox(for: intake).outbox.remove(d.id) } label: {
                                    Text("Discard").font(.subheadline).frame(minHeight: 44)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Reply to the agent", text: $reply, axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.roundedBorder)
            Button {
                let draft = ThreadDraft(threadID: threadID, anchor: nil, text: reply)
                reply = ""
                send(draft)
            } label: {
                Image(systemName: "arrow.up.circle.fill").font(.title2).frame(minWidth: 44, minHeight: 44)
            }
            .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .accessibilityLabel("Send")
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: - Loading

    private func send(_ d: ThreadDraft) {
        flightControl.sendThread(d, intake: intake) { load() }
    }

    /// Asks again while the screen is open: nothing about a thread is pushed.
    private func poll() async {
        while !Task.isCancelled {
            load()
            try? await Task.sleep(for: .seconds(model.summary?.status == "answering" ? 2 : 5))
        }
    }

    private func load() {
        let token = requests.begin()
        flightControl.thread(intake, threadID: threadID, since: model.since) { result in
            guard requests.accepts(token) else { return }
            switch result {
            case .success(let page):
                model.apply(page)
                flightControl.threadOutbox(for: intake).outbox.reconcile(thread: threadID, turns: model.turns)
                flightControl.threadOutbox(for: intake).outbox.reconcile(diffs: page.diffs)
            case .failure(let error): model.apply(error)
            }
        }
    }
}

/// Words and tones for threads, apart from SwiftUI so a test can read them.
enum ThreadStyle {
    static func statusWords(_ status: String) -> String {
        switch status {
        case "answering": "Agent is working"
        case "needsYou": "Needs you"
        case "stale": "Out of date"
        case "resolved": "Resolved"
        default: "Open"
        }
    }

    static func statusTone(_ status: String) -> Color {
        switch status {
        case "needsYou": .orange
        case "stale": .red
        default: .secondary
        }
    }

    static func diffWords(_ state: String) -> String {
        switch state {
        case "accepted": "Accepted"
        case "rejected": "Rejected"
        case "stale": "Out of date"
        default: "Proposed. Tap to decide."
        }
    }
}


/// The Ask sheet: what was selected, a question, Send. The thread is opened by the send.
struct AskSheet: View {
    let quote: String?
    @State var text = ""
    let onSend: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let quote { Text("“\(quote)”").font(.subheadline).italic().foregroundStyle(.secondary) }
                    else { Text("The whole plan").font(.subheadline).foregroundStyle(.secondary) }
                }
                Section {
                    TextField("Ask the agent", text: $text, axis: .vertical).lineLimit(3...8).focused($focused)
                }
            }
            .navigationTitle("Ask").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Send") { onSend(text.trimmingCharacters(in: .whitespacesAndNewlines)); dismiss() }
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { focused = true }
        }
        .presentationDetents([.medium, .large])
    }
}
