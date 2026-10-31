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
/// Cheap to poll: the Mac panel reads it every second or two on the main actor, for every
/// thread. Each parse is cached against its file's (mtime, size, inode) — every write here is
/// an atomic replace, so a changed file is always a new inode — and a thread whose files
/// haven't changed costs a `stat` per file, a resolved one included. `turns.jsonl` is rewritten
/// whole when a turn lands (its reply fills in an existing line), so it is reparsed whole when
/// it changes, never read from an offset. Copies of a store share one cache.
public struct ThreadStore: ThreadStoreReading, Sendable {
    public let intakeDirectory: URL
    private let cache = ReadCache()

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
        let names: [String] = cache.cached(threadsDirectory, as: [String].self) {
            (try? FileManager.default.contentsOfDirectory(atPath: threadsDirectory.path)) ?? []
        } ?? []
        return names.compactMap { UUID(uuidString: $0).flatMap { thread(ThreadID(raw: $0)) } }
            .sorted { ($0.createdAt, $0.id.raw.uuidString) < ($1.createdAt, $1.id.raw.uuidString) }
    }

    public func thread(_ id: ThreadID) -> ThreadRecord? {
        let url = recordURL(id)
        return cache.cached(url, as: ThreadRecord?.self) {
            (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode(ThreadRecord.self, from: $0) }
        } ?? nil
    }

    /// In seq order. A line that doesn't decode is skipped.
    public func turns(_ id: ThreadID) -> [ThreadTurn] {
        let url = turnsURL(id)
        return cache.cached(url, as: [ThreadTurn].self) {
            guard let data = try? Data(contentsOf: url) else { return [] }
            return LockedAppend.lines(of: data).compactMap { try? Self.decoder.decode(ThreadTurn.self, from: $0) }
                .sorted { $0.seq < $1.seq }
        } ?? []
    }

    /// In the order their turns proposed them. The directory's own stamp moves whenever a diff
    /// file is added or replaced (an atomic write is a rename into it), so an unchanged directory
    /// returns the cached list without touching its files.
    public func diffs(_ id: ThreadID) -> [ThreadDiff] {
        let dir = diffsDirectory(id)
        return cache.cached(dir, as: [ThreadDiff].self) {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
            return names.filter { $0.hasSuffix(".json") }
                .compactMap { (try? Data(contentsOf: dir.appendingPathComponent($0))).flatMap { try? Self.decoder.decode(ThreadDiff.self, from: $0) } }
                .sorted { ($0.turn ?? 0, $0.id.uuidString) < ($1.turn ?? 0, $1.id.uuidString) }
        } ?? []
    }

    public func diff(_ thread: ThreadID, _ id: UUID) -> ThreadDiff? {
        diffs(thread).first { $0.id == id }
    }

    /// Changes whenever anything a reader shows could have: a thread added, or any thread's
    /// header, turns, diffs or live activity rewritten. A poller compares it with the last one
    /// and skips its refresh when it is the same. Costs a `stat` per file, no reads.
    public func fingerprint() -> Int {
        var h = Hasher()
        h.combine(FileStamp(threadsDirectory))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: threadsDirectory.path)) ?? []
        for name in names.sorted() {
            guard let raw = UUID(uuidString: name) else { continue }
            let id = ThreadID(raw: raw)
            for url in [recordURL(id), turnsURL(id), diffsDirectory(id), activityURL(id)] { h.combine(FileStamp(url)) }
        }
        return h.finalize()
    }

    /// R2's live line while a turn runs: the agent's current action ("running rg …", "reading
    /// s3.md"), else its headline, else "thinking". nil when no turn of this thread is running —
    /// checked against the turns, not the file alone, so a runner that died mid-turn leaves no
    /// activity showing forever.
    public func activity(_ id: ThreadID) -> String? {
        let url = activityURL(id)
        guard turns(id).contains(where: { $0.endedAt == nil && !$0.isDivider }),
              let activity = cache.cached(url, as: SeatActivity?.self, {
                  (try? Data(contentsOf: url)).flatMap { try? Self.decoder.decode(SeatActivity.self, from: $0) }
              }) ?? nil, !activity.finished
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

    /// `IntakeJSON.decoder`'s dates, parsed with a format style made once rather than a new
    /// `ISO8601DateFormatter` per date: a poll decodes a date or two per turn, and that
    /// formatter's setup was most of a poll's cost (measured: `ThreadStoreReadCostTests`).
    /// Accepts the same two forms, with and without fractional seconds.
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        let fractional = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        let whole = Date.ISO8601FormatStyle()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            if let date = try? fractional.parse(s) { return date }
            if let date = try? whole.parse(s) { return date }
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "Invalid ISO8601 date: \(s)")
        }
        return d
    }()
}

/// A file's identity for the read cache: an atomic replace gives it a new inode, an append a
/// new size, and any write a new mtime. A missing file has its own stamp, so a file appearing
/// or vanishing is a change too.
struct FileStamp: Hashable, Sendable {
    var inode: UInt64, size: Int64, seconds: Int, nanoseconds: Int

    init(_ url: URL) {
        var s = Darwin.stat()
        guard stat(url.path, &s) == 0 else { self.init(inode: 0, size: -1, seconds: 0, nanoseconds: 0); return }
        self.init(inode: UInt64(s.st_ino), size: Int64(s.st_size), seconds: s.st_mtimespec.tv_sec,
                  nanoseconds: s.st_mtimespec.tv_nsec)
    }

    init(inode: UInt64, size: Int64, seconds: Int, nanoseconds: Int) {
        self.inode = inode; self.size = size; self.seconds = seconds; self.nanoseconds = nanoseconds
    }
}

/// Parsed files by path, each kept while its stamp holds. A class under a lock so the struct
/// that owns it stays a value every copy of which shares the same cache, from any thread.
final class ReadCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (stamp: FileStamp, value: Any)] = [:]

    /// `url`'s parse: the cached one when its stamp is unchanged, else `parse()`'s, kept.
    /// Stamped before parsing, so a write that lands mid-parse leaves a stamp that won't match
    /// next time, and the file is read again.
    func cached<T>(_ url: URL, as type: T.Type, _ parse: () -> T) -> T? {
        let stamp = FileStamp(url)
        if let hit = lock.withLock({ entries[url.path] }), hit.stamp == stamp, let value = hit.value as? T { return value }
        let value = parse()
        lock.withLock { entries[url.path] = (stamp, value) }
        return value
    }
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
