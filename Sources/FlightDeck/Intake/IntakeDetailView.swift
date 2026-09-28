import IntakeKit
import SwiftUI

/// The right-hand pane of `ProjectView`'s Intakes split, one selected `Intake` at a time.
/// Entirely state-driven off `Intake.state` — see the table in
/// `.superpowers/sdd/2026-09-26-flywheel-intake-phase1-3/task-17-brief.md`.
struct IntakeDetailView: View {
    /// Observed, not just held: a tape advancing changes `service.tapes` without changing
    /// `intake`, and a plain `let` would let SwiftUI skip this body on exactly that update.
    @ObservedObject var service: IntakeService
    let intake: Intake
    /// Opens `ProjectView`'s release-review sheet; the sheet's own state (`reviewIntakeID`)
    /// lives on `ProjectView`, not here, because `Task 18`'s `ReleaseReviewView` loads its
    /// review model independently in a `.task` keyed on the id ProjectView hands it.
    let onOpenReview: () -> Void

    /// Answer drafts for `.needsAnswers`, indexed the same as the current exchange's
    /// questions. Reloaded via `.task(id:)` below whenever the question set changes — the
    /// same `IntakeDetailView` instance lives across a `needsAnswers` → `triaging` →
    /// `needsAnswers` round trip (selection doesn't change), so a plain `@State` seeded
    /// once at init would still hold the previous round's drafts. Mirrored to
    /// `answer-drafts.json` through the service so a relaunch (a release swap) keeps them.
    @State private var answers: [String] = []
    @State private var selectedPreset: Preset = .bead
    /// Indices into `intake.exchanges` whose Clarifications section is open. Collapsed by
    /// default: answered rounds are there to look back at, not to push the live work down.
    @State private var expandedRounds: Set<Int>
    @State private var confirmingDiscard = false

    init(service: IntakeService, intake: Intake, onOpenReview: @escaping () -> Void,
         expandedRounds: Set<Int> = []) {
        self.service = service
        self.intake = intake
        self.onOpenReview = onOpenReview
        _expandedRounds = State(initialValue: expandedRounds)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 8) {
                        IntakeStatePill(intake: intake, tape: service.tapes[intake.id])
                        Text(intake.intent)
                            .font(.title3)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    Divider()
                    clarifications
                    content
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            // Pinned outside the ScrollView so the way forward (and out) is always in reach,
            // however long the questions or the shaping tape run.
            if Self.primaryAction(for: intake.state, preset: selectedPreset) != nil
                || Self.closeAction(for: intake.state) != nil {
                Divider()
                actionBar
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .accessibilityIdentifier("intake-detail")
    }

    @ViewBuilder
    private var content: some View {
        switch intake.state {
        case .triaging: triagingBody
        case .needsAnswers: needsAnswersBody
        case .awaitingChoice: awaitingChoiceBody
        case .shaping: shapingBody
        case .parked: parkedBody
        case .review: reviewBody
        case .releasing: releasingBody
        case .released, .partiallyReleased: releasedBody
        case .failed, .interrupted: failedBody
        // `intakeService.intakes(forProject:)` already filters discarded intakes out of
        // the list this view is selected from, so this arm exists only for exhaustiveness.
        case .discarded: EmptyView()
        }
    }

    private var triagingBody: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            // Only a resumed turn has a `HarnessSession` yet — the very first turn's
            // harness/model is decided inside `IntakeService` and isn't published back
            // onto the intake until that turn completes.
            if let session = intake.triage {
                Text("Triaging with \(session.harness.rawValue) · \(session.model)")
            } else {
                Text("Triaging…")
            }
        }
        .foregroundStyle(.secondary)
    }

    private var openQuestions: [String] {
        guard let open = intake.exchanges.last, open.answers == nil else { return [] }
        return open.questions
    }

    /// The open round as a grouped form: numbered, fully wrapped questions, each over a
    /// multi-line answer field. Sent rounds leave this form and reappear under Clarifications.
    private var needsAnswersBody: some View {
        let questions = openQuestions
        return VStack(alignment: .leading, spacing: 6) {
            Text(questions.count == 1 ? "Question" : "Questions").font(.headline)
            GroupedRows(count: questions.count) { i in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(i + 1).")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(questions[i])
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                        TextField("Answer \(i + 1)", text: answerBinding(i), prompt: Text("Your answer"), axis: .vertical)
                            .labelsHidden()
                            .lineLimit(2...6)
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
            Text("Triage continues once every question has an answer. Press ⌘↩ to send.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        // Keyed on the questions' CONTENTS (and the intake): a follow-up round with the same
        // number of questions used to keep the previous round's answers typed into the new
        // questions' fields, ready to send against questions they never answered.
        .task(id: [intake.id.uuidString] + questions) {
            answers = service.answerDrafts(intake.id, questions: questions)
                ?? Array(repeating: "", count: questions.count)
        }
        // Debounced write-through: every keystroke restarts this task, so the file is written
        // once typing pauses. `saveAnswerDrafts` refuses a round already sent, so a write
        // racing Send can't resurrect it.
        .task(id: answers) { [answers, id = intake.id] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            service.saveAnswerDrafts(id, questions: questions, answers: answers)
        }
    }

    private func answerBinding(_ index: Int) -> Binding<String> {
        Binding(
            get: { index < answers.count ? answers[index] : "" },
            set: { newValue in
                guard index < answers.count else { return }
                answers[index] = newValue
            }
        )
    }

    /// At least one answer, and none of them blank once whitespace/newlines are trimmed —
    /// otherwise "Send answers" would ship empty strings straight to `IntakeService.answer`,
    /// which has no guard of its own against that (it only checks `state == .needsAnswers`
    /// and a non-empty exchange).
    static func canSendAnswers(_ answers: [String]) -> Bool {
        !answers.isEmpty && !answers.contains { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private var awaitingChoiceBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let recommended = intake.recommended {
                Text("Recommended: \(UIText.presetName(recommended))").font(.callout.weight(.semibold))
            }
            if let reason = intake.recommendationReason {
                Text(reason).foregroundStyle(.secondary)
            }
            Picker("Fidelity", selection: $selectedPreset) {
                ForEach(Self.allPresets, id: \.self) { preset in
                    Text(UIText.presetName(preset)).tag(preset)
                }
            }
            .pickerStyle(.menu)
            if selectedPreset != .bead {
                roundsEditor
            }
        }
        .task(id: intake.id) { selectedPreset = intake.recommended ?? .bead; seedConfig() }
        .onChange(of: selectedPreset) { seedConfig() }
    }

    /// The Rounds disclosure: the selected preset's expansion, editable before Start Planning. Re-seeded
    /// whenever the preset changes, so an edit to Full plan's config never leaks into Sketch's.
    @ViewBuilder
    private var roundsEditor: some View {
        if let config = editedConfig {
            RoundConfigEditor(
                preset: selectedPreset,
                config: Binding(get: { config }, set: { editedConfig = $0 }),
                available: service.availableModels()
            )
        }
    }

    /// The config `startShaping` hands to `beginShaping` — `nil` until the preset's expansion
    /// seeds it. `beginShaping` rather than `choose` so the edited config is what actually runs.
    @State private var editedConfig: RoundConfig?

    private func seedConfig() {
        editedConfig = PresetExpansion.config(for: selectedPreset, available: service.availableModels())
    }

    private func startShaping() {
        guard let config = editedConfig ?? PresetExpansion.config(for: selectedPreset, available: service.availableModels())
        else { return }
        service.beginShaping(intake.id, preset: selectedPreset, config: config)
    }

    /// Chosen before planning rounds existed; the same choice as `.awaitingChoice` resumes it.
    private var parkedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Parked before planning rounds existed — choose a fidelity to continue.").foregroundStyle(.secondary)
            awaitingChoiceBody
        }
    }

    private var shapingBody: some View {
        ShapingView(intake: intake, tape: service.tapes[intake.id] ?? .empty,
                    loadFile: { [service, id = intake.id] checkpoint, path in
                        service.checkpointFile(id, checkpoint: checkpoint, path)
                    },
                    onSend: { [service, id = intake.id] command in service.send(id, command) })
    }

    private var reviewBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            // A refused release comes back here with its reason — without this line the only
            // trace of the refusal was the sheet having closed.
            if let failure = intake.failure {
                Text(failure).foregroundStyle(.orange)
            }
            Text("The change set is ready. Review what will be written before releasing it.")
                .foregroundStyle(.secondary)
        }
    }

    private var releasingBody: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Releasing…")
        }
        .foregroundStyle(.secondary)
    }

    private var releasedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let record = intake.release {
                Text("\(record.appliedSteps) step\(record.appliedSteps == 1 ? "" : "s") applied")
                if let error = record.error {
                    Text(error).foregroundStyle(.orange)
                }
                if !record.warnings.isEmpty {
                    DisclosureGroup("Delivery warnings (\(record.warnings.count))") {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(record.warnings, id: \.self) { warning in
                                Text(warning).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }

    private var failedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let failure = intake.failure {
                Text(failure).foregroundStyle(.orange)
            }
            if let raw = intake.rawFailureOutput {
                DisclosureGroup("Raw output") {
                    ScrollView {
                        Text(raw)
                            .font(.caption.monospaced())
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 200)
                }
            }
        }
    }

    // MARK: - Answered rounds

    /// Every answered exchange, in every state that has one, as a collapsed section — so the
    /// Q&A that shaped a recommendation, a plan or a review can be read back from there.
    @ViewBuilder
    private var clarifications: some View {
        let answered = intake.exchanges.indices.filter { intake.exchanges[$0].answers != nil }
        if !answered.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Clarifications").font(.headline)
                GroupedRows(count: answered.count) { n in
                    let index = answered[n]
                    DisclosureGroup(isExpanded: roundExpansion(index)) {
                        answeredRound(intake.exchanges[index])
                            .padding(.top, 8)
                    } label: {
                        Text(Self.roundLabel(index: index, exchange: intake.exchanges[index]))
                    }
                }
            }
        }
    }

    private func answeredRound(_ exchange: TriageExchange) -> some View {
        let answers = exchange.answers ?? []
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(exchange.questions.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 3) {
                    Text(exchange.questions[i])
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(i < answers.count ? answers[i] : "—")
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.leading, 18)
    }

    private func roundExpansion(_ index: Int) -> Binding<Bool> {
        Binding(
            get: { expandedRounds.contains(index) },
            set: { open in
                if open { expandedRounds.insert(index) } else { expandedRounds.remove(index) }
            }
        )
    }

    /// "Round 1 · 3 questions" — numbered by position in `exchanges`, so a round keeps its
    /// number whichever state the intake is reviewed from.
    static func roundLabel(index: Int, exchange: TriageExchange) -> String {
        let n = exchange.questions.count
        return "Round \(index + 1) · \(n) question\(n == 1 ? "" : "s")"
    }

    // MARK: - Action bar

    /// macOS HIG button placement: the destructive Discard alone on the leading edge, where it
    /// can't be hit in place of the primary; the primary on the trailing edge as the default
    /// button. "Dismiss" (released intakes) is not destructive, so it sits trailing with no
    /// confirmation. Every state has a way off the list except `.releasing`, which
    /// `IntakeService.discard` refuses (beads half-written, no record yet). Before that an
    /// intake stuck at a question, a choice or the review had no exit, and a
    /// `.partiallyReleased` one — which counts as needing attention — kept its project's
    /// orange badge lit forever.
    private var actionBar: some View {
        let close = Self.closeAction(for: intake.state)
        return HStack(spacing: 8) {
            if close == "Discard" {
                Button("Discard", role: .destructive) { confirmingDiscard = true }
                    .accessibilityIdentifier("intake-discard")
            }
            Spacer()
            if close == "Dismiss" {
                Button("Dismiss") { service.discard(intake.id) }
            }
            if let title = Self.primaryAction(for: intake.state, preset: selectedPreset) {
                primaryButton(title)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .confirmationDialog("Discard this intake?", isPresented: $confirmingDiscard, titleVisibility: .visible) {
            Button("Discard", role: .destructive) { service.discard(intake.id) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It leaves the list. Nothing already written to tasks is undone.")
        }
    }

    /// Send Answers takes ⌘↩ rather than `.defaultAction`: the answers are multi-line fields,
    /// and Return belongs to the text being typed, not to sending half of it.
    @ViewBuilder
    private func primaryButton(_ title: String) -> some View {
        let button = Button(title) { performPrimary() }
            .buttonStyle(.borderedProminent)
            .accessibilityIdentifier("intake-primary-action")
        if intake.state == .needsAnswers {
            button
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!Self.canSendAnswers(answers))
        } else {
            button.keyboardShortcut(.defaultAction)
        }
    }

    private func performPrimary() {
        switch intake.state {
        case .needsAnswers:
            guard Self.canSendAnswers(answers) else { return }
            service.answer(intake.id, answers: answers)
        case .awaitingChoice, .parked:
            if selectedPreset == .bead { service.choose(intake.id, preset: .bead) } else { startShaping() }
        case .review: onOpenReview()
        case .failed, .interrupted: service.retry(intake.id)
        case .triaging, .shaping, .releasing, .released, .partiallyReleased, .discarded: break
        }
    }

    /// The trailing, default action per state, title-cased per the HIG. Nil where the state
    /// has nothing to press: triage and release are running, and shaping has its own transport.
    static func primaryAction(for state: IntakeState, preset: Preset) -> String? {
        switch state {
        case .needsAnswers: "Send Answers"
        case .awaitingChoice, .parked: preset == .bead ? "Continue" : "Start Planning"
        case .review: "Open Release Review"
        case .failed, .interrupted: "Retry"
        case .triaging, .shaping, .releasing, .released, .partiallyReleased, .discarded: nil
        }
    }

    /// "Dismiss" once released: nothing is thrown away — `discard` only hides the intake, its
    /// `ReleaseRecord` stays in `intake.json` — so "Discard" would misdescribe it. Nil for
    /// `.releasing` (see `actionBar`) and `.discarded` (never listed).
    static func closeAction(for state: IntakeState) -> String? {
        switch state {
        case .triaging, .needsAnswers, .awaitingChoice, .shaping, .parked, .review, .failed, .interrupted: "Discard"
        case .released, .partiallyReleased: "Dismiss"
        case .releasing, .discarded: nil
        }
    }

    private static let allPresets: [Preset] = [.bead, .sketch, .featurePlan, .fullPlan]
}

/// A macOS grouped-form section without `Form`: `Form(.grouped)` is its own scroll view, and
/// nested inside the pane's ScrollView it collapses to no height. Rows sit in one rounded,
/// faintly filled box with inset separators, the way System Settings draws a section.
private struct GroupedRows<Row: View>: View {
    let count: Int
    @ViewBuilder let row: (Int) -> Row

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(0..<count, id: \.self) { i in
                if i > 0 { Divider().padding(.leading, 12) }
                row(i)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.quinary, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.separator))
    }
}
