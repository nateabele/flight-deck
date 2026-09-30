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

/// One thing a person can ask of an intake; identifies a send for the in-flight set.
enum IntakeAction: Hashable {
    case tape(String), defaultPlay(String), note(UUID), removeNote(UUID)
}

enum CommandCopy {
    /// `nil` is the deadline: no answer at all.
    static func message(for error: FleetRequestError?) -> String {
        switch error {
        case nil: return "Couldn't reach your Mac."
        case .disconnected?: return "Not connected to your Mac, so this wasn't sent."
        case .server(let code)?:
            switch code {
            case "intake_moved_on": return "This intake has moved on."
            case "not_allowed": return "That isn't possible right now."
            case "note_consumed": return "A round has already read that note."
            case "empty_note": return "Write something first."
            case "unknown_intake": return "This intake is no longer on your Mac."
            case "unknown_checkpoint", "unknown_block": return "The plan changed — reopen it and try again."
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
    /// Tokens of sends that timed out, by action; see `send`.
    @ObservationIgnored private var retryTokens: [IntakeAction: UUID] = [:]

    init(intake: UUID, commander: IntakeCommanding?, timeout: Duration = .seconds(10)) {
        self.intake = intake
        self.commander = commander
        self.timeout = timeout
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
    /// it" from "it got it and the ack was lost", so the timed-out token is remembered and the
    /// next send of the same action reuses it: the Mac dedupes on the token, which is what
    /// makes the retry safe. It is forgotten on an ack or a `.server` err (a definitive answer)
    /// and on `.disconnected` (never sent), after which a fresh token is right.
    func send(_ action: IntakeAction, command: (UUID) -> FleetCommand, onAck: @escaping () -> Void) {
        guard !inFlight.contains(action) else { return }
        let token = retryTokens[action] ?? UUID()
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
            self.retryTokens[action] = token
            self.message = CommandCopy.message(for: nil)
        }

        guard let commander else {
            deadlines.removeValue(forKey: token)?.cancel()
            inFlight.remove(action)
            retryTokens[action] = nil
            message = CommandCopy.message(for: .disconnected)
            return
        }
        commander.sendIntake(command(token)) { [weak self] result in
            // Whichever of the answer and the deadline claims the token first wins.
            guard let self, let deadline = self.deadlines.removeValue(forKey: token) else { return }
            deadline.cancel()
            self.inFlight.remove(action)
            self.retryTokens[action] = nil
            switch result {
            case .success: onAck()
            case .failure(let error): self.message = CommandCopy.message(for: error)
            }
        }
    }
}
