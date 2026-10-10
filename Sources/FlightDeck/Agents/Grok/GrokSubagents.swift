import Foundation

/// grok's subagents, as files: where they are, which are running, and which hold a card.
///
/// Probed live on grok 1.0.30 (`.superpowers/grok-tui-facts-2.md` §4). A subagent is a session
/// of its own — `sessions/<encoded child cwd>/<child id>/`, a sibling of its parent's directory,
/// with its own `events.jsonl` and `updates.jsonl` — and the parent marks it with
/// `<parent dir>/subagents/<child id>/meta.json` (`status: "running"|"completed"`).
///
/// **Why the parent's own files are not enough.** A subagent's permission card is drawn in the
/// PARENT's TUI, but its `tool_call` and its unmatched `permission_requested` are written only to
/// the child's files. For a background subagent the parent happens to mirror the wait (a
/// `permission_requested` on `get_command_or_subagent_output`); for a foreground one it writes
/// nothing at all and reads `busy` while the card waits. So a parent's status and its open prompt
/// have to look at its running children.
enum GrokSubagents {
    static let directoryName = "subagents"
    static let metaName = "meta.json"

    /// The tools a parent sits in while a subagent works: a foreground `spawn_subagent` runs
    /// until the child ends, a background child is waited on with `get_command_or_subagent_output`.
    /// An open call to one of these is the parent waiting on its child, not a card of its own.
    static let waitingTools: Set<String> = ["spawn_subagent", "get_command_or_subagent_output"]

    /// The children `<parentDirectory>/subagents/` names, split into running and finished.
    /// `known` are ids already seen finished; a finished child never runs again, so they are
    /// skipped without reading their `meta.json`.
    static func children(
        ofSessionDirectory parentDirectory: URL, skipping known: Set<String> = []
    ) -> (running: [String], finished: [String]) {
        let root = parentDirectory.appendingPathComponent(directoryName, isDirectory: true)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return ([], []) }
        var running: [String] = []
        var finished: [String] = []
        for name in names.sorted() where !known.contains(name) {
            let meta = root.appendingPathComponent(name).appendingPathComponent(metaName)
            guard let data = try? Data(contentsOf: meta),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            if object["status"] as? String == "running" { running.append(name) } else { finished.append(name) }
        }
        return (running, finished)
    }

    /// A child id as grok mints them: a lowercase UUID (probed: `01a120ac-aefd-7c71-884a-289c9a0a72ae`).
    /// Checked before any path is built from an id that came off the wire.
    static func isChildID(_ id: String) -> Bool {
        id.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", options: .regularExpression) != nil
    }

    /// Whether the session in `parentDirectory` spawned `id` (its `subagents/<id>/meta.json`).
    static func isChild(_ id: String, ofSessionDirectory parentDirectory: URL) -> Bool {
        FileManager.default.fileExists(atPath: parentDirectory
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(id).appendingPathComponent(metaName).path)
    }

    /// The child's own session directory, wherever its cwd put it.
    static func childDirectory(_ id: String, sessionsRoot: URL) -> URL? {
        guard let uuid = UUID(uuidString: id) else { return nil }
        return GrokSessionFiles.existingSessionDirectory(root: sessionsRoot, conversationID: uuid)
    }

    /// Whether an `events.jsonl` ends with a permission request still unresolved — the same
    /// counting `GrokStatusFold` does, because the records carry no call id.
    static func holdsPermission(eventsData data: Data) -> Bool {
        var fold = GrokStatusFold()
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let record = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            _ = fold.apply(eventRecord: record)
        }
        return fold.pendingPermissions > 0
    }

    /// The directories of the running children of the session whose transcript is `transcript`
    /// that hold an open permission right now. Read in full each call: a subagent's events file
    /// is one short task, and this runs only for a tab that is `waiting`.
    static func childrenHoldingPermission(ofTranscript transcript: URL) -> [URL] {
        let parent = transcript.deletingLastPathComponent()
        let root = GrokSessionFiles.sessionsRoot(ofTranscript: transcript)
        return children(ofSessionDirectory: parent).running.compactMap { id in
            guard let dir = childDirectory(id, sessionsRoot: root),
                  let data = try? Data(contentsOf: dir.appendingPathComponent(GrokSessionFiles.eventsName)),
                  holdsPermission(eventsData: data)
            else { return nil }
            return dir
        }
    }

    /// A value that changes whenever a running child's `events.jsonl` does, or nil for a
    /// session with no `subagents/` directory.
    static func stamp(ofTranscript transcript: URL) -> String? {
        let parent = transcript.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: parent.appendingPathComponent(directoryName).path) else { return nil }
        let root = GrokSessionFiles.sessionsRoot(ofTranscript: transcript)
        return children(ofSessionDirectory: parent).running.map { id -> String in
            guard let dir = childDirectory(id, sessionsRoot: root) else { return "\(id):-" }
            var info = stat()
            guard stat(dir.appendingPathComponent(GrokSessionFiles.eventsName).path, &info) == 0 else { return "\(id):-" }
            return "\(id):\(info.st_size):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec)"
        }.joined(separator: ",")
    }

    /// The last `maxBytes` of a file as lines, the first (possibly cut) line dropped when the
    /// read did not start at the top.
    static func tailLines(of url: URL, maxBytes: Int = 256 * 1024) -> [SourceLine] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        guard (try? handle.seek(toOffset: start)) != nil, let data = try? handle.readToEnd() else { return [] }
        var lines: [SourceLine] = []
        var offset = Int(start)
        var first = true
        for chunk in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
            defer { offset += chunk.count + 1; first = false }
            if first && start > 0 { continue }
            guard !chunk.isEmpty else { continue }
            lines.append(SourceLine(offset: offset, text: String(decoding: chunk, as: UTF8.self)))
        }
        return lines
    }
}
