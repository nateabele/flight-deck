import Foundation

/// `threads/` on disk: ThreadRunner is its only writer, and every other process reads it through
/// `ThreadStoreReading`. Each file is replaced atomically, so a reader in another process sees
/// the whole old file or the whole new one, never half of a write.
///
/// ```
/// threads/commands.jsonl            ThreadCommandStore: what the app and the phone append (R8)
/// threads/cursor                    the last command seq ThreadRunner has folded in (R5)
/// threads/runner.json               the runner's pid and heartbeat (R5)
/// threads/runner.lock               one runner per intake
/// threads/<id>/thread.json          ThreadRecord
/// threads/<id>/turns.jsonl          one ThreadTurn per line, rewritten whole
/// threads/<id>/diffs/<diff>.json    ThreadDiff
/// threads/<id>/activity.json        the running turn's SeatActivity (R2)
/// threads/<id>/workspace/           ThreadWorkspace, rebuilt per turn
/// threads/<id>/runs/<seq>-<n>/      one headless run's stdout, stderr and schema
/// ```
///
/// Reads every call, caching nothing: the app's binding holds one reader for the life of the
/// detail pane, and it must see what the runner wrote since.
public struct ThreadStore: ThreadStoreReading, Sendable {
    public let intakeDirectory: URL

    public init(intakeDirectory: URL) { self.intakeDirectory = intakeDirectory }

    public var threadsDirectory: URL { intakeDirectory.appendingPathComponent("threads", isDirectory: true) }
    public var cursorURL: URL { threadsDirectory.appendingPathComponent("cursor") }
    public var heartbeatURL: URL { threadsDirectory.appendingPathComponent("runner.json") }
    public var lockURL: URL { threadsDirectory.appendingPathComponent("runner.lock") }

    public func directory(_ id: ThreadID) -> URL {
        threadsDirectory.appendingPathComponent(id.raw.uuidString, isDirectory: true)
    }
    public func workspaceDirectory(_ id: ThreadID) -> URL { directory(id).appendingPathComponent("workspace", isDirectory: true) }
    public func activityURL(_ id: ThreadID) -> URL { directory(id).appendingPathComponent("activity.json") }
    public func runDirectory(_ id: ThreadID, name: String) -> URL {
        directory(id).appendingPathComponent("runs", isDirectory: true).appendingPathComponent(name, isDirectory: true)
    }
    private func recordURL(_ id: ThreadID) -> URL { directory(id).appendingPathComponent("thread.json") }
    private func turnsURL(_ id: ThreadID) -> URL { directory(id).appendingPathComponent("turns.jsonl") }
    private func diffsDirectory(_ id: ThreadID) -> URL { directory(id).appendingPathComponent("diffs", isDirectory: true) }

    // MARK: - Reading

    /// Every thread, oldest first. A folder without a readable `thread.json` is skipped.
    public func threads() -> [ThreadRecord] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: threadsDirectory.path)) ?? []
        return names.compactMap { UUID(uuidString: $0).flatMap { thread(ThreadID(raw: $0)) } }
            .sorted { ($0.createdAt, $0.id.raw.uuidString) < ($1.createdAt, $1.id.raw.uuidString) }
    }

    public func thread(_ id: ThreadID) -> ThreadRecord? {
        (try? Data(contentsOf: recordURL(id))).flatMap { try? IntakeJSON.decoder.decode(ThreadRecord.self, from: $0) }
    }

    /// In seq order. A line that doesn't decode is skipped.
    public func turns(_ id: ThreadID) -> [ThreadTurn] {
        guard let data = try? Data(contentsOf: turnsURL(id)) else { return [] }
        return LockedAppend.lines(of: data).compactMap { try? Self.lineDecoder.decode(ThreadTurn.self, from: $0) }
            .sorted { $0.seq < $1.seq }
    }

    /// In the order their turns proposed them.
    public func diffs(_ id: ThreadID) -> [ThreadDiff] {
        let dir = diffsDirectory(id)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        return names.filter { $0.hasSuffix(".json") }
            .compactMap { (try? Data(contentsOf: dir.appendingPathComponent($0))).flatMap { try? IntakeJSON.decoder.decode(ThreadDiff.self, from: $0) } }
            .sorted { ($0.turn ?? 0, $0.id.uuidString) < ($1.turn ?? 0, $1.id.uuidString) }
    }

    public func diff(_ thread: ThreadID, _ id: UUID) -> ThreadDiff? {
        (try? Data(contentsOf: diffsDirectory(thread).appendingPathComponent("\(id.uuidString).json")))
            .flatMap { try? IntakeJSON.decoder.decode(ThreadDiff.self, from: $0) }
    }

    /// R2's live line while a turn runs: the agent's current action ("running rg …", "reading
    /// s3.md"), else its headline, else "thinking". nil when no turn of this thread is running —
    /// checked against the turns, not the file alone, so a runner that died mid-turn leaves no
    /// activity showing forever.
    public func activity(_ id: ThreadID) -> String? {
        guard turns(id).contains(where: { $0.endedAt == nil && !$0.isDivider }),
              let data = try? Data(contentsOf: activityURL(id)),
              let activity = try? IntakeJSON.decoder.decode(SeatActivity.self, from: data), !activity.finished
        else { return nil }
        if let action = activity.action {
            return [action.verb, action.object].compactMap { $0 }.joined(separator: " ")
        }
        return activity.headline ?? "thinking"
    }

    /// The seq of the last thread command folded in; 0 before any.
    public func cursor() -> Int {
        (try? String(contentsOf: cursorURL, encoding: .utf8)).flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
    }

    public func heartbeat() -> ThreadRunnerHeartbeat? {
        (try? Data(contentsOf: heartbeatURL)).flatMap { try? IntakeJSON.decoder.decode(ThreadRunnerHeartbeat.self, from: $0) }
    }

    // MARK: - Writing (ThreadRunner only)

    func save(_ record: ThreadRecord) throws {
        try FileManager.default.createDirectory(at: directory(record.id), withIntermediateDirectories: true)
        try IntakeJSON.encoder.encode(record).write(to: recordURL(record.id), options: .atomic)
    }

    func save(turns: [ThreadTurn], of id: ThreadID) throws {
        try FileManager.default.createDirectory(at: directory(id), withIntermediateDirectories: true)
        var data = Data()
        for turn in turns.sorted(by: { $0.seq < $1.seq }) {
            data.append(try Self.lineEncoder.encode(turn))
            data.append(0x0A)
        }
        try data.write(to: turnsURL(id), options: .atomic)
    }

    func save(_ diff: ThreadDiff) throws {
        let dir = diffsDirectory(diff.thread)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try IntakeJSON.encoder.encode(diff).write(to: dir.appendingPathComponent("\(diff.id.uuidString).json"), options: .atomic)
    }

    func saveCursor(_ seq: Int) throws {
        try FileManager.default.createDirectory(at: threadsDirectory, withIntermediateDirectories: true)
        try Data("\(seq)\n".utf8).write(to: cursorURL, options: .atomic)
    }

    func saveHeartbeat(_ beat: ThreadRunnerHeartbeat?) {
        guard let beat else { try? FileManager.default.removeItem(at: heartbeatURL); return }
        try? FileManager.default.createDirectory(at: threadsDirectory, withIntermediateDirectories: true)
        try? IntakeJSON.encoder.encode(beat).write(to: heartbeatURL, options: .atomic)
    }

    func clearActivity(_ id: ThreadID) { try? FileManager.default.removeItem(at: activityURL(id)) }

    // A turn is one line: never pretty-printed.
    private static let lineEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = IntakeJSON.encoder.dateEncodingStrategy
        return e
    }()
    private static var lineDecoder: JSONDecoder { IntakeJSON.decoder }
}

/// `threads/runner.json` (R5): which process runs this intake's threads, and when it last said
/// so. The app reads a runner as gone once the heartbeat is stale, the rule `tape.json`'s
/// heartbeat follows for rounds.
public struct ThreadRunnerHeartbeat: Codable, Equatable, Sendable {
    public var pid: Int32
    public var heartbeat: Date
    public init(pid: Int32, heartbeat: Date) {
        self.pid = pid
        self.heartbeat = threadMillisecondRounded(heartbeat)
    }
}

extension ThreadTurn {
    /// The `messageID` prefix of a divider: the turn ThreadRunner records when the thread moves
    /// onto a newer round, whose `reply` is "Now reading <label>". It has no `you` and runs no
    /// agent.
    public static let dividerPrefix = "divider:"

    public var isDivider: Bool { messageID.hasPrefix(Self.dividerPrefix) }
}
