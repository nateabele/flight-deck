// Sources/FlightDeck/ProcessIdentity.swift
import Foundation

/// One process, identified so that a recycled pid cannot be mistaken for it.
///
/// A pid alone is not an identity — macOS recycles pids. This is the same doctrine
/// `ConversationPin.Anchor` uses for the `~/.claude/sessions/<pid>.json` registry: a
/// familiar pid carrying an unfamiliar start time is a *different* process, not the one we
/// recorded. Every signal the reaper sends is gated on this pairing still matching, which
/// is what makes the launch-time orphan sweep safe to run against a snapshot written by a
/// previous boot.
struct ProcessIdentity: Codable, Equatable, Sendable {
    let pid: pid_t
    /// Process start time in whole microseconds since the epoch, from `PROC_PIDTBSDINFO`'s
    /// `pbi_start_tvsec` and `pbi_start_tvusec` combined. Whole-seconds resolution alone lets
    /// two unrelated processes that start within the same second collide on this field, and
    /// this value is the sole gate `isAlive` uses before a signal goes out — a collision there
    /// is a signal sent to the wrong process.
    let procStart: UInt64
}
