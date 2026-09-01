import FleetKit
import Foundation

/// How `AnswerTrigger`'s `logs` op reaches the attached phones.
///
/// A protocol over the two things it needs from `FleetService` rather than the service itself,
/// for the reason `TimelinePaging` is one on the phone: the concrete type owns an `NWListener`
/// and answers nothing without a socket, a pairing and a real handset, so a trigger that took
/// it could not have a single one of the outcomes that matter asserted — a phone too old to
/// ask, a phone that refuses, a phone that never answers.
///
/// Deliberately no wider than these two. Anything else the trigger wants from the fleet is a
/// seam this app can drift into using for something that is not a diagnostic fetch.
@MainActor
protocol PhoneLogFetching: AnyObject {
    /// Every phone attached right now, as its `hello` described it.
    var attachedClients: [FleetAttachment] { get }

    /// Ask one of them for its log. Answers **exactly once** — with the entries, with the
    /// phone's own refusal code, or with `.disconnected` when that connection is gone.
    func fetchPhoneLogs(
        from client: UUID, seconds: Int, limit: Int,
        then completion: @escaping (Result<WirePhoneLogs, FleetRequestError>) -> Void
    )
}

extension FleetService: PhoneLogFetching {}

/// Where a phone's fetched log lands on this Mac.
///
/// **Beside the Mac's own two, on purpose.** `flight-deck-answer.log` holds every aborted
/// answer drive and `flight-deck-prompt.log` every dialog this Mac believed was open; this is
/// the third file in that set and the first one whose contents came off another device. A
/// stale-card report is read by putting them side by side, so they share a directory, a
/// timestamp format and a local-time offset — see `PromptLifecycleLog.write`, which this
/// mirrors deliberately rather than by coincidence.
///
/// **Append-only, and it accumulates across fetches for a reason the phone cannot fix.**
/// `OSLogStore(scope: .currentProcessIdentifier)` — the only scope an iOS app may open —
/// returns what the *current launch* logged and nothing from before it, so the phone's own
/// horizon ends at its last restart. This file is the history that gives.
enum PhoneLogFile {
    /// `~/Library/Logs/flight-deck-phone.log`. Beside `flight-deck-answer.log`, for the reason
    /// that one is not in a container: this build is unsandboxed and a path a human can type is
    /// the whole point.
    static let fileURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/flight-deck-phone.log")

    /// Appends one fetch: a header naming the device and the moment, then one line per entry.
    ///
    /// The header is written even for an empty answer, and that is the point of writing one at
    /// all: "the phone answered and had nothing in the window" and "the fetch never happened"
    /// are different facts, and a file that recorded only the second case cannot tell them
    /// apart. `truncated` rides the header for the same reason — a short block and a clipped
    /// one look identical without it.
    ///
    /// **Every failure is swallowed and the file is only ever appended to**, exactly as
    /// `PromptLifecycleLog.write` is: a log that cannot be written is not a reason to answer
    /// the caller differently, and an unopenable file is left alone rather than replaced,
    /// because the history already in it is worth more than this one fetch.
    static func append(_ logs: WirePhoneLogs, device: String?, to url: URL = fileURL) {
        let stamp = ISO8601DateFormatter()
        stamp.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        // Local time with its offset, matching the other two logs in this directory and the
        // phone's own stamps, so correlating the three needs no arithmetic.
        stamp.timeZone = .current
        var text = "\(stamp.string(from: Date())) fetch device=\"\(fold(device ?? "-"))\""
            + " entries=\(logs.entries.count) truncated=\(logs.truncated)\n"
        for entry in logs.entries {
            // The phone's own timestamp, verbatim — never this Mac's clock. The whole value of
            // these lines is when they happened *on the phone*, and restamping them here would
            // put every entry of a fetch at the same instant.
            text += "\(entry.at) [\(entry.category)/\(entry.level)] \(fold(entry.message))\n"
        }
        write(text, to: url)
    }

    /// One line per record, always. A `grep` over this file has to return whole records, and
    /// the phone's own guarantee is that its messages are structural — this folds anyway,
    /// because a newer phone's line is not this build's to trust the shape of.
    private static func fold(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }

    private static func write(_ text: String, to url: URL) {
        let manager = FileManager.default
        if !manager.fileExists(atPath: url.path) {
            try? manager.createDirectory(at: url.deletingLastPathComponent(),
                                         withIntermediateDirectories: true)
            manager.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }
}
