import Foundation

/// The on-disk shape of one intake's shaping run, shared by the app process and the detached
/// runner: `tape.json` (the authoritative state), `commands.jsonl` (an append-only queue the
/// app writes and the runner drains) and `checkpoints/<id>/` (the files each round produced).
/// Not a single index file — the directory is the unit, same rationale as `IntakeStore`.
public struct TapeStore: Sendable {
    public let intakeDirectory: URL
    public init(intakeDirectory: URL) {
        self.intakeDirectory = intakeDirectory
    }

    public var tapeURL: URL { intakeDirectory.appendingPathComponent("tape.json") }
    public var commandsURL: URL { intakeDirectory.appendingPathComponent("commands.jsonl") }

    public func checkpointDirectory(_ id: Int) -> URL {
        intakeDirectory.appendingPathComponent("checkpoints", isDirectory: true).appendingPathComponent(String(id), isDirectory: true)
    }
    public func workDirectory() -> URL {
        intakeDirectory.appendingPathComponent("work", isDirectory: true)
    }
    public func runDirectory(_ name: String) -> URL {
        intakeDirectory.appendingPathComponent("runs", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }

    /// `.empty` when the file is absent or fails to decode — a corrupt tape is never a crash,
    /// it's a fresh start (the checkpoints directory still has whatever real work happened;
    /// only the index is gone).
    public func loadTape() -> Tape {
        guard let data = try? Data(contentsOf: tapeURL),
              let tape = try? IntakeJSON.decoder.decode(Tape.self, from: data) else {
            return .empty
        }
        return tape
    }

    public func saveTape(_ t: Tape) throws {
        try FileManager.default.createDirectory(at: intakeDirectory, withIntermediateDirectories: true)
        try IntakeJSON.encoder.encode(t).write(to: tapeURL, options: .atomic)
    }

    /// One `CommandEnvelope` per line, appended with a single `FileHandle` write rather than
    /// a rewrite of the whole file — the runner may be reading `commandsURL` concurrently, and
    /// `commands(after:)`'s torn-line tolerance exists specifically to cover a reader catching
    /// this write mid-flight.
    public func appendCommand(_ c: TapeCommand) throws -> Int {
        try FileManager.default.createDirectory(at: intakeDirectory, withIntermediateDirectories: true)
        let seq = (readCommandLines().map(\.seq).max() ?? 0) + 1
        var line = try Self.lineEncoder.encode(CommandEnvelope(seq: seq, command: c))
        line.append(0x0A) // "\n" — one line per command, never a multi-line pretty-print.

        if !FileManager.default.fileExists(atPath: commandsURL.path) {
            FileManager.default.createFile(atPath: commandsURL.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: commandsURL)
        defer { try? handle.close() }
        // A prior append that crashed mid-write leaves a torn final line with no trailing
        // newline. Appending straight onto that would glue this command onto the garbage,
        // corrupting both — and since a torn line is silently dropped by `commands(after:)`,
        // the command riding in on it (a pause/stop the user just asked for) would vanish
        // with no error anywhere. Closing that line out with its own newline first keeps this
        // append self-contained regardless of what the file already ends with.
        if let existing = try? Data(contentsOf: commandsURL), let last = existing.last, last != 0x0A {
            handle.seekToEndOfFile()
            handle.write(Data([0x0A]))
        }
        handle.seekToEndOfFile()
        handle.write(line)
        return seq
    }

    /// Commands with `seq > seq`, in file order. Skips a torn last line (no trailing newline,
    /// or invalid JSON) rather than treating it as fatal — that's the read side of
    /// `appendCommand` not being an atomic rewrite.
    public func commands(after seq: Int) -> [CommandEnvelope] {
        readCommandLines().filter { $0.seq > seq }
    }

    private func readCommandLines() -> [CommandEnvelope] {
        guard let data = try? Data(contentsOf: commandsURL), let text = String(data: data, encoding: .utf8) else {
            return []
        }
        return text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            guard let lineData = line.data(using: .utf8) else { return nil }
            return try? Self.lineDecoder.decode(CommandEnvelope.self, from: lineData)
        }
    }

    /// Writes the round's files into `checkpoints/<id>/` first, and only then appends the
    /// checkpoint and saves the tape. A crash between those two steps leaves an orphan
    /// directory `loadTape` never sees (it only reads `tape.json`) — and because the
    /// checkpoint id a rerun assigns is `(tape.head?.id ?? 0) + 1`, that rerun reuses exactly
    /// this id, so any stale file from the dead attempt is removed first rather than left to
    /// mix with the new one.
    public func writeCheckpoint(_ cp: Checkpoint, files: [String: Data], into tape: inout Tape) throws {
        let dir = checkpointDirectory(cp.id)
        let fm = FileManager.default
        if fm.fileExists(atPath: dir.path) {
            try fm.removeItem(at: dir)
        }
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        for (name, data) in files {
            // Names are relative paths (a draft round writes `drafts/<i>.md`), so each file's
            // own parent may not exist yet.
            let url = dir.appendingPathComponent(name)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Atomic, like every other tape write: a crash mid-write must not leave a torn
            // plan.md or changeset.json in a directory the next load might trust.
            try data.write(to: url, options: .atomic)
        }

        var next = tape
        next.checkpoints.append(cp)
        try saveTape(next)
        tape = next
    }

    // `commands.jsonl` has no dates to worry about, but it still must never be pretty-printed
    // — `IntakeJSON.encoder`'s `.prettyPrinted` would spread one command across several lines
    // and break the one-line-per-command contract `appendCommand`/`commands(after:)` share.
    private static let lineEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let lineDecoder = JSONDecoder()
}
