import Foundation

/// `threads/commands.jsonl` (R8): the app and the phone append `ThreadCommand`s, and ThreadRunner
/// reads them from its cursor (`threads/cursor`, R5). The same contract as the tape's
/// `commands.jsonl` (`TapeStore.appendCommand`/`commands(after:)`): one `{seq, command}` line per
/// command, `seq` one above the highest on file, a torn last line skipped on read and closed off
/// before the next append, and a kind a later build wrote dropped while its seq still counts.
///
/// **Appends are locked.** Two writers (the app and ThreadRunner's auto-accept path, or two app
/// processes) appending at once could both read the same max seq, so `append` reads the max and
/// writes under `LockedAppend`'s lock, as `TapeStore.appendCommand` does. Reads take no lock.
public struct ThreadCommandStore: Sendable {
    public let intakeDirectory: URL

    public init(intakeDirectory: URL) { self.intakeDirectory = intakeDirectory }

    public var threadsDirectory: URL { intakeDirectory.appendingPathComponent("threads", isDirectory: true) }
    public var commandsURL: URL { threadsDirectory.appendingPathComponent("commands.jsonl") }

    /// Appends `command` as one line and returns its seq.
    @discardableResult
    public func append(_ command: ThreadCommand) throws -> Int {
        try FileManager.default.createDirectory(at: threadsDirectory, withIntermediateDirectories: true)
        // Read-max-then-write under a lock on a sibling file: the app and ThreadRunner append here.
        return try LockedAppend.withLock(on: LockedAppend.lockURL(for: commandsURL)) {
            let seq = (lines().compactMap { try? Self.decoder.decode(SeqOnly.self, from: $0).seq }.max() ?? 0) + 1
            var line = try Self.encoder.encode(ThreadCommandEnvelope(seq: seq, command: command))
            line.append(0x0A) // one line per command, never a multi-line pretty-print

            if !FileManager.default.fileExists(atPath: commandsURL.path) {
                FileManager.default.createFile(atPath: commandsURL.path, contents: nil)
            }
            let handle = try FileHandle(forWritingTo: commandsURL)
            defer { try? handle.close() }
            // A crashed append leaves a torn last line with no newline; appending onto it would glue
            // this command to the garbage and both would be dropped on read. Close it off first.
            if let existing = try? Data(contentsOf: commandsURL), let last = existing.last, last != 0x0A {
                handle.seekToEndOfFile()
                handle.write(Data([0x0A]))
            }
            handle.seekToEndOfFile()
            handle.write(line)
            return seq
        }
    }

    /// Commands with a seq above `seq`, in file order. A torn or unknown line is skipped, never
    /// fatal to the read.
    public func commands(after seq: Int) -> [ThreadCommandEnvelope] {
        lines().compactMap { try? Self.decoder.decode(ThreadCommandEnvelope.self, from: $0) }.filter { $0.seq > seq }
    }

    private func lines() -> [Data] {
        guard let data = try? Data(contentsOf: commandsURL) else { return [] }
        return LockedAppend.lines(of: data)
    }

    /// Just a line's seq, so a line this build can't decode still counts toward the next one:
    /// reused, a new command would sit at or below the reader's cursor and never be read.
    private struct SeqOnly: Decodable { let seq: Int }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        return e
    }()
    private static let decoder = JSONDecoder()
}
