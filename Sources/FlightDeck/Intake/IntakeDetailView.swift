import IntakeKit
import SwiftUI

/// The right-hand pane of `ProjectView`'s Intakes split, one selected `Intake` at a time.
/// Entirely state-driven off `Intake.state` — see the table in
/// `.superpowers/sdd/2026-09-26-flywheel-intake-phase1-3/task-17-brief.md`.
struct IntakeDetailView: View {
    let service: IntakeService
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
                IntakeStatePill(intake: intake)
                Text(intake.intent)
                Divider()
                content
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
        }
        .task(id: questions) {
            if answers.count != questions.count { answers = Array(repeating: "", count: questions.count) }
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
            // Only `.bead` encodes today — every other preset just parks, so the person
            // choosing it needs to know Continue won't actually start planning yet.
            if selectedPreset != .bead {
                Text("Planning rounds arrive with the round engine").font(.caption).foregroundStyle(.secondary)
            }
            Button("Continue") { service.choose(intake.id, preset: selectedPreset) }
        }
        .task(id: intake.id) { selectedPreset = intake.recommended ?? .bead }
    }

    private var parkedBody: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Parked — planning rounds arrive with the round engine.").foregroundStyle(.secondary)
            Button("Discard", role: .destructive) { service.discard(intake.id) }
        }
    }

    private var reviewBody: some View {
        Button("Open release review", action: onOpenReview)
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
            HStack(spacing: 8) {
                Button("Retry") { service.retry(intake.id) }
                Button("Discard", role: .destructive) { service.discard(intake.id) }
            }
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
