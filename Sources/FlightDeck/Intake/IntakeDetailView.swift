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
    /// questions. Reset via `.task(id:)` below whenever the question set changes — the
    /// same `IntakeDetailView` instance lives across a `needsAnswers` → `triaging` →
    /// `needsAnswers` round trip (selection doesn't change), so a plain `@State` seeded
    /// once at init would still hold the previous round's drafts.
    @State private var answers: [String] = []
    @State private var selectedPreset: Preset = .bead

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                IntakeStatePill(intake: intake, tape: service.tapes[intake.id])
                Text(intake.intent)
                Divider()
                content
                closeButton
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
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

    private var needsAnswersBody: some View {
        let questions = intake.exchanges.last?.questions ?? []
        return VStack(alignment: .leading, spacing: 12) {
            ForEach(questions.indices, id: \.self) { i in
                VStack(alignment: .leading, spacing: 4) {
                    Text(questions[i]).font(.callout)
                    TextField("Answer", text: answerBinding(i))
                        .textFieldStyle(.roundedBorder)
                }
            }
            Button("Send answers") { service.answer(intake.id, answers: answers) }
                .disabled(!Self.canSendAnswers(answers))
        }
        // Keyed on the questions' CONTENTS (and the intake): a follow-up round with the same
        // number of questions used to keep the previous round's answers typed into the new
        // questions' fields, ready to send against questions they never answered.
        .task(id: [intake.id.uuidString] + questions) {
            answers = Array(repeating: "", count: questions.count)
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
                Text("Recommended: \(Self.presetLabel(recommended))").font(.callout.weight(.semibold))
            }
            if let reason = intake.recommendationReason {
                Text(reason).foregroundStyle(.secondary)
            }
            Picker("Fidelity", selection: $selectedPreset) {
                ForEach(Self.allPresets, id: \.self) { preset in
                    Text(Self.presetLabel(preset)).tag(preset)
                }
            }
            .pickerStyle(.menu)
            if selectedPreset == .bead {
                Button("Continue") { service.choose(intake.id, preset: .bead) }
            } else {
                roundsEditor
                Button("Start") { startShaping() }
            }
        }
        .task(id: intake.id) { selectedPreset = intake.recommended ?? .bead; seedConfig() }
        .onChange(of: selectedPreset) { seedConfig() }
    }

    /// The Rounds disclosure: the selected preset's expansion, editable before Start. Re-seeded
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
            Button("Open release review", action: onOpenReview)
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
            Button("Retry") { service.retry(intake.id) }
        }
    }

    /// Every state has a way off the list except `.releasing`, which `IntakeService.discard`
    /// refuses (beads half-written, no record yet). Before this an intake stuck at a question,
    /// a choice or the review had no exit, and a `.partiallyReleased` one — which counts as
    /// needing attention — kept its project's orange badge lit forever.
    @ViewBuilder
    private var closeButton: some View {
        if let label = Self.closeAction(for: intake.state) {
            Button(label, role: label == "Discard" ? .destructive : nil) { service.discard(intake.id) }
        }
    }

    /// "Dismiss" once released: nothing is thrown away — `discard` only hides the intake, its
    /// `ReleaseRecord` stays in `intake.json` — so "Discard" would misdescribe it. Nil for
    /// `.releasing` (see `closeButton`) and `.discarded` (never listed).
    static func closeAction(for state: IntakeState) -> String? {
        switch state {
        case .triaging, .needsAnswers, .awaitingChoice, .shaping, .parked, .review, .failed, .interrupted: "Discard"
        case .released, .partiallyReleased: "Dismiss"
        case .releasing, .discarded: nil
        }
    }

    private static let allPresets: [Preset] = [.bead, .sketch, .featurePlan, .fullPlan]

    private static func presetLabel(_ preset: Preset) -> String {
        switch preset {
        case .bead: return "Bead"
        case .sketch: return "Sketch"
        case .featurePlan: return "Feature plan"
        case .fullPlan: return "Full plan"
        }
    }
}
