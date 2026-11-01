import AppKit
import IntakeKit
import SwiftUI

/// The one place planning's halts are told: what stopped, why, for how long, and what to do —
/// the same panel for a failed round, an intake-level failure, an interrupted release, a pause,
/// a stop and a rate-limited seat. `HaltStatus` decides every word and which controls apply;
/// this view only draws them and hands the press back (`perform`), so Retry, To review and Resume
/// run the paths the transport keys do.
///
/// "Retry with another model" is a menu of the other agents and models the failed seat could take
/// (`HaltReseat`); choosing one saves it to the seat and retries, so a down model is one click
/// from running on another. `openRounds`, when given, adds the full editor to that menu.
struct HaltPanel: View {
    let status: HaltStatus
    /// Other models the failed seat could move to; empty hides Retry with another model's menu
    /// down to the editor entry alone.
    let reseat: [HaltReseat.Group]
    let perform: (HaltStatus.Action) -> Void
    let choose: (ModelChoice) -> Void
    let openRounds: (() -> Void)?
    let naming: (ModelChoice) -> String

    @State private var showsOutput: Bool

    init(status: HaltStatus, reseat: [HaltReseat.Group] = [], outputOpen: Bool = false,
         perform: @escaping (HaltStatus.Action) -> Void, choose: @escaping (ModelChoice) -> Void = { _ in },
         openRounds: (() -> Void)? = nil, naming: @escaping (ModelChoice) -> String = { "\($0.agent.displayName) · \($0.model)" }) {
        self.status = status
        self.reseat = reseat
        self.perform = perform
        self.choose = choose
        self.openRounds = openRounds
        self.naming = naming
        _showsOutput = State(initialValue: outputOpen)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            reason
            if let whatToDo = status.whatToDo {
                Text(Self.codeSpans(whatToDo))
                    .font(.system(size: 12.5))
                    .foregroundStyle(Instrument.phosphor)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("halt-panel-what-to-do")
            }
            if let slot = status.slot { slotLine(slot) }
            controls
            if showsOutput, let output = status.output { outputTail(output) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(LinearGradient(colors: [Instrument.glassTop, Instrument.glassBottom], startPoint: .top, endPoint: .bottom))
        )
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.45), lineWidth: 1))
        .shadow(color: Instrument.glassShadow, radius: 1, y: 0.5)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("halt-panel")
    }

    // MARK: - Parts

    private var tint: Color { status.kind.isFailure ? Instrument.red : Instrument.amber }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: Self.glyph(status.kind)).foregroundStyle(tint)
            Text(status.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Instrument.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let since = status.since { clock(since) }
        }
    }

    /// "HALTED FOR 04:12", ticking on its own second: the panel can stand alone in a stage body
    /// that has no timeline of its own.
    private func clock(_ since: Date) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 6) {
                Text(Self.clockLabel(status.kind))
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Instrument.phosphor.opacity(0.5))
                Text(BoardModel.clock(max(0, context.date.timeIntervalSince(since))))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private var reason: some View {
        Text(status.reason)
            .font(.system(size: 12.5))
            .foregroundStyle(status.kind.isFailure ? Instrument.red : Instrument.phosphor)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityIdentifier("halt-panel-reason")
    }

    private func slotLine(_ slot: HaltStatus.Slot) -> some View {
        HStack(spacing: 6) {
            Text("AGENT")
                .font(.system(size: 9.5, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(Instrument.phosphor.opacity(0.5))
            Text(Self.slotText(slot))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Instrument.phosphor)
                .lineLimit(2)
                .textSelection(.enabled)
        }
        .accessibilityIdentifier("halt-panel-slot")
    }

    private var controls: some View {
        HStack(spacing: 8) {
            ForEach(status.actions.filter { $0 != .showOutput }, id: \.self) { action in
                control(action)
            }
            Spacer(minLength: 0)
            if status.actions.contains(.showOutput), status.output != nil {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { showsOutput.toggle() }
                } label: {
                    Label(showsOutput ? "Hide agent output" : "Show agent output",
                          systemImage: showsOutput ? "chevron.down" : "chevron.right")
                }
                .buttonStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(Instrument.blue)
                .accessibilityIdentifier("halt-panel-show-output")
            }
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func control(_ action: HaltStatus.Action) -> some View {
        switch action {
        case .retryOther:
            retryOther
        case .retry, .resume, .toReview:
            Button(Self.label(action)) { perform(action) }
                .buttonStyle(.borderedProminent)
                .tint(action == .retry || action == .resume ? Instrument.blue : nil)
                .help(Self.help(action))
                .accessibilityIdentifier("halt-panel-\(action.rawValue)")
        case .showOutput:
            EmptyView()
        }
    }

    private var retryOther: some View {
        Menu {
            ForEach(reseat, id: \.agent) { group in
                Menu(group.agent.displayName) {
                    ForEach(group.choices, id: \.model) { choice in
                        Button(naming(choice)) { choose(choice) }
                    }
                }
            }
            if let openRounds {
                if !reseat.isEmpty { Divider() }
                Button("Edit rounds…", action: openRounds)
            }
        } label: {
            Text(Self.label(.retryOther))
        }
        .menuStyle(.button)
        .fixedSize()
        .help(Self.help(.retryOther))
        .accessibilityIdentifier("halt-panel-retryOther")
    }

    private func outputTail(_ output: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("AGENT OUTPUT")
                    .font(.system(size: 9.5, weight: .bold))
                    .tracking(1.2)
                    .foregroundStyle(Instrument.phosphor.opacity(0.5))
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(output, forType: .string)
                } label: {
                    Label("Copy", systemImage: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Instrument.blue)
                .help("Copy the agent's output")
            }
            ScrollView {
                Text(output)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(Instrument.phosphor)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(maxHeight: 180)
            .background(RoundedRectangle(cornerRadius: 6).fill(Instrument.well))
        }
        .accessibilityIdentifier("halt-panel-output")
    }

    // MARK: - Words

    static func glyph(_ kind: HaltStatus.Kind) -> String {
        switch kind {
        case .roundFailed, .intakeFailed: "exclamationmark.triangle.fill"
        case .interrupted: "bolt.slash.fill"
        case .paused: "pause.circle.fill"
        case .stopped: "stop.circle.fill"
        case .rateLimited: "hourglass"
        }
    }

    static func clockLabel(_ kind: HaltStatus.Kind) -> String {
        switch kind {
        case .paused: "PAUSED FOR"
        case .stopped: "STOPPED FOR"
        case .rateLimited: "WAITING FOR"
        case .roundFailed, .intakeFailed, .interrupted: "HALTED FOR"
        }
    }

    static func label(_ action: HaltStatus.Action) -> String {
        switch action {
        case .retry: "Retry"
        case .retryOther: "Retry with another model"
        case .toReview: "To review"
        case .resume: "Resume"
        case .showOutput: "Show agent output"
        }
    }

    static func help(_ action: HaltStatus.Action) -> String {
        switch action {
        case .retry: "Run the round that stopped again, as it is"
        case .retryOther: "Give the failed role to another agent or model, then run the round again"
        case .toReview: "Run every remaining round, to release review"
        case .resume: "Carry on with the default play"
        case .showOutput: "The tail of what the failed agent printed"
        }
    }

    /// "polisher · Gemini 3 Pro · high": the role, then who ran it. `ran` is the model's name as
    /// the halt model chose to write it; the harness and model ids stand in when it has none.
    static func slotText(_ slot: HaltStatus.Slot) -> String {
        let who = slot.ran.isEmpty ? [slot.harness, slot.model].compactMap { $0 }.joined(separator: " · ") : slot.ran
        return who.isEmpty ? slot.role : "\(slot.role) · \(who)"
    }

    /// `codex login` in the monospaced face. Set by hand: a parsed code span under the view's
    /// `.font` came out in the body face with its backticks gone, so the command read as a word.
    static func codeSpans(_ text: String) -> AttributedString {
        guard var out = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))
        else { return AttributedString(text) }
        for run in out.runs where run.inlinePresentationIntent?.contains(.code) == true {
            out[run.range].font = .system(size: 12, weight: .medium, design: .monospaced)
        }
        return out
    }
}

extension HaltStatus.Kind {
    /// A failure reads red; a pause, stop or wait is the amber of a state the human chose or can
    /// simply wait out.
    var isFailure: Bool { self == .roundFailed || self == .intakeFailed || self == .interrupted }
}
