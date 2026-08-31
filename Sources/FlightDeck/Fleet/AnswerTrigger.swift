import FleetKit
import Foundation

/// The answer drive, reachable from a shell.
///
/// **It exists because diagnosing the drive cost a human a handset.** An answer only ever
/// arrived from a paired iPhone, so every attempt to reproduce a failed drive — and the
/// `AnswerAbort` record it writes — needed somebody to pick up a phone, find the tab and tap
/// a row. That made the diagnostics added for exactly this failure nearly unusable. This turns
/// one round trip on a handset into one line in a terminal.
///
/// **It is `PromptService` all the way down, and that is the whole point.** A trigger that
/// typed keys itself, or that called `SessionStore.answerPrompt` with a hand-built
/// `OpenPrompt`, would exercise none of what fails: the re-derivation, the call-id comparison,
/// the store's own gauntlet, `AnswerPlan` and `ChoiceDialog`'s interlock. Every operation here
/// goes through the same service `FleetService`'s `.answerPrompt` arm calls, with the same
/// arguments in the same order, so what a shell drives and what a phone drives are one path.
///
/// **Off unless someone turned it on.** Anything that can reach this socket can press Return
/// in the developer's terminal, so it is gated on `FlightDeckAnswerTrigger` (see `isEnabled`)
/// and nothing opens a socket in a shipped launch. The gate is a `UserDefaults` flag rather
/// than a `#if DEBUG` for the reason `answerAbortSink` is a seam rather than a conditional:
/// the failure being chased reproduces only on the installed **Release** build, so a
/// debug-only entry point would not reach it.
@MainActor
final class AnswerTrigger {
    /// `defaults write dev.flightdeck.FlightDeck FlightDeckAnswerTrigger -bool YES`, then
    /// relaunch. Read once, at launch, so turning it off is a relaunch too — a socket that
    /// could appear and vanish under a running app would be a second lifetime to reason about
    /// for no gain.
    static let defaultsKey = "FlightDeckAnswerTrigger"

    /// The `defaults` parameter is what lets a test ask this of its own suite instead of the
    /// developer's real domain — the same arrangement `FlightDeckApp.stateDirectory(_:)` has,
    /// and for the same reason.
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: Self.defaultsKey)
    }

    private let store: SessionStore
    /// Not private: `AnswerTriggerTests` substitutes its `tail` seam, which is the same seam
    /// `PromptServiceTests` substitutes and the only way to put a transcript in front of this
    /// without writing one to disk.
    let prompts: PromptService

    /// Where the abort log ends right now. A seam so a test can pin the cursor without a file,
    /// and the production value is the length of `AnswerAbortLog.fileURL`.
    var answerLogLength: () -> Int = AnswerTrigger.answerLogLength

    init(store: SessionStore) {
        self.store = store
        self.prompts = PromptService(store: store)
    }

    /// One request line in, one response line out. Never throws and never traps: this runs on
    /// the main actor with a socket on the other end, and a malformed line is a caller's
    /// mistake, not a reason to take the app down.
    func handle(_ line: String) -> String {
        guard let data = line.data(using: .utf8),
              let request = try? JSONDecoder().decode(Request.self, from: data)
        else {
            return encode(.failure(
                op: nil, error: "bad_request",
                detail: "expected one line of JSON: {\"op\":\"list\"} or "
                    + "{\"op\":\"answer\",\"session\":\"<uuid>\",\"selections\":[[0,1]]}"
            ))
        }
        switch request.op {
        case .list: return encode(list())
        case .answer: return encode(answer(request))
        }
    }

    // MARK: - list

    /// Every tab with a dialog up, described well enough to answer one without seeing a screen.
    ///
    /// Derived per tab through `PromptService.openPrompt(inSession:)` rather than from a
    /// snapshot, so the listing and the answer that follows it ask the same question of the
    /// same transcript. Tabs it refuses are omitted rather than reported: a listing is a menu
    /// of what can be answered, and "this tab is idle" is every tab most of the time.
    private func list() -> Response {
        let open = store.repos.flatMap { repo in
            repo.sessions.compactMap { session -> Response.OpenSession? in
                guard case .success(let prompt) = prompts.openPrompt(inSession: session.id)
                else { return nil }
                return Response.OpenSession(prompt, session: session, project: repo.displayName)
            }
        }
        return Response(ok: true, op: "list", sessions: open)
    }

    // MARK: - answer

    /// Answer one tab's set of questions by index — `[[0, 1], [2]]` is "question 0 takes
    /// options 0 and 1, question 1 takes option 2".
    ///
    /// **The labels are filled in from this Mac's own derivation, and that is a real gap.**
    /// `PromptAnswer.answers` carries a label beside every index so the Mac can refuse a phone
    /// whose copy of the transcript disagrees with its own. A caller here has no independent
    /// copy to disagree with — it read the labels out of `list`, which read them out of the
    /// same transcript a moment earlier — so that cross-check passes by construction and this
    /// path does not exercise it. Everything after it is identical to the phone's.
    ///
    /// `call` is optional. Supplied, it is compared exactly as a phone's is, and a tab that has
    /// moved on answers `prompt_changed`. Omitted, this answers whatever is open right now,
    /// which is what a script driving its own session wants and is the one check a shell gives
    /// up by not being a phone.
    private func answer(_ request: Request) -> Response {
        guard let session = request.session else {
            return .failure(op: "answer", error: "missing_session",
                            detail: "answer needs a session id — run list first")
        }
        guard let selections = request.selections else {
            return .failure(op: "answer", error: "missing_selections",
                            detail: "answer needs selections, e.g. [[0,1],[2]]")
        }
        // Derived once. A second call would read the transcript again and could legitimately
        // return a different dialog, which is the one thing this must not answer against.
        let derived = prompts.openPrompt(inSession: session)
        guard case .success(let open) = derived else {
            guard case .failure(let code) = derived else {
                return .failure(op: "answer", error: "prompt_changed", detail: nil)
            }
            return .failure(op: "answer", error: code.code, detail: nil)
        }
        // A permission dialog has no options to index into — `SessionStore.answerPrompt` says
        // so too, as `unreadable_screen`. Said plainly here because the caller chose `list`'s
        // output and deserves to know it named the wrong kind of dialog.
        guard case .question(let call, let questions) = open else {
            return .failure(op: "answer", error: "not_a_question",
                            detail: "this tab is blocked on a permission dialog, "
                                + "which has no options to select")
        }
        if let named = request.call, named != call {
            return .failure(op: "answer", error: "prompt_changed", detail: nil)
        }

        // **Only what has no label is refused here.** Naming question 5 of two, or option 9 of
        // four, leaves nothing to put in the `AnswerSelection` — there is no label to send —
        // so those are the caller's typos and are named as such. A set that is merely SHORT
        // still labels cleanly, and it is passed through untouched: `answerPrompt` refuses a
        // count that disagrees with the questions as `unreadable_screen`, and reproducing that
        // refusal from a shell is one of the things this exists for.
        var picked: [[AnswerSelection]] = []
        for (number, chosen) in selections.enumerated() {
            guard questions.indices.contains(number) else {
                return .failure(op: "answer", error: "bad_selection",
                                detail: "there is no question \(number)")
            }
            let question = questions[number]
            var row: [AnswerSelection] = []
            for index in chosen {
                guard question.options.indices.contains(index) else {
                    return .failure(
                        op: "answer", error: "bad_selection",
                        detail: "question \(number) has no option \(index)"
                    )
                }
                row.append(AnswerSelection(index: index, label: question.options[index].label))
            }
            picked.append(row)
        }

        // Read before the drive starts, never after: a drive aborts across `injectionSettle`,
        // long after this reply has gone, so the reply cannot carry the abort — only a cursor
        // past every record that was already there. `tail -c +$((offset + 1))` reads exactly
        // what this answer wrote.
        let cursor = answerLogLength()
        let result = prompts.answer(
            session: session, call: call, answer: .answers(picked), token: UUID()
        )
        if case .failure(let code) = result {
            return .failure(op: "answer", error: code.code, detail: nil)
        }
        return Response(
            ok: true, op: "answer", result: "dispatched", session: session, call: call,
            abortLog: Response.AbortLog(path: AnswerAbortLog.fileURL.path, offset: cursor)
        )
    }

    /// The length of the abort log, or 0 when there is not one yet. Every failure reads as
    /// zero: a cursor that cannot be taken is better given as "read the whole file" than as a
    /// refusal to answer at all.
    static func answerLogLength() -> Int {
        let attributes = try? FileManager.default.attributesOfItem(
            atPath: AnswerAbortLog.fileURL.path
        )
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    private func encode(_ response: Response) -> String {
        let encoder = JSONEncoder()
        // Paths are the point of half these fields, and `\/` in every one of them is noise a
        // reader has to undo. `sortedKeys` because `JSONEncoder` otherwise emits a keyed
        // container in hash order — not declaration order — so without it the same reply comes
        // back with its fields shuffled between runs, and two outputs cannot be diffed.
        encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
        guard let data = try? encoder.encode(response),
              let text = String(data: data, encoding: .utf8)
        else { return #"{"ok":false,"error":"encoding_failed"}"# }
        return text
    }
}

extension AnswerTrigger {
    /// What a shell asks for. Two operations and four fields, all optional but `op`, so a
    /// caller writes the shortest line that says what it means.
    struct Request: Decodable {
        enum Op: String, Decodable {
            case list
            case answer
        }

        let op: Op
        let session: UUID?
        /// The call id from `list`. See `answer(_:)` for what omitting it gives up.
        let call: String?
        /// One array per question, in the order the questions are asked, each holding the
        /// option indices chosen for it.
        let selections: [[Int]]?
    }

    /// One envelope for both operations, with every field that does not apply left out.
    ///
    /// A single shape rather than one type per operation because the caller is a script: `.ok`
    /// is always there to branch on and `.error` is always where a refusal is, whichever
    /// operation produced it.
    struct Response: Encodable {
        var ok: Bool
        var op: String?
        var error: String?
        var detail: String?
        var sessions: [OpenSession]?
        var result: String?
        var session: UUID?
        var call: String?
        var abortLog: AbortLog?

        static func failure(op: String?, error: String, detail: String?) -> Response {
            Response(ok: false, op: op, error: error, detail: detail)
        }

        /// Where this answer's abort record will land, if it aborts. See `AnswerAbortLog`.
        struct AbortLog: Encodable {
            let path: String
            let offset: Int
        }

        struct OpenSession: Encodable {
            let session: UUID
            let title: String
            let project: String
            let agent: String
            let call: String
            /// `question` or `permission` — the two `OpenPrompt` cases, so a caller can tell
            /// a set it can answer from a dialog it cannot.
            let kind: String
            let tool: String?
            let summary: String?
            let questions: [Question]?

            struct Question: Encodable {
                /// The question's position in the set, which is the index its selections go at.
                let index: Int
                let header: String?
                let question: String
                let multiSelect: Bool
                let unanswerable: String?
                let options: [Option]
            }

            struct Option: Encodable {
                let index: Int
                let label: String
                let detail: String?
            }

            init(_ prompt: OpenPrompt, session: Session, project: String) {
                self.session = session.id
                self.title = session.title
                self.project = project
                self.agent = session.agent.rawValue
                self.call = prompt.callID
                switch prompt {
                case .question(_, let questions):
                    self.kind = "question"
                    self.tool = nil
                    self.summary = nil
                    self.questions = questions.enumerated().map { number, question in
                        Question(
                            index: number,
                            header: question.header,
                            question: question.question,
                            multiSelect: question.multiSelect,
                            unanswerable: question.unanswerable,
                            options: question.options.enumerated().map {
                                Option(index: $0, label: $1.label, detail: $1.detail)
                            }
                        )
                    }
                case .permission(_, let tool, let summary):
                    self.kind = "permission"
                    self.tool = tool
                    self.summary = summary
                    self.questions = nil
                }
            }
        }
    }
}
