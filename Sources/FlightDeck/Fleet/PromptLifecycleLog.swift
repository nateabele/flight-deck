import FleetKit
import Foundation
import OSLog

/// One thing this Mac decided about the dialog a session is blocked on, and what it told its
/// clients about it.
///
/// **Written because the question could not be answered without a handset.** A phone displayed
/// a permission dialog the Mac no longer had; tapping it came back *"Your Mac has moved on
/// from this"*, and at that same moment `scripts/answer-trigger.sh list` reported no session
/// with an open prompt at all. Nothing recorded either half, so "the Mac never emitted the
/// closure" and "the phone never applied one it was sent" were indistinguishable — and which
/// of those it is decides which machine the repair goes on. Every case below exists to
/// separate them.
///
/// **Observability only.** Nothing in the app reads a record back and no branch anywhere is
/// taken on one. A change here that altered when a frame is sent, or what is in it, would
/// destroy the thing being measured.
struct PromptLifecycleRecord: Equatable {
    /// Which dialog, in the two shapes `OpenPrompt` has.
    ///
    /// Counts, not contents: how many questions a set asks and how many options each carries
    /// is what tells one dialog from another in a log, and the labels themselves are the
    /// user's own text. Those go to the file (see `detail`) and never to os_log.
    enum Kind: Equatable {
        /// An `AskUserQuestion`. One entry per question, holding that question's option count.
        case question(options: [Int])
        /// Any other tool awaiting approval. `nil` for a `tool_use` record naming no tool.
        case permission(tool: String?)
    }

    /// Why a dialog this Mac believed was open stopped being the one it believes is open.
    enum CloseReason: Equatable {
        /// The session's activity left `waiting` — the ordinary end of a dialog, however it
        /// was answered. The new activity is carried because "the agent went back to work"
        /// and "the agent exited" are different endings and only one of them is expected.
        case activity(String?)
        /// Still `waiting`, and the newest unanswered call is a different one: claude answered
        /// one dialog and raised the next without the session ever leaving `waiting`. This is
        /// the race `PromptService`'s re-derivation exists for, and the case where the Mac
        /// never pushes anything at all — the activity did not move, so no `FleetEvent`
        /// describes it.
        case superseded(call: String)
        /// Still `waiting`, and nothing this build can name is on the transcript any more.
        /// **This is the Mac-side signature of the stale-card report**: a phone still holding
        /// a card for a call the Mac can no longer find will be refused, and no frame said so.
        case unnamed(code: String)
        /// The tab is gone.
        case sessionRemoved
    }

    /// What this Mac's own dialog derivation said at the instant a blind Escape was considered.
    ///
    /// **The field the abort escape hatch's whole safety story rests on.** `.answer` carries
    /// `open` so a reader can see what the Mac believed about the call a thumb came down on; an
    /// abort names no call, so without this the log could not answer the one question anyone
    /// will ask of it after the fact — *was this Escape aimed at a genuinely unnameable dialog,
    /// or at one the Mac could have answered properly?* A `.nameable` beside a dispatched abort
    /// would be this feature doing exactly the harm it was built to avoid; a `.nameable` beside
    /// `code=prompt_nameable` is the guard that now prevents it, visible as having fired.
    enum AbortProbe: Equatable {
        /// The probe named a dialog: this Mac could have answered it targetedly.
        case nameable
        /// The probe refused, with this code — nothing here can name the dialog, which is the
        /// only state a blind Escape exists for.
        case unnameable(code: String)
        /// No probe was installed. A bare `SessionStore` in a test, and never production —
        /// `FleetService.init` always installs one. Distinct from `.unnameable` on purpose: an
        /// absent derivation is not a derivation that came back empty.
        case unavailable
    }

    /// What an outbound frame says about whether a dialog is up.
    enum Assertion: String, Equatable {
        /// `activity == waiting`: the phone will draw a card.
        case open
        /// Anything else, and a removal.
        case absent
    }

    enum Event: Equatable {
        /// A dialog this Mac can name went up.
        case opened(call: String, agent: String?, kind: Kind)
        case closed(call: String, reason: CloseReason)
        /// The session is `waiting` and this Mac cannot say which dialog that is — the state
        /// in which a phone draws "Waiting for you" with no controls under it, and in which
        /// every tap it could make is refused. `code` is `PromptService`'s own refusal.
        case unnamed(code: String)
        /// One outbound push, and what it asserts. `clients` is the whole point: a closure
        /// nobody was attached to receive is not the same failure as one that went out and
        /// was ignored.
        case pushed(asserts: Assertion, activity: String?, clients: Int)
        /// What a reattaching client was handed. A phone that was away across the close gets
        /// its prompt state from here and nowhere else, so a stale card survives exactly as
        /// long as this frame is wrong. `clients` counts every attachment including the one
        /// just made, which is what makes a phone reconnecting on top of a socket that never
        /// dropped visible as the two connections it is.
        case resumed(lastSeq: Int, mode: String, frames: Int, waiting: Int, clients: Int)
        /// An inbound answer, decided before any key was pressed.
        ///
        /// **The single most valuable line in this log.** `sent` is the call the client had on
        /// screen when a thumb came down; `open` is the call this Mac believes is up right
        /// now, or `nil` when it believes none is. Side by side they say which machine was
        /// wrong. `code` is `nil` for an answer that was accepted.
        case answer(sent: String, open: String?, code: String?)
        /// A dialog this Mac still cannot name, seconds after it first could not — and again
        /// later, while that is still true.
        ///
        /// **A second or so of `unnamed` is ordinary** — claude writes its status file and its
        /// transcript by independent paths, so `waiting` routinely arrives first and the very
        /// next poll names the call (16:37:57 `unnamed` → 16:37:58 `opened`). This case is the
        /// state that is NOT that: still blocked, still unnameable, and now worth a person's
        /// attention. It carries the two paths side by side because which of them is wrong is
        /// the whole question — `pathMatches == false` is this Mac reading a file `claude`
        /// left, and `pathMatches == true` with a stale `lastRecordAgeMs` is a record that was
        /// never written, which is upstream and not ours.
        ///
        /// **Read the ages against the record's own age in the episode.** The first record of an
        /// episode is written seconds in, when `fileAgeMs` and `lastRecordAgeMs` are young by
        /// construction and cannot separate a stall from a race that is about to resolve; the
        /// later ones are where a `lastRecordAgeMs` growing in step with the wall clock says the
        /// record is not coming. `SessionStore.stuckPromptReportLadder` is the schedule, and why.
        case stuck(
            code: String, watched: String?, registryCWD: String?, pathMatches: Bool,
            fileAgeMS: Int?, lastRecordAgeMS: Int?, tailRecords: Int
        )
        /// An Escape sent at a dialog nothing could name. A sibling of `answer`, not a reuse of
        /// it: `answer` carries `sent` and `open` so a reader can see which machine was wrong
        /// about *which call*, and an abort names no call on either side. Forcing a sentinel
        /// through those fields would make "no call id by construction" read as a truncated line.
        ///
        /// `sent` is whether a key was actually typed, and it is **not** derivable from `code`:
        /// a dispatch and a replayed token both report no error, so a `code`-only record could
        /// not count the Escapes this Mac really sent. `probe` is what this Mac believed about
        /// the dialog at that instant — see `AbortProbe`, which is where the reason lives.
        case aborted(code: String?, sent: Bool, probe: AbortProbe)
    }

    /// `nil` only for `resumed`, which is about a connection rather than a session.
    let session: UUID?
    let event: Event
    /// Detail worth keeping but not worth putting in the unified log — the option labels and
    /// the tool summary, which are the user's own text and the reason this has a file at all.
    let detail: String?

    init(session: UUID?, event: Event, detail: String? = nil) {
        self.session = session
        self.event = event
        self.detail = detail
    }

    /// The one-line form. Short deliberately: os_log truncates, and every field here has to
    /// survive that — which is why `detail` is not part of it.
    var summary: String {
        "prompt session=\(session?.uuidString ?? "-") \(body)"
    }

    private var body: String {
        switch event {
        case .opened(let call, let agent, .question(let options)):
            return "opened call=\(call) agent=\(agent ?? "-") kind=question"
                + " questions=\(options.count)"
                + " options=\(options.map(String.init).joined(separator: ","))"
        case .opened(let call, let agent, .permission(let tool)):
            return "opened call=\(call) agent=\(agent ?? "-") kind=permission"
                + " tool=\(tool ?? "-")"
        case .closed(let call, let reason):
            return "closed call=\(call) reason=\(Self.describe(reason))"
        case .unnamed(let code):
            return "unnamed code=\(code)"
        case .pushed(let asserts, let activity, let clients):
            return "push asserts=\(asserts.rawValue) activity=\(activity ?? "-")"
                + " clients=\(clients)"
        case .resumed(let lastSeq, let mode, let frames, let waiting, let clients):
            return "resume lastSeq=\(lastSeq) mode=\(mode) frames=\(frames)"
                + " waiting=\(waiting) clients=\(clients)"
        case .answer(let sent, let open, let code):
            // `sent` before `open`, always, and both always present: a reader scanning this
            // file for the stale-card report is comparing exactly these two strings, and one
            // of them being omitted when it is absent would make "the Mac had nothing open"
            // look like a truncated line.
            return "answer sent=\(sent) open=\(open ?? "none") code=\(code ?? "ok")"
        case .stuck(let code, let watched, let registryCWD, let matches,
                    let fileAge, let recordAge, let tail):
            return "stuck code=\(code) pathMatches=\(matches)"
                + " watched=\(watched ?? "-") registryCwd=\(registryCWD ?? "-")"
                + " fileAgeMs=\(fileAge.map(String.init) ?? "-")"
                + " lastRecordAgeMs=\(recordAge.map(String.init) ?? "-")"
                + " tailRecords=\(tail)"
        case .aborted(let code, let sent, let probe):
            return "abort code=\(code ?? "ok") sent=\(sent) probe=\(Self.describe(probe))"
        }
    }

    private static func describe(_ probe: AbortProbe) -> String {
        switch probe {
        case .nameable: return "nameable"
        case .unnameable(let code): return "unnameable-\(code)"
        case .unavailable: return "-"
        }
    }

    private static func describe(_ reason: CloseReason) -> String {
        switch reason {
        case .activity(let activity): return "activity-\(activity ?? "none")"
        case .superseded(let call): return "superseded-by-\(call)"
        case .unnamed(let code): return "unnamed-\(code)"
        case .sessionRemoved: return "session-removed"
        }
    }
}

/// Puts a `PromptLifecycleRecord` in the two places it can be read after the fact.
///
/// The same two channels, for the same reasons, as `AnswerAbortLog` — read that type first;
/// this is its counterpart for the half of the story that happens before any key is pressed.
/// The unified log is where a person already looks and where the other half of a failed answer
/// already is, so the summaries correlate by eye; the file is what survives the unified log's
/// ring buffer rolling over, which matters here because the interesting question is asked
/// hours after the transition it is about.
///
/// Unconditional: not `#if DEBUG`, not behind `FlightDeckAnswerTrigger` — that flag guards a
/// control surface and this is only observation — and not behind a preference. The failure
/// this exists for reproduces only on the installed Release build, and these transitions are
/// rare enough that always writing one costs nothing worth measuring: one line per dialog, not
/// one per poll.
enum PromptLifecycleLog {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "dev.flightdeck.FlightDeck",
        category: "prompt"
    )

    /// Beside `flight-deck-answer.log`, for the reason that one is not in a container: this
    /// build is unsandboxed and a path a human can type is the whole point.
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/flight-deck-prompt.log")

    /// `notice`, not `info` and not `error`.
    ///
    /// **`info` was tried and is unusable here**: os_log keeps `info` in a memory ring and does
    /// not persist it, so `log show` finds nothing minutes later — and "minutes later" is the
    /// only time anyone asks this log a question. `notice` is the default level and is written
    /// to disk. `error`, which `AnswerAbortLog` correctly uses, would be a lie: an abort is a
    /// failure and a dialog opening is not, and levelling ordinary traffic as an error makes
    /// the level meaningless for the records that are one.
    static func record(_ record: PromptLifecycleRecord) {
        logger.notice("\(record.summary, privacy: .public)")
        write(record, to: fileURL)
    }

    /// Appends one line: a timestamp, the summary, and the detail when there is one.
    ///
    /// **Every failure is swallowed and the file is only ever appended to**, exactly as
    /// `AnswerAbortLog.write` is: this runs inside a status commit and inside an answer a
    /// person is waiting on, so a log that cannot be written is not a reason to behave
    /// differently from one that can — and an unopenable file is left alone rather than
    /// replaced, because the history already in it is worth more than this one record.
    static func write(_ record: PromptLifecycleRecord, to url: URL) {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Local time with its offset, because the other half of this record is in the unified
        // log — which Console shows in local time — and correlating the two should not need
        // arithmetic.
        stamp.timeZone = .current
        var line = "\(stamp.string(from: Date())) \(record.summary)"
        // One line per record, always. The detail is the user's own text and can carry a
        // newline of its own, so it is folded onto the same line rather than given its own
        // block — `AnswerAbortLog`'s delimited dump is right for a whole screen and wrong for
        // a label, and a `grep` over this file has to return whole records.
        if let detail = record.detail, !detail.isEmpty {
            let folded = detail
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\"", with: "'")
            line += " detail=\"\(folded)\""
        }
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try? manager.createDirectory(at: url.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: Data("\(line)\n".utf8))
    }
}
