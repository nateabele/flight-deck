import AppKit
import IntakeKit
import SwiftUI

/// The thread panel (spec §6): replaces the notes rail inside the inspector. The index is 180 pt
/// (R7) and the conversation takes the rest. Below `wideEnough` the two don't fit side by side,
/// so the conversation gets the column and the index is a page behind a button.
struct ThreadPanel: View {
    @ObservedObject var model: ThreadPanelModel
    /// Where the human's notes live, so a note the agent left can be withdrawn like any other.
    let withdraw: (UUID) -> Void
    /// A citation chip was pressed.
    let openCitation: (ThreadCitation) -> Void
    /// A thread was chosen: the plan scrolls to its anchor.
    let reveal: (ThreadRecord) -> Void
    var projectPath: String?
    /// Renders only: a focused composer would take the editor's focus.
    var focusesComposer = true

    static let indexWidth: CGFloat = 180
    static let wideEnough: CGFloat = 480

    @State private var narrowShowsIndex = false

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width >= Self.wideEnough
            VStack(spacing: 0) {
                topBar(wide: wide)
                Divider()
                if wide {
                    HStack(spacing: 0) {
                        ThreadIndexView(model: model, choose: choose)
                            .frame(width: Self.indexWidth)
                        Divider()
                        conversation
                    }
                } else if narrowShowsIndex {
                    ThreadIndexView(model: model, choose: { choose($0); narrowShowsIndex = false })
                } else {
                    conversation
                }
            }
            .onAppear { model.width = geo.size.width }
            .onChange(of: geo.size.width) { _, width in model.width = width }
        }
        // Spec §6: ⌘[ and ⌘] move between threads "while the panel has focus": key presses that
        // reach the panel from whatever inside it is focused (the composer included), and not a
        // window-wide shortcut that would also fire from the plan.
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(keys: [KeyEquivalent("["), KeyEquivalent("]")]) { press in
            guard let step = ThreadPanelModel.switchStep(key: press.characters, command: press.modifiers.contains(.command)) else {
                return .ignored
            }
            model.switchThread(by: step)
            return .handled
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("thread-panel")
    }

    private func choose(_ id: ThreadID) {
        model.open(id)
        if let record = model.record(id) { reveal(record) }
    }

    private func topBar(wide: Bool) -> some View {
        HStack(spacing: 8) {
            Button { model.close() } label: { Label("Notes", systemImage: "chevron.left") }
                .buttonStyle(.borderless)
                .help("Back to the notes")
                .accessibilityIdentifier("thread-panel-back")
            Text("Threads (\(model.liveCount))").fontWeight(.semibold)
            Spacer(minLength: 0)
            if !wide {
                Button { narrowShowsIndex.toggle() } label: { Image(systemName: "list.bullet") }
                    .buttonStyle(.borderless)
                    .help(narrowShowsIndex ? "Back to the conversation" : "All threads")
                    .accessibilityIdentifier("thread-index-toggle")
            }
        }
        .font(.callout)
        .padding(.horizontal, 14)
        .frame(height: 38)
    }

    @ViewBuilder
    private var conversation: some View {
        if let selected = model.selected, !model.isComposingNewThread, model.record(selected) != nil {
            ThreadConversation(model: model, id: selected, withdraw: withdraw, openCitation: openCitation,
                               projectPath: projectPath, focusesComposer: focusesComposer)
        } else if let anchor = model.newThreadAnchor {
            NewThreadView(model: model, anchor: anchor, focusesComposer: focusesComposer)
        } else {
            InspectorPlaceholder(title: "No thread open", message: "Pick one from the list, or select text in the plan and press ✦ Ask.")
        }
    }
}

// MARK: Index

private struct ThreadIndexView: View {
    @ObservedObject var model: ThreadPanelModel
    let choose: (ThreadID) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).imageScale(.small)
                TextField("Filter threads", text: $model.filter)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .accessibilityIdentifier("thread-filter")
            }
            .padding(.horizontal, 8)
            .frame(height: 26)
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.secondary.opacity(0.4)))
            .padding(.horizontal, 8)
            .padding(.vertical, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    group("Open", rows: model.index.open)
                    group("Needs you", rows: model.index.needsYou)
                    group("Resolved", rows: model.index.resolved, dim: true)
                    if model.index.all.isEmpty {
                        Text(model.filter.isEmpty ? "No threads yet." : "Nothing matches.")
                            .font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 14).padding(.top, 6)
                    }
                    Button { model.beginThread(on: .wholePlan) } label: {
                        Text("＋ New thread on whole plan").font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 14)
                    .padding(.top, 14)
                    .accessibilityIdentifier("thread-new-whole-plan")
                }
                .padding(.bottom, 12)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.04))
    }

    @ViewBuilder
    private func group(_ title: String, rows: [ThreadIndexRow], dim: Bool = false) -> some View {
        if !rows.isEmpty {
            Text(title.uppercased())
                .font(.system(size: 10.5, weight: .bold))
                .tracking(0.5)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 10)
                .padding(.bottom, 3)
                .accessibilityAddTraits(.isHeader)
            ForEach(rows) { row in
                let on = row.id == model.selected && !model.isComposingNewThread
                Button { choose(row.id) } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("✦ \(row.title)").font(.system(size: 12.5)).lineLimit(2)
                        HStack(spacing: 4) {
                            Text(row.detail).lineLimit(1)
                            if let pill = row.pill, pill != .needsYou { Text("· \(pill.text)").lineLimit(1) }
                        }
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(on ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 7))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 6)
                .opacity(dim ? 0.6 : 1)
                .accessibilityIdentifier("thread-index-row")
            }
        }
    }
}

// MARK: Conversation

private struct ThreadConversation: View {
    @ObservedObject var model: ThreadPanelModel
    let id: ThreadID
    let withdraw: (UUID) -> Void
    let openCitation: (ThreadCitation) -> Void
    let projectPath: String?
    let focusesComposer: Bool

    var body: some View {
        VStack(spacing: 0) {
            if let header = model.header(for: id) { ThreadHeaderView(model: model, id: id, header: header) }
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(Array(model.turns(id).enumerated()), id: \.element.seq) { at, turn in
                            if at > 0, model.turns(id)[at - 1].checkpoint != turn.checkpoint {
                                versionDivider(turn.checkpoint)
                            }
                            TurnView(model: model, thread: id, turn: turn, isLast: at == model.turns(id).count - 1,
                                     withdraw: withdraw, openCitation: openCitation, projectPath: projectPath)
                        }
                        if let live = model.snapshot.activity[id] {
                            Text("● \(live)").font(.system(size: 12)).foregroundStyle(.green)
                        }
                        Color.clear.frame(height: 1).id("end")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .onChange(of: model.turns(id).count) { _, _ in proxy.scrollTo("end") }
                .onAppear { proxy.scrollTo("end") }
            }
            ThreadComposer(model: model, focuses: focusesComposer)
        }
    }

    private func versionDivider(_ checkpoint: Int) -> some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
            Text("moved to \(model.versionLabel(checkpoint) ?? "checkpoint \(checkpoint)")")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize()
            Rectangle().fill(Color.secondary.opacity(0.3)).frame(height: 1)
        }
    }
}

private struct ThreadHeaderView: View {
    @ObservedObject var model: ThreadPanelModel
    let id: ThreadID
    let header: ThreadHeaderModel

    private var agentMenu: some View {
        let choices = model.agentChoices
        return Menu {
            ForEach(choices) { choice in
                Button { model.setAgent(id, choice) } label: {
                    Text("\(choice.agent.displayName) · \(choice.modelName)")
                }
            }
        } label: {
            Text("\(header.agent) ▾")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .disabled(choices.isEmpty)
        .help("The agent that answers this thread")
        .accessibilityLabel("Agent")
        .accessibilityValue(header.agent)
        .accessibilityIdentifier("thread-agent-menu")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("✦ \(header.title)").font(.system(size: 14, weight: .semibold)).lineLimit(2)
                Spacer(minLength: 0)
                if header.status == .resolved {
                    Button("Reopen") { model.reopen(id) }.controlSize(.small).accessibilityIdentifier("thread-reopen")
                } else {
                    Button("Resolve") { model.resolve(id) }.controlSize(.small).accessibilityIdentifier("thread-resolve")
                }
            }
            // Wraps: at the inspector's 300 pt minimum the three facts don't share a line.
            FlowRow(spacing: 10) {
                // Who answers: a menu of the agents and models this Mac can run. Grok and OpenCode
                // read files only (R1), and the header says so.
                agentMenu
                if header.readsFilesOnly { Text("reads files only").foregroundStyle(.secondary).font(.system(size: 11)) }
                Toggle("Auto-accept diffs", isOn: Binding(get: { model.autoAccept(id) }, set: { model.setAutoAccept(id, $0) }))
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .accessibilityIdentifier("thread-auto-accept")
                Text(header.follows).foregroundStyle(.secondary)
            }
            .font(.system(size: 12))
            if let quote = header.quote {
                HStack(spacing: 0) {
                    Text("“\(quote.replacingOccurrences(of: "\n", with: " "))”" + (header.section.map { " · \($0)" } ?? ""))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .padding(.leading, 8)
                }
                .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor).frame(width: 3) }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

/// Lays its children left to right and wraps them, for a header row that must survive 300 pt.
private struct FlowRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let laid = arrange(width: bounds.width, subviews: subviews)
        for (subview, origin) in zip(subviews, laid.origins) {
            subview.place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + 4
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return (CGSize(width: widest, height: y + rowHeight), origins)
    }
}

private struct TurnView: View {
    @ObservedObject var model: ThreadPanelModel
    let thread: ThreadID
    let turn: ThreadTurn
    let isLast: Bool
    let withdraw: (UUID) -> Void
    let openCitation: (ThreadCitation) -> Void
    let projectPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let you = turn.you {
                VStack(alignment: .leading, spacing: 2) {
                    who("You")
                    Text(you)
                        .font(.system(size: 12.5))
                        .textSelection(.enabled)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.accentColor.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }
            if turn.answers != nil {
                who("You answered")
            }
            if turn.reply != nil || !turn.actions.isEmpty || !turn.errors.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    who("Agent")
                    if let reply = turn.reply { ThreadReplyText(reply: reply, open: openCitation) }
                    ForEach(Array(turn.actions.enumerated()), id: \.offset) { _, action in actionView(action) }
                    ForEach(turn.errors, id: \.self) { error in
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 11.5)).foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private func who(_ name: String) -> some View {
        Text(name).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
    }

    @ViewBuilder
    private func actionView(_ action: ThreadAction) -> some View {
        switch action {
        case .proposeDiff:
            ForEach(model.diffs(thread).filter { $0.turn == turn.seq }, id: \.id) { diff in
                DiffActionRow(diff: diff, decide: { model.decide(diff, accept: $0) }, repropose: { model.repropose(diff) })
            }
        case .addNote(let note):
            ActionBox {
                ThreadPillView(NoteStyle.label(note.kind))
                Text("“\(note.note)” · pending for next round").font(.system(size: 12)).lineLimit(2)
                Spacer(minLength: 0)
                Button("Withdraw") { withdraw(note.id) }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .askQuestion(let question):
            QuestionBox(model: model, thread: thread, question: question, live: isLast && !answered, projectPath: projectPath)
        }
    }

    private var answered: Bool { model.openQuestions(thread).isEmpty }
}

private struct ActionBox<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 8) { content }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.secondary.opacity(0.35)))
    }
}

private struct DiffActionRow: View {
    let diff: ThreadDiff
    let decide: (Bool) -> Void
    let repropose: () -> Void

    var body: some View {
        ActionBox {
            ThreadPillView("diff", tone: .diff)
            Text((diff.anchor.section.map(ThreadPanelModel.sectionLabel) ?? "Plan") + (diff.state == .pending ? " · shown inline in the plan" : ""))
                .font(.system(size: 12)).lineLimit(1)
            Spacer(minLength: 0)
            switch diff.state {
            case .pending:
                Button { decide(false) } label: { Text("✗").foregroundStyle(.red) }.buttonStyle(.plain)
                    .help("Reject this edit")
                    .accessibilityIdentifier("thread-diff-reject")
                Button { decide(true) } label: { Text("✓").foregroundStyle(.green).fontWeight(.semibold) }.buttonStyle(.plain)
                    .help("Apply this edit to the plan")
                    .accessibilityIdentifier("thread-diff-accept")
            case .accepted: Text("accepted").font(.system(size: 11.5)).foregroundStyle(.secondary)
            case .rejected: Text("rejected").font(.system(size: 11.5)).foregroundStyle(.secondary)
            case .stale:
                ThreadPillView("stale", tone: .stale)
                Button("Re-propose", action: repropose).controlSize(.small)
            }
        }
    }
}

/// A question the agent asked, with the same controls as triage's (`StructuredQuestionView`).
private struct QuestionBox: View {
    @ObservedObject var model: ThreadPanelModel
    let thread: ThreadID
    let question: StructuredQuestion
    let live: Bool
    let projectPath: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("Question for you").fontWeight(.semibold)
                if live { Text("· pick one").foregroundStyle(.secondary) }
            }
            .font(.system(size: 12))
            Text(question.text).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
            StructuredQuestionView(
                question: question,
                answer: Binding(get: { model.answerDrafts[question.id] ?? StructuredAnswer(questionID: question.id) },
                                set: { model.answerDrafts[question.id] = $0 }),
                projectPath: projectPath)
                .disabled(!live)
            if live {
                Button("Send answer") { model.submitAnswers(thread) }
                    .controlSize(.small)
                    .disabled(model.answerDrafts[question.id] == nil)
                    .accessibilityIdentifier("thread-send-answer")
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(Color.accentColor.opacity(0.6)))
        .opacity(live ? 1 : 0.7)
    }
}

// MARK: Composer

private struct ThreadComposer: View {
    @ObservedObject var model: ThreadPanelModel
    let focuses: Bool
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let notice = model.notice {
                Text(notice).font(.system(size: 11.5)).foregroundStyle(.orange)
            }
            TextField("Reply… (⌘↩ to send · ⌘⇧↩ to send and resolve)", text: $model.composer, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .lineLimit(2...6)
                .focused($focused)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.secondary.opacity(0.5)))
                .accessibilityIdentifier("thread-composer")
            // The keys live on buttons so they work with the field focused; hidden, as the field
            // itself says what they are.
            ZStack {
                Button("Send") { model.send() }.keyboardShortcut(.return, modifiers: .command)
                Button("Send and resolve") { model.send(andResolve: true) }.keyboardShortcut(.return, modifiers: [.command, .shift])
            }
            .opacity(0).frame(width: 0, height: 0).allowsHitTesting(false).accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Divider() }
        .onAppear { if focuses { DispatchQueue.main.async { focused = true } } }
    }
}

/// A thread not yet started: its anchor and an empty composer.
private struct NewThreadView: View {
    @ObservedObject var model: ThreadPanelModel
    let anchor: ThreadAnchor
    let focusesComposer: Bool

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("✦ New thread").font(.system(size: 14, weight: .semibold))
                if let quote = anchor.note?.quote, !quote.isEmpty {
                    Text("“\(quote.replacingOccurrences(of: "\n", with: " "))”")
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(4)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) { Rectangle().fill(Color.accentColor).frame(width: 3) }
                } else {
                    Text("About the whole plan").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            Divider()
            Spacer(minLength: 0)
            ThreadComposer(model: model, focuses: focusesComposer)
        }
    }
}

// MARK: In the rail

/// What the inspector shows in Notes mode: the rail, or the panel that replaces it. One view
/// observing the model, so opening or closing the panel redraws this and nothing around it.
struct RailOrPanel<Rail: View>: View {
    @ObservedObject var model: ThreadPanelModel
    let controller: PlanNotesController
    @ViewBuilder let rail: Rail
    var focusesComposer = true

    var body: some View {
        // One container for both: its appearing and disappearing are the rail or the panel being on
        // screen, and a swap between them is neither. (Modifiers on each branch fired a stop for the
        // one leaving and a start for the one arriving, in an order the swap does not promise.)
        VStack(spacing: 0) {
            if model.isOpen {
                ThreadPanel(model: model, withdraw: { controller.withdrawNote($0) },
                            openCitation: { ThreadCitationRouter.open($0, controller: controller) },
                            reveal: { controller.reveal(thread: $0) }, projectPath: controller.projectPath,
                            focusesComposer: focusesComposer)
            } else {
                rail
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }
}

/// "Threads (4) ⤢" in the rail's header: opens the panel on the thread it was last on, the first
/// one, or a new thread on the whole plan when there are none.
struct ThreadsHeaderButton: View {
    @ObservedObject var model: ThreadPanelModel

    var body: some View {
        Button {
            if let selected = model.selected, model.record(selected) != nil { model.open(selected) }
            else if let first = model.index.all.first { model.open(first.id) }
            else { model.beginThread(on: .wholePlan) }
        } label: {
            Text("Threads (\(model.liveCount)) ⤢").font(.system(size: 12))
        }
        .buttonStyle(.borderless)
        .help("Open the thread panel")
        .accessibilityIdentifier("notes-threads-button")
    }
}

/// What a citation chip opens. A checkpoint goes through the round list's navigation, as the spec
/// says; a file opens relative to the intake's project. The intake and issue chips have nowhere to
/// go on the Mac yet (the plan is already the intake's; issues arrive with provenance in a later
/// task), so they are inert rather than pointing somewhere wrong.
@MainActor
enum ThreadCitationRouter {
    static func open(_ citation: ThreadCitation, controller: PlanNotesController) {
        switch citation {
        case .checkpoint(let n): controller.openCheckpoint(n)
        case .file(let path, _):
            let url = path.hasPrefix("/") ? URL(fileURLWithPath: path)
                : controller.projectPath.map { URL(fileURLWithPath: $0).appendingPathComponent(path) }
            if let url, FileManager.default.fileExists(atPath: url.path) { NSWorkspace.shared.open(url) }
        case .intake, .issue: break
        }
    }
}
