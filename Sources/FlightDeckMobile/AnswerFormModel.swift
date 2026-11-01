import FleetKit
import Foundation

/// The open clarifying round as the phone can answer it: present only from a Mac that takes
/// `intake.answer` and while the intake waits for answers.
struct OpenRound: Equatable {
    let round: Int
    let digest: String
    let questions: [WireStructuredQuestion]

    var title: String {
        "Round \(round + 1) · \(questions.count) question\(questions.count == 1 ? "" : "s")"
    }
}

/// Whether the phone shows the answer form, when it reads "Sending…", and when it starts again
/// — decided here, not in `IntakeScreen`, so it can be tested. One per intake (from
/// `FlightControlModel`), so "sent" survives the screen being popped and pushed.
///
/// Everything keys on the round's digest, never its index alone: the Mac's retry clears the
/// exchanges, so a fresh round reuses index 0 with different questions. Keyed by index, the
/// form kept its `@State` answers (option ids the new round lacks) and stayed "Sending…" for a
/// round nobody had answered.
@MainActor
@Observable
final class AnswerFormModel {
    let intake: UUID
    /// The digest of the round whose answers were sent and not yet replaced.
    private(set) var sentDigest: String?
    /// Bumped by a `stale_questions` refusal, so the form starts again from the refreshed round
    /// even before the refresh brings a new digest.
    private(set) var resets = 0
    @ObservationIgnored private let drafts: AnswerDraftStore?

    init(intake: UUID, drafts: AnswerDraftStore? = nil) {
        self.intake = intake
        self.drafts = drafts
    }

    /// nil means no form: the flag is missing or false (an older Mac, which would drop the
    /// socket on `intake.answer`), the intake is not waiting for answers, or there is no round.
    static func openRound(_ d: WireIntakeDetail?) -> OpenRound? {
        guard let d, d.structuredQuestions == true, d.summary.state == "needsAnswers", let q = d.questions,
              let questions = q.structured, !questions.isEmpty, let round = q.round, let digest = q.digest
        else { return nil }
        return OpenRound(round: round, digest: digest, questions: questions)
    }

    /// The form's view identity: a new one drops the form's `@State` answers.
    func identity(_ open: OpenRound) -> String { "\(open.digest)-\(resets)" }

    /// From the press until the Mac moves the round on: after the ack the detail still reads
    /// `needsAnswers` until triage saves, and a live Send then would only be refused stale.
    func sending(_ open: OpenRound, inFlight: Set<IntakeAction>) -> Bool {
        inFlight.contains(.answer(open.digest)) || sentDigest == open.digest
    }

    /// Every new detail. Clears "sent" once its round is no longer the open one — the state
    /// left `needsAnswers` or the digest changed — so a later round that asks the very same
    /// questions is not shown as already sent.
    func observe(_ d: WireIntakeDetail?) {
        if let sent = sentDigest, Self.openRound(d)?.digest != sent { sentDigest = nil }
    }

    /// What the form starts from: this round's kept answers when they fit its questions, else
    /// the recommended options.
    func initialAnswers(_ open: OpenRound) -> [WireStructuredAnswer] {
        if let kept = drafts?.drafts(intake: intake, digest: open.digest),
           kept.map(\.questionID) == open.questions.map(\.id) { return kept }
        return open.questions.map(\.initialAnswer)
    }

    func keep(_ answers: [WireStructuredAnswer], for open: OpenRound) {
        drafts?.save(answers, intake: intake, digest: open.digest)
    }

    /// The kept answers go only on the ack: a send that times out or is refused leaves them for
    /// the next try.
    func send(_ answers: [WireStructuredAnswer], for open: OpenRound, via commands: IntakeCommandModel,
              refresh: @escaping () -> Void) {
        let intake = self.intake, drafts = self.drafts
        sentDigest = open.digest
        commands.send(.answer(open.digest), command: {
            .intakeAnswer(id: intake, token: $0, round: open.round, digest: open.digest, answers: answers)
        }, onAck: {
            drafts?.clear(intake: intake, digest: open.digest)
            refresh()
        }, onFailure: { [weak self] error in
            guard let self else { return }
            if self.sentDigest == open.digest { self.sentDigest = nil }
            if case .server(code: "stale_questions")? = error { self.resets += 1; refresh() }
        })
    }
}
