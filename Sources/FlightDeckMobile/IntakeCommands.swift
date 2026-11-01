import FleetKit
import Foundation

/// What `IntakeCommandModel` needs from the fleet: send a command, hear exactly one answer.
/// The answer can arrive before `sendIntake` returns (`.disconnected` with no socket, the
/// asymmetry `FleetConnector.send(_:then:)` documents).
@MainActor
protocol IntakeCommanding: AnyObject {
    func sendIntake(
        _ command: FleetCommand,
        then: @escaping (Result<Void, FleetRequestError>) -> Void
    )
}

/// One thing a person can ask of an intake; identifies a send for the in-flight set and for the
/// kept retry token. `answer` carries the round's digest: one shared action let the next round's
/// answer reuse a token kept from a timed-out send of the last, which the Mac acks as a
/// duplicate and drops without a word.
enum IntakeAction: Hashable {
    case tape(String), defaultPlay(String), note(UUID), removeNote(UUID), noteKind(UUID), choose(String), rounds
    case answer(String)
    /// Ask threads: a draft's send (by its id), a thread's resolve (by thread id). Answers are keyed
    /// on the turn they answer and a diff's decision on which decision it is (C-I1): a token kept
    /// from a lost ✓ reused for a ✗ was acked as a duplicate while the plan took the edit, and one
    /// kept from turn N's answers reused for turn N+1's dropped them without a word.
    case threadSend(UUID), threadResolve(UUID), threadAnswer(UUID, turn: Int), diffDecide(UUID, accept: Bool)
}

enum CommandCopy {
    /// `nil` is the deadline: no answer at all. `afterSend` tells a `.disconnected` that came
    /// after the command was written (the socket dropped mid-flight, so it may have landed) from
    /// one with no socket at all (nothing was sent).
    static func message(for error: FleetRequestError?, afterSend: Bool = false) -> String {
        switch error {
        case nil: return "Couldn't reach your Mac."
        case .disconnected?:
            return afterSend ? "Lost the connection — your Mac may not have got this."
                             : "Not connected to your Mac, so this wasn't sent."
        case .server(let code)?:
            switch code {
            // Not "here are the new ones": the round may have been answered on the Mac, with triage
            // going straight to a fidelity and no new questions after it.
            case "stale_questions": return "These questions were answered or replaced."
            case "unknown_question": return "Your Mac couldn't match these answers to its questions."
            case "invalid_answer": return "Your Mac couldn't use one of these answers."
            case "intake_moved_on": return "This intake has moved on."
            case "not_allowed": return "That isn't possible right now."
            case "note_consumed": return "A round has already read that note."
            case "empty_note": return "Write something first."
            case "diff_stale": return "That change no longer fits the plan. Ask the agent to propose it again."
            case "diff_decided": return "That change was already decided."
            case "already_accepted": return "You already accepted that change."
            case "unknown_diff", "unknown_thread": return "That thread is no longer on your Mac."
            case "thread_resolved": return "This thread is resolved."
            case "empty_message": return "Write something first."
            case "threads_unavailable": return "Your Mac isn't running ask threads."
            case "no_agent": return "No agent is set up on your Mac to answer."
            case "write_failed": return "Your Mac couldn't save that. Try again."
            case "no_agents": return "No agent is available on your Mac to run planning rounds."
            case "unknown_intake": return "This intake is no longer on your Mac."
            case "unknown_checkpoint", "unknown_block", "rounds_changed":
                return "The plan changed — reopen it and try again."
            case "invalid_config": return "Your Mac couldn't use those settings."
            // The Mac's own sentence, as the Rounds editor words it ("The reviewer already ran…").
            case _ where code.hasPrefix(RoundsRefusal.prefix): return String(code.dropFirst(RoundsRefusal.prefix.count))
            default: return "Your Mac wouldn't do that (\(code))."
            }
        }
    }
}

/// Sends one intake's commands and reports what came of them: the in-flight set (immediate
/// feedback), and a message when a send fails or times out.
@MainActor
@Observable
final class IntakeCommandModel {
    let intake: UUID
    private(set) var inFlight: Set<IntakeAction> = []
    private(set) var message: String?
    /// Weak: the fleet owns Flight Control, which owns this model, so a strong reference here
    /// would be a cycle that keeps a dropped `FleetModel` alive.
    @ObservationIgnored private weak var commander: IntakeCommanding?
    @ObservationIgnored private let timeout: Duration
    @ObservationIgnored private var deadlines: [UUID: Task<Void, Never>] = [:]
    /// Tokens of sends whose fate is unknown, by action, with when they were kept; see `send`.
    @ObservationIgnored private var retryTokens: [IntakeAction: (token: UUID, keptAt: Date)] = [:]
    @ObservationIgnored private let now: () -> Date

    /// How long a kept token stands for "retry that press". Past it a send is a new press: a
    /// token reused hours later would be acked by the Mac as a duplicate while nothing ran.
    static let retryWindow: TimeInterval = 60

    init(intake: UUID, commander: IntakeCommanding?, timeout: Duration = .seconds(10),
         now: @escaping () -> Date = Date.init) {
        self.intake = intake
        self.commander = commander
        self.timeout = timeout
        self.now = now
    }

    func clearMessage() { message = nil }

    /// Forget everything in flight (unpair): a late ack or deadline must not touch state that
    /// now belongs to nobody.
    func cancelAll() {
        for deadline in deadlines.values { deadline.cancel() }
        deadlines = [:]
        inFlight = []
        retryTokens = [:]
        message = nil
    }

    /// Does nothing if `action` is already in flight. A timeout cannot tell "the Mac never got
    /// it" from "it got it and the ack was lost", and nor can a `.disconnected` that arrives
    /// after the write (the connector drains in-flight acks when the socket drops), so either
    /// keeps the token and the next send of the same action within `retryWindow` reuses it: the
    /// Mac dedupes on the token, which is what makes the retry safe. It is forgotten on an ack
    /// or a `.server` err — a definitive answer, even one arriving after the deadline — after
    /// which a fresh token is right. A `.disconnected` before `sendIntake` returns (no socket)
    /// sent nothing, so it leaves any token kept earlier as it was.
    ///
    /// `onFailure` hears every failure after the message is set — the error, or `nil` for no
    /// answer by the deadline — for a caller that must undo something on a particular refusal.
    func send(_ action: IntakeAction, command: (UUID) -> FleetCommand, onAck: @escaping () -> Void,
              onFailure: ((FleetRequestError?) -> Void)? = nil) {
        guard !inFlight.contains(action) else { return }
        if let kept = retryTokens[action], now().timeIntervalSince(kept.keptAt) >= Self.retryWindow {
            retryTokens[action] = nil
        }
        let token = retryTokens[action]?.token ?? UUID()
        inFlight.insert(action)
        message = nil

        // Armed BEFORE the send, which can complete before it returns; otherwise the deadline
        // would outlive an answer already shown and fire over it.
        let timeout = self.timeout
        deadlines[token] = Task { [weak self] in
            try? await Task.sleep(for: timeout)
            guard !Task.isCancelled, let self, self.deadlines.removeValue(forKey: token) != nil
            else { return }
            self.inFlight.remove(action)
            self.retryTokens[action] = (token, self.now())
            self.message = CommandCopy.message(for: nil)
            onFailure?(nil)
        }

        guard let commander else {
            deadlines.removeValue(forKey: token)?.cancel()
            inFlight.remove(action)
            message = CommandCopy.message(for: .disconnected)
            onFailure?(.disconnected)
            return
        }
        var returned = false
        commander.sendIntake(command(token)) { [weak self] result in
            guard let self else { return }
            let definitive: Bool
            if case .failure(.disconnected) = result { definitive = false } else { definitive = true }
            // Whichever of the answer and the deadline claims the token first wins. The loser
            // may still carry news: a late ack or refusal settles the token the deadline kept.
            guard let deadline = self.deadlines.removeValue(forKey: token) else {
                if definitive, self.retryTokens[action]?.token == token { self.retryTokens[action] = nil }
                return
            }
            deadline.cancel()
            self.inFlight.remove(action)
            switch result {
            case .success:
                self.retryTokens[action] = nil
                onAck()
            case .failure(.disconnected):
                if returned { self.retryTokens[action] = (token, self.now()) }
                self.message = CommandCopy.message(for: .disconnected, afterSend: returned)
                onFailure?(.disconnected)
            case .failure(let error):
                self.retryTokens[action] = nil
                self.message = CommandCopy.message(for: error)
                onFailure?(error)
            }
        }
        returned = true
    }
}
