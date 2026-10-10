import Foundation

/// Where grok keeps one session, and what two of its files say.
///
/// Layout, probed on grok 1.0.30 (`.superpowers/grok-tui-facts.md` §2):
/// `$GROK_HOME/sessions/<percent-encoded absolute cwd>/<session uuid>/`, holding among others
/// `updates.jsonl` (the transcript — what grok's own hooks name as `transcriptPath`),
/// `events.jsonl` (a phase machine: turn started, permission requested, turn ended) and
/// `summary.json` (the title). `grok -s <uuid>` creates the directory at LAUNCH, before any
/// prompt, so a binding computed before the process starts names a path that is about to exist.
enum GrokSessionFiles {
    static let transcriptName = "updates.jsonl"
    static let eventsName = "events.jsonl"
    static let summaryName = "summary.json"

    static func sessionsRoot(home: URL) -> URL {
        home.appendingPathComponent("sessions", isDirectory: true)
    }

    /// grok's directory name for a working directory: the absolute path percent-encoded, so
    /// `/Users/me/repo` is `%2FUsers%2Fme%2Frepo`. Unreserved characters (`-._~`, letters,
    /// digits) pass through, which every name on the probe machine bore out — `.fd-grok-probe`
    /// kept its dot and hyphen.
    ///
    /// **Not total, and the gap is stated rather than papered over.** grok swaps a name longer
    /// than 255 bytes for a slug plus a hash and a `.cwd` file (its user guide, ch. 17), and that
    /// hash is grok's own. `sessionDirectory` therefore prefers whatever directory already holds
    /// the session over this computed one; a brand-new session in a very deep directory is the
    /// one case that computes a path grok will not use.
    static func encodedDirectoryName(forWorkingDirectory path: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }

    /// The session's directory: the one that already holds `conversationID` if any does, else
    /// where grok will create it for `workingDirectory`.
    ///
    /// The scan exists because `grok -r <uuid>` is global (facts §0.6): a resumed session keeps
    /// the directory of the cwd it was BORN in, which need not be this tab's. Matching on the
    /// session id alone is exact — grok mints ids per session, so one id names one directory.
    static func sessionDirectory(
        home: URL, workingDirectory: String, conversationID: UUID,
        listing: (String) -> [String] = defaultListing
    ) -> URL {
        let root = sessionsRoot(home: home)
        if let found = existingSessionDirectory(root: root, conversationID: conversationID, listing: listing) {
            return found
        }
        return root
            .appendingPathComponent(encodedDirectoryName(forWorkingDirectory: workingDirectory), isDirectory: true)
            .appendingPathComponent(conversationID.uuidString.lowercased(), isDirectory: true)
    }

    /// `sessions/*/<id>`, or nil. grok writes ids lowercase.
    static func existingSessionDirectory(
        root: URL, conversationID: UUID, listing: (String) -> [String] = defaultListing
    ) -> URL? {
        let id = conversationID.uuidString.lowercased()
        for name in listing(root.path) {
            let candidate = root.appendingPathComponent(name, isDirectory: true)
                .appendingPathComponent(id, isDirectory: true)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    static func transcriptURL(
        home: URL, workingDirectory: String, conversationID: UUID,
        listing: (String) -> [String] = defaultListing
    ) -> URL {
        sessionDirectory(home: home, workingDirectory: workingDirectory,
                         conversationID: conversationID, listing: listing)
            .appendingPathComponent(transcriptName)
    }

    /// The sibling of a transcript, by name — every grok file the adapter reads lives in the
    /// same session directory, so the transcript URL is the one path that has to be carried.
    static func sibling(_ name: String, of transcript: URL) -> URL {
        transcript.deletingLastPathComponent().appendingPathComponent(name)
    }

    /// `sessions/` above a transcript: `<root>/<encoded cwd>/<id>/updates.jsonl`.
    static func sessionsRoot(ofTranscript transcript: URL) -> URL {
        transcript.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// grok's process registry, `$GROK_HOME/active_sessions.json`:
    /// `[{"session_id","pid","cwd","opened_at"}]`, an entry added at launch and removed on exit.
    static func registryURL(sessionsRoot: URL) -> URL {
        sessionsRoot.deletingLastPathComponent().appendingPathComponent("active_sessions.json")
    }

    /// Whether the registry lists `conversationID`. An unreadable registry lists nothing.
    static func isRegistered(_ conversationID: UUID, registryData data: Data) -> Bool {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return false }
        let id = conversationID.uuidString.lowercased()
        return entries.contains { ($0["session_id"] as? String)?.lowercased() == id }
    }

    static func defaultListing(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }

    /// A session's title as `summary.json` holds it: `generated_title`, and whether a person set
    /// it (`title_is_manual`, which `/rename` sets and `/rename --auto` clears — probed live).
    struct Summary: Equatable, Sendable {
        let title: String
        let isManual: Bool
    }

    /// Nil for an unreadable file or an empty title — an auto title arrives ~6 s after the
    /// first turn, so "no title yet" is the ordinary state of a new session.
    static func summary(fromData data: Data) -> Summary? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = (object["generated_title"] as? String)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
              !title.isEmpty
        else { return nil }
        return Summary(title: title, isManual: object["title_is_manual"] as? Bool ?? false)
    }
}
