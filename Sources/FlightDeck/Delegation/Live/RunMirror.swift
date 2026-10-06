import Foundation
import HostKit

/// This Mac's copy of one run's output and events, on disk (Ruling 21: the app keeps a copy of
/// every run's output, replays from it, and asks the host only for what it lacks), so a subscriber from
/// any offset — after the run ended, or after the app relaunched — is served without asking the
/// host again. The host's spool is not enough on its own: the host streams a run's events to
/// each attached connection from wherever it attached, so behind that point only a copy kept
/// here can answer.
///
/// Not HostKit's `OutputSpool`, which it mirrors in arithmetic: the spool's index lives only in
/// memory (a run never outlives hostd), it numbers bytes itself from 0, and it cannot hold a
/// gap. This file must survive a relaunch, record the host's own offsets, and may begin at any
/// offset — a fresh install that first sees a run mid-way — or skip bytes the host's spool had
/// already dropped.
///
/// **Format.** Append-only records, `[u8 kind][u32 BE length][payload]`:
/// - `origin` (an Int64): the offset this copy starts at; it covers every offset from there on.
/// - `output`: `[u8 stream][i64 BE offset][bytes]`.
/// - `event`: a `queued`/`started`/`exited`/`serviceDied` as its wire JSON.
///
/// A record cut short by a crash ends the file: it is truncated there on open.
///
/// **Cap.** `OutputSpool`'s: past `cap` bytes between the first retained offset and the end,
/// the oldest output records go, down to half the cap, by rewriting the file. A read from
/// before the retained window (but after the origin) starts with the spool's marker line,
/// ending exactly at the first retained byte.
///
/// **Its index is main-actor confined, its file I/O is not.** `RunFeed` drives it on the main
/// actor, and every append, rewrite and replay read would otherwise be a syscall there per
/// output chunk. So the index (`entries`, `size`) is updated at once, on main, and the bytes
/// go to and from the file on `io`, one serial queue for every mirror: each operation is laid
/// out against the index as it stood when it was queued, and the queue runs them in that same
/// order, so a read always finds the file the index describes. Opening a mirror waits for the
/// queue first, so a copy reopened (a pruned feed, a relaunch in a test) sees every write
/// made through the one before it.
@MainActor
final class RunMirror {
    struct Chunk: Equatable {
        let stream: RunOutputStream
        let offset: Int64
        let data: Data
        var end: Int64 { offset + Int64(data.count) }
    }

    private enum Kind: UInt8 { case origin = 0, output = 1, event = 2 }

    private struct Entry {
        let stream: RunOutputStream
        let offset: Int64
        /// Where the bytes start in the file.
        let filePosition: UInt64
        let length: Int
        var end: Int64 { offset + Int64(length) }
    }

    nonisolated private static let io = DispatchQueue(label: "dev.flightdeck.delegation.mirror", qos: .utility)

    private(set) var url: URL
    private let cap: Int64
    private var entries: [Entry] = []
    private var size: UInt64 = 0

    /// The offset this copy covers from; nil when it holds nothing yet.
    private(set) var origin: Int64?
    /// One past the newest byte held.
    private(set) var end: Int64 = 0
    /// The run's latest `queued`/`started`.
    private(set) var state: RunEvent?
    /// How it ended, once it has.
    private(set) var exit: RunEvent?

    init(url: URL, cap: Int64 = OutputSpool.defaultCap) {
        self.url = url
        self.cap = cap
        load()
    }

    /// Blocks until every queued write has reached the disk: for tests that read a mirror's
    /// file directly, and for a sweep that must not delete a file mid-write.
    nonisolated static func waitForIO() { io.sync {} }

    /// The first retained offset: past the origin once the cap has dropped output.
    var start: Int64 { entries.first?.offset ?? end }

    /// Whether a subscriber from `offset` can be served from here alone.
    func covers(_ offset: Int64) -> Bool {
        guard let origin else { return false }
        return offset >= origin
    }

    /// Starts over from `offset`: what was held is replaced by a host replay from there.
    func reset(origin offset: Int64) {
        entries = []
        size = 0
        origin = offset
        end = offset
        state = nil
        exit = nil
        rewrite(keeping: [])
    }

    /// Holds the part of `chunk` past `end`; a chunk starting after it leaves a gap, which is
    /// output the host no longer has.
    func append(_ chunk: Chunk) {
        guard origin != nil, chunk.end > end else { return }
        let skip = Int(max(0, end - chunk.offset))
        let offset = chunk.offset + Int64(skip)
        let data = chunk.data.dropFirst(skip)
        var payload = Data([Self.code(chunk.stream)])
        payload.append(Self.bytes(offset))
        payload.append(data)
        let position = write(.output, payload)
        entries.append(Entry(stream: chunk.stream, offset: offset, filePosition: position + 14, length: data.count))
        end = chunk.end
        if end - start > cap { compact() }
    }

    /// Records a state or the end.
    func record(_ event: RunEvent) {
        guard origin != nil, let json = try? JSONEncoder().encode(event) else { return }
        switch event {
        case .queued, .started: state = event
        case .exited, .serviceDied: exit = event
        case .output: return
        }
        write(.event, json)
    }

    /// The held output at or after `offset`, at most `OutputSpool.maxChunk` of it, read off the
    /// main actor: the spool's marker when the cap dropped what was asked for, then the bytes
    /// from there (or from the next byte held, past a gap the host dropped). Nil once there is
    /// nothing more, or the disk would not give it back.
    ///
    /// One chunk per call, so a replay of a whole copy goes out a chunk at a time with the
    /// main actor free between them, rather than as one burst that outruns the socket.
    func chunk(from offset: Int64) async -> Chunk? {
        guard let origin, offset < end else { return nil }
        let position = max(offset, origin)
        if position < start { return marker(from: position) }
        // Binary search: a 64 MiB copy holds tens of thousands of records.
        var low = 0, high = entries.count
        while low < high {
            let mid = (low + high) / 2
            if entries[mid].end <= position { low = mid + 1 } else { high = mid }
        }
        guard low < entries.count else { return nil }
        let entry = entries[low]
        let at = max(position, entry.offset)
        let skip = Int(at - entry.offset)
        let take = min(entry.length - skip, OutputSpool.maxChunk)
        let url = url
        let filePosition = entry.filePosition + UInt64(skip)
        let data: Data? = await withCheckedContinuation { continuation in
            Self.io.async {
                guard let handle = try? FileHandle(forReadingFrom: url) else { return continuation.resume(returning: nil) }
                defer { try? handle.close() }
                guard (try? handle.seek(toOffset: filePosition)) != nil else { return continuation.resume(returning: nil) }
                continuation.resume(returning: try? handle.read(upToCount: take))
            }
        }
        guard let data, data.count == take else { return nil }
        return Chunk(stream: entry.stream, offset: at, data: data)
    }

    /// Renames the copy, for a run whose local id was not known when its first output arrived.
    func move(to destination: URL) {
        guard destination != url else { return }
        let source = url
        url = destination
        Self.io.async {
            let fm = FileManager.default
            try? fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: destination)
            try? fm.moveItem(at: source, to: destination)
        }
    }

    func delete() {
        let url = url
        Self.io.async { try? FileManager.default.removeItem(at: url) }
        entries = []
        size = 0
        origin = nil
        end = 0
        state = nil
        exit = nil
    }

    // MARK: File

    /// Reads the index back: record headers only, plus the small event records. The output
    /// bytes stay on disk (mapped, never copied) until a reader asks for them.
    private func load() {
        let url = url
        guard let data = Self.io.sync(execute: { try? Data(contentsOf: url, options: .alwaysMapped) }) else { return }
        var at = 0
        while at + 5 <= data.count {
            let kind = data[data.startIndex + at]
            let length = Int(Self.uint32(data, at + 1))
            let body = at + 5
            guard body + length <= data.count else { break }
            switch Kind(rawValue: kind) {
            case .origin where length == 8:
                origin = Self.int64(data, body)
                end = origin ?? 0
            case .output where length >= 9:
                guard let stream = Self.stream(data[data.startIndex + body]) else { break }
                let offset = Self.int64(data, body + 1)
                entries.append(Entry(stream: stream, offset: offset, filePosition: UInt64(body + 9), length: length - 9))
                end = offset + Int64(length - 9)
            case .event:
                let payload = data.subdata(in: (data.startIndex + body)..<(data.startIndex + body + length))
                switch try? JSONDecoder().decode(RunEvent.self, from: payload) {
                case .some(let event):
                    switch event {
                    case .queued, .started: state = event
                    case .exited, .serviceDied: exit = event
                    case .output: break
                    }
                case .none: break
                }
            default:
                break
            }
            at = body + length
        }
        size = UInt64(at)
        if at < data.count {
            // A record a crash cut short: dropped, so the next append lands after a whole one.
            let size = size
            Self.io.async {
                guard let handle = try? FileHandle(forWritingTo: url) else { return }
                try? handle.truncate(atOffset: size)
                try? handle.close()
            }
        }
    }

    /// Appends one record and returns where it starts. Laid out now, written on `io`; a write
    /// the disk refuses leaves the copy holding less than its index says, so a replay of that
    /// range ends early and a later subscriber is served by the host.
    @discardableResult
    private func write(_ kind: Kind, _ payload: Data) -> UInt64 {
        var record = Data([kind.rawValue])
        record.append(Self.bytes(UInt32(payload.count)))
        record.append(payload)
        let position = size
        size += UInt64(record.count)
        let url = url
        Self.io.async {
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                fm.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            try? handle.seek(toOffset: position)
            try? handle.write(contentsOf: record)
        }
        return position
    }

    /// `OutputSpool.compact`'s rule: whole output records off the front until at most half
    /// the cap remains.
    private func compact() {
        var drop = 0
        var newStart = start
        while drop < entries.count - 1, end - newStart > cap / 2 {
            newStart += Int64(entries[drop].length)
            drop += 1
        }
        rewrite(keeping: Array(entries[drop...]))
    }

    /// Writes the file afresh — origin, state, end, then `kept` — and renames it over the old
    /// one, so a crash mid-rewrite leaves the previous copy whole. The new layout is fixed here;
    /// the kept bytes are copied out of the old file on `io`.
    private func rewrite(keeping kept: [Entry]) {
        var header = Data()
        func put(_ kind: Kind, _ payload: Data) {
            header.append(kind.rawValue)
            header.append(Self.bytes(UInt32(payload.count)))
            header.append(payload)
        }
        if let origin { put(.origin, Self.bytes(origin)) }
        for event in [state, exit].compactMap({ $0 }) {
            if let json = try? JSONEncoder().encode(event) { put(.event, json) }
        }
        var position = UInt64(header.count)
        var rewritten: [Entry] = []
        for entry in kept {
            rewritten.append(Entry(stream: entry.stream, offset: entry.offset, filePosition: position + 14, length: entry.length))
            position += 14 + UInt64(entry.length)
        }
        let url = url
        Self.io.async {
            var out = header
            if !kept.isEmpty {
                guard let old = try? FileHandle(forReadingFrom: url) else { return }
                defer { try? old.close() }
                for entry in kept {
                    guard (try? old.seek(toOffset: entry.filePosition)) != nil,
                          let data = try? old.read(upToCount: entry.length), data.count == entry.length
                    else { return }
                    out.append(Kind.output.rawValue)
                    out.append(Self.bytes(UInt32(9 + entry.length)))
                    out.append(Self.code(entry.stream))
                    out.append(Self.bytes(entry.offset))
                    out.append(data)
                }
            }
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let temp = url.appendingPathExtension("compact")
            guard (try? out.write(to: temp)) != nil else { return }
            _ = rename(temp.path, url.path)
        }
        entries = rewritten
        size = position
    }

    /// The spool's marker, so a reader cannot tell which copy answered.
    private func marker(from position: Int64) -> Chunk {
        let dropped = start - position
        var text = Data("[flightdeck: \(dropped) bytes of earlier output dropped (spool cap)]\n".utf8)
        if Int64(text.count) > dropped { text = Data(text.prefix(Int(dropped) - 1)) + Data("\n".utf8) }
        return Chunk(stream: .stderr, offset: start - Int64(text.count), data: text)
    }

    // MARK: Encoding

    nonisolated private static let streams: [RunOutputStream] = [.stdout, .stderr, .pty]
    nonisolated private static func code(_ stream: RunOutputStream) -> UInt8 { UInt8(streams.firstIndex(of: stream) ?? 0) }
    nonisolated private static func stream(_ code: UInt8) -> RunOutputStream? { Int(code) < streams.count ? streams[Int(code)] : nil }

    nonisolated private static func bytes(_ value: Int64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    nonisolated private static func bytes(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }

    nonisolated private static func int64(_ data: Data, _ at: Int) -> Int64 {
        data.subdata(in: (data.startIndex + at)..<(data.startIndex + at + 8)).reduce(Int64(0)) { $0 << 8 | Int64($1) }
    }

    nonisolated private static func uint32(_ data: Data, _ at: Int) -> UInt32 {
        data.subdata(in: (data.startIndex + at)..<(data.startIndex + at + 4)).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
}
