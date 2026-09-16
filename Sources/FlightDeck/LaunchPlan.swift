// Sources/FlightDeck/LaunchPlan.swift
import Foundation

/// The pure attach-vs-cold-create decision for launching a session's shell under `fd-abduco`.
/// No process spawning, no liveness detection — those live elsewhere. This only turns a
/// liveness bool into the right `SessionDaemon` command and the text (if any) that still needs
/// to be typed into it.
enum LaunchPlan {
    /// The daemon already has a live session for this id: re-attach to it. Nothing needs to be
    /// typed — the shell inside is already running whatever it was running.
    case attach(command: String)

    /// No live daemon session exists: start one cold, then type `typed` into it (e.g. a
    /// `claude --resume` invocation, or the empty string for a plain shell).
    case coldCreate(command: String, typed: String)

    /// Decides between `.attach` and `.coldCreate` for `sessionID` based on `isLive`.
    static func decide(
        sessionID: UUID,
        isLive: Bool,
        shell: String,
        resumeOrLaunch typed: String,
        daemon: SessionDaemon
    ) throws -> LaunchPlan {
        if isLive {
            return .attach(command: try daemon.attachCommand(for: sessionID))
        }
        return .coldCreate(
            command: try daemon.coldCreateCommand(for: sessionID, shell: shell),
            typed: typed
        )
    }

    /// The shell command to launch, regardless of which case this is.
    var command: String {
        switch self {
        case .attach(let command):
            return command
        case .coldCreate(let command, _):
            return command
        }
    }

    /// The text still to be typed into the launched shell. Always empty for `.attach` — an
    /// attached session is already running whatever it was running.
    var typed: String {
        switch self {
        case .attach:
            return ""
        case .coldCreate(_, let typed):
            return typed
        }
    }
}
