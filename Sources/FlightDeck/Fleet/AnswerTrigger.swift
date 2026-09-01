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

    /// How the `logs` op reaches the attached phones.
    ///
    /// A seam rather than a stored `FleetService`, on the same reasoning `answerLogLength` is
    /// one: the trigger is constructed from a `SessionStore` and the service is built by
    /// `FlightDeckApp` on an independent path, so there is no construction-time hook to inject
    /// through — and a test needs to present phones that are attached, refuse, or never answer
    /// without a socket, a pairing and a real handset. Production resolves `FleetService`'s own
    /// `current` seam, which is exactly what `AppDelegate` does for the search index.
    var phones: (any PhoneLogFetching)? = FleetService.current

    /// Where a fetched log is appended. A seam for the same reason: the production value writes
    /// to the developer's real `~/Library/Logs/flight-deck-phone.log`, which a test must not.
    var appendPhoneLogs: (WirePhoneLogs, String?) -> Void = {
        PhoneLogFile.append($0, device: $1)
    }

    init(store: SessionStore) {
        self.store = store
        self.prompts = PromptService(store: store)
    }

    /// One request line in, one response line out. Never throws and never traps: this runs on
    /// the main actor with a socket on the other end, and a malformed line is a caller's
    /// mistake, not a reason to take the app down.
    ///
    /// **A completion rather than a return value, and `logs` is why.** `list` and `answer` are
    /// answered from state this actor already holds, and both still complete before this call
    /// returns. `logs` cannot: it puts a frame on a phone's socket and waits for the phone, so
    /// a synchronous shape would either block the main actor on a network round trip or need a
    /// second, differently-shaped entry point for one operation. One shape that some callers
    /// satisfy immediately beats two shapes a reader has to keep apart.
    func handle(_ line: String, then reply: @escaping (String) -> Void) {
        guard let data = line.data(using: .utf8),
              let request = try? JSONDecoder().decode(Request.self, from: data)
        else {
            return reply(encode(.failure(
                op: nil, error: "bad_request",
                detail: "expected one line of JSON: {\"op\":\"list\"}, "
                    + "{\"op\":\"answer\",\"session\":\"<uuid>\",\"selections\":[[0,1]]} "
                    + "or {\"op\":\"logs\"}"
            )))
        }
        switch request.op {
        case .list: reply(encode(list()))
        case .answer: reply(encode(answer(request)))
        case .logs: logs(request) { reply(self.encode($0)) }
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

    // MARK: - logs

    /// Pull every attached phone's own log to this Mac and append it to
    /// `~/Library/Logs/flight-deck-phone.log`.
    ///
    /// **Behind this gate rather than a new one.** Anything that can reach this socket can
    /// already press Return in the developer's terminal; reading a paired phone's diagnostics
    /// is strictly less than that, and a second flag would be a second thing to remember to
    /// turn off.
    ///
    /// **Every attached phone, not one named by the caller.** The question this answers is
    /// "what did my phone see", and the overwhelmingly common fleet is one handset — so making
    /// the caller first list devices, then name one, would be two round trips to save nothing.
    /// Two phones each get their own block in the file and their own row in the reply.
    ///
    /// **`ok` is true when at least one phone answered.** All-refused and none-attached are
    /// both `ok: false`, because either way there is nothing new in the file — and a script
    /// that branched on `ok` would otherwise report success for a fetch that returned nothing.
    /// Which of the two it was is in `error`, and every phone's own outcome is in `devices`.
    private func logs(_ request: Request, then reply: @escaping (Response) -> Void) {
        let seconds = min(
            max(request.seconds ?? PhoneLogLimits.defaultSeconds, 1), PhoneLogLimits.maxSeconds
        )
        guard let phones else {
            return reply(.failure(op: "logs", error: "stopped",
                                  detail: "the fleet service is not running"))
        }
        let clients = phones.attachedClients
        guard !clients.isEmpty else {
            return reply(.failure(
                op: "logs", error: "no_phones",
                detail: "no paired phone is attached — open the app on your phone and retry"
            ))
        }

        // Fanned out rather than run in series, and the ordering is settled by the counter
        // below rather than by the order the answers land: two phones on the same LAN answer
        // in whatever order their radios wake up, and serialising them would make the whole
        // fetch as slow as the slowest handset for no gain.
        var rows: [Response.PhoneLogs] = []
        var outstanding = clients.count
        for client in clients {
            phones.fetchPhoneLogs(
                from: client.id, seconds: seconds, limit: PhoneLogLimits.maxEntries
            ) { [weak self] result in
                switch result {
                case .success(let logs):
                    // Written before the row is recorded, so a reply claiming N entries is one
                    // whose N entries are already in the file.
                    self?.appendPhoneLogs(logs, client.name)
                    rows.append(Response.PhoneLogs(
                        device: client.name, entries: logs.entries.count,
                        truncated: logs.truncated, error: nil
                    ))
                case .failure(let error):
                    rows.append(Response.PhoneLogs(
                        device: client.name, entries: nil, truncated: nil,
                        error: Self.describe(error)
                    ))
                }
                outstanding -= 1
                guard outstanding == 0 else { return }
                let total = rows.compactMap(\.entries).reduce(0, +)
                let answered = rows.contains { $0.error == nil }
                reply(Response(
                    ok: answered, op: "logs",
                    // Named only when nothing came back: a partial fetch is a success with one
                    // bad row in it, and putting a top-level error on that would have a script
                    // discard a file it should be reading.
                    error: answered ? nil : "no_logs",
                    path: PhoneLogFile.fileURL.path, seconds: seconds, entries: total,
                    devices: rows
                ))
            }
        }
    }

    /// The refusal a caller sees, in the phone's own vocabulary where there is one.
    ///
    /// `FleetRequestError.server`'s code is carried through verbatim rather than mapped: this
    /// build produces `unsupported_peer` (a phone too old to be asked — see `FleetCapability`),
    /// `timed_out`, `unhandled` and `unreadable`, and a newer phone may invent more. A caller
    /// must treat an unrecognised code as "no logs from that phone".
    private static func describe(_ error: FleetRequestError) -> String {
        switch error {
        case .disconnected: return "disconnected"
        case .server(let code): return code
        }
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
            case logs
        }

        let op: Op
        let session: UUID?
        /// The call id from `list`. See `answer(_:)` for what omitting it gives up.
        let call: String?
        /// One array per question, in the order the questions are asked, each holding the
        /// option indices chosen for it.
        let selections: [[Int]]?
        /// How far back `logs` reaches, in seconds. `nil` is `PhoneLogLimits.defaultSeconds`;
        /// anything past `maxSeconds` is clamped rather than refused, the same contract the
        /// phone itself keeps against this Mac.
        let seconds: Int?
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
        /// Where `logs` put what it fetched, and what it fetched. `entries` is the total across
        /// every phone; `devices` breaks it down and is where a single phone's refusal is.
        var path: String?
        var seconds: Int?
        var entries: Int?
        var devices: [PhoneLogs]?

        static func failure(op: String?, error: String, detail: String?) -> Response {
            Response(ok: false, op: op, error: error, detail: detail)
        }

        /// One phone's outcome. `entries` and `error` are mutually exclusive — a phone either
        /// answered or refused — and both are optional so the row carries only the one that
        /// happened rather than a null beside it.
        struct PhoneLogs: Encodable {
            /// What the phone calls itself, which since iOS 16 is usually just "iPhone" — see
            /// `FleetModel.deviceName`. The paired slot is deliberately not here: it is an
            /// internal identifier that would tell a reader nothing this does not.
            let device: String?
            let entries: Int?
            let truncated: Bool?
            let error: String?
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
