import FleetKit
import Foundation
import OSLog

/// What this phone writes down about itself, and how the Mac reads it back.
///
/// **It exists because the phone was the only unobserved half of this system.** The Mac keeps
/// `~/Library/Logs/flight-deck-answer.log` (every aborted answer drive, with the viewport that
/// caused it) and `~/Library/Logs/flight-deck-prompt.log` (every dialog it believed was open,
/// and every frame it pushed about one). The phone kept nothing at all — `Logger` appeared
/// nowhere in this target — so when a handset showed a card for a dialog the Mac had already
/// left, "the Mac never pushed the closure" and "the phone never applied one it was sent" were
/// indistinguishable, and the only evidence available was a person reading their screen aloud.
/// Two bugs were chased that way for a day each.
///
/// **Structural only, and this is a hard boundary rather than a habit.** These lines are
/// fetched over the fleet socket and written to a file on somebody's Mac, so nothing here may
/// carry prompt option text, transcript content, a session title, or anything a person typed.
/// Ids, counts, states and timings. Every call site below is one line of that shape; a call
/// that interpolated a label would put a user's own words on a wire the user never chose to
/// put them on.
///
/// **A diagnostic aid, not a trace.** One line per connection transition, one per change in
/// what dialog this phone believes is open, one per answer and its outcome. Nothing is logged
/// per render, per event or per fetched page — `blocked(agent:activity:call:)` is called from a
/// view body, so the model logs the *transition* and not the call.
///
/// **Nothing reads a record back and no branch is taken on one.** A change here that altered
/// when a frame is sent, or what is in it, would destroy the thing being measured — the same
/// rule `PromptLifecycleRecord` states on the Mac.
enum PhoneLog {
    /// The app's own bundle id, so `OSLogStore`'s predicate below selects exactly what these
    /// loggers wrote and nothing the system logged around them.
    ///
    /// Read from the bundle with the literal as a fallback, matching `PromptLifecycleLog` on
    /// the Mac: a test bundle has its own identifier, and a subsystem that silently became
    /// the test host's would make `entries(seconds:limit:)` return nothing with no hint why.
    static let subsystem = Bundle.main.bundleIdentifier ?? "dev.flightdeck.FlightDeckMobile"

    /// Dialling, connecting, snapshots and resume points — the phone's counterpart to the
    /// Mac's `resume lastSeq=… mode=…` line.
    static let connection = Logger(subsystem: subsystem, category: "connection")
    /// What dialog this phone believes is open, and what the Mac told it was open.
    static let prompt = Logger(subsystem: subsystem, category: "prompt")
    /// Answers sent, and what came back.
    static let answer = Logger(subsystem: subsystem, category: "answer")

    /// The categories `entries(seconds:limit:)` will return, which is every one above.
    ///
    /// Named rather than derived so a category added for something that is *not* a diagnostic
    /// — a future noisy one — does not silently start crossing the device boundary.
    static let categories = ["connection", "prompt", "answer"]

    /// This phone's own entries from the last `seconds` seconds, oldest first.
    ///
    /// **`.currentProcessIdentifier` is the only scope an iOS app may open**, and its
    /// consequence has to be understood by anyone reading the result: it holds what *this
    /// launch* logged and nothing from before it. A phone that crashed, was force-quit, or was
    /// evicted from memory and relaunched answers with a fresh, short log — so an empty answer
    /// means "the app restarted", never "nothing happened". `flight-deck-phone.log` on the Mac
    /// accumulates across fetches, which is what gives the history this scope cannot.
    ///
    /// `notice` and above, deliberately: `info` is kept in a memory ring and is not persisted,
    /// which is the same trap `PromptLifecycleLog` documents on the Mac — every line this type
    /// writes is `notice` or `error` so that it is still there when somebody asks.
    ///
    /// Both bounds are clamped here rather than trusted from the Mac, the same contract
    /// `FleetService`'s `.search` handler keeps against a phone: a peer-side bug that asked for
    /// a week of entries must not cost this phone an unbounded read.
    static func entries(seconds: Int, limit: Int) -> Result<WirePhoneLogs, PhoneRequestRefusal> {
        let window = min(max(seconds, 1), PhoneLogLimits.maxSeconds)
        let cap = min(max(limit, 1), PhoneLogLimits.maxEntries)
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else {
            return .failure(PhoneRequestRefusal(code: "unreadable"))
        }
        let since = store.position(date: Date().addingTimeInterval(-TimeInterval(window)))
        // The predicate is applied by the store rather than by a filter here, so the categories
        // this app does not own are never materialised as entries at all — on a busy launch
        // that is the difference between reading three hundred records and thirty thousand.
        let predicate = NSPredicate(
            format: "subsystem == %@ AND category IN %@", subsystem, categories
        )
        guard let found = try? store.getEntries(with: [], at: since, matching: predicate) else {
            return .failure(PhoneRequestRefusal(code: "unreadable"))
        }
        // Built here, once per fetch, rather than held as a static: `ISO8601DateFormatter` is
        // not `Sendable` and this target builds in Swift 6, so a shared instance would be a
        // data race the compiler correctly refuses. One allocation per fetch — not per entry —
        // is not a cost worth an `nonisolated(unsafe)` for.
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Local time with its offset, matching `PromptLifecycleLog.write` on the Mac exactly:
        // the two halves of a failure are read side by side, and correlating them should not
        // need arithmetic.
        stamp.timeZone = .current
        let all = found.compactMap { $0 as? OSLogEntryLog }.map {
            WirePhoneLogEntry(
                at: stamp.string(from: $0.date), level: describe($0.level),
                category: $0.category, message: $0.composedMessage
            )
        }
        // The NEWEST `cap` entries, not the oldest: a truncated answer must keep the end of the
        // story, because the end is where the failure being chased is. `truncated` says the
        // window was too wide, which is the one thing a short answer cannot say for itself.
        return .success(WirePhoneLogs(
            entries: Array(all.suffix(cap)), truncated: all.count > cap
        ))
    }

    /// `OSLogEntryLog.Level` has no string form of its own, and the raw integers would make
    /// the fetched file unreadable.
    private static func describe(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .undefined: return "undefined"
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        @unknown default: return "unknown"
        }
    }
}
