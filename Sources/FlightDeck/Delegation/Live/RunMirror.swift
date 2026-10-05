import Foundation
import HostKit

/// This Mac's copy of one run's output and events, on disk (ruling 21), so a subscriber from
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
/// Main-actor confined, through `RunFeed`. Its writes are small appends; the rewrite at the cap
/// copies at most half the cap, once per half-cap of output.
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
    }

    let url: URL
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
        guard let position = write(.output, payload) else { return }
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

    /// Everything held from `offset` on, oldest first, in chunks of at most
    /// `OutputSpool.maxChunk`; the spool's marker first when the cap dropped what was asked for.
    func read(from offset: Int64) -> [Chunk] {
        guard let origin, offset < end else { return [] }
        var out: [Chunk] = []
        var position = max(offset, origin)
        if position < start {
            out.append(marker(from: position))
            position = start
        }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return out }
        defer { try? handle.close() }
        for entry in entries where entry.offset + Int64(entry.length) > position {
            var at = max(position, entry.offset)
            while at < entry.offset + Int64(entry.length) {
                let skip = Int(at - entry.offset)
                let take = min(entry.length - skip, OutputSpool.maxChunk)
                guard (try? handle.seek(toOffset: entry.filePosition + UInt64(skip))) != nil,
                      let data = try? handle.read(upToCount: take), data.count == take
                else { return out }
                out.append(Chunk(stream: entry.stream, offset: at, data: data))
                at += Int64(take)
            }
            position = at
        }
        return out
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
        entries = []
        size = 0
        origin = nil
        end = 0
        state = nil
        exit = nil
    }

    // MARK: File

    private func load() {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return }
        var at = 0
        while at + 5 <= data.count {
            let kind = data[data.startIndex + at]
            let length = Int(Self.uint32(data, at + 1))
            let body = at + 5
            guard body + length <= data.count else { break }
            let payload = data.subdata(in: (data.startIndex + body)..<(data.startIndex + body + length))
            switch Kind(rawValue: kind) {
            case .origin where length == 8:
                origin = Self.int64(payload, 0)
                end = origin ?? 0
            case .output where length >= 9:
                guard let stream = Self.stream(payload[payload.startIndex]) else { break }
                let offset = Self.int64(payload, 1)
                entries.append(Entry(stream: stream, offset: offset, filePosition: UInt64(body + 9), length: length - 9))
                end = offset + Int64(length - 9)
            case .event:
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
        if at < data.count, let handle = try? FileHandle(forWritingTo: url) {
            // A record a crash cut short: dropped, so the next append lands after a whole one.
            try? handle.truncate(atOffset: size)
            try? handle.close()
        }
    }

    /// Appends one record; returns where it starts, nil when the disk refused it (the copy then
    /// simply holds less, and a later subscriber is served by the host).
    @discardableResult
    private func write(_ kind: Kind, _ payload: Data) -> UInt64? {
        var record = Data([kind.rawValue])
        record.append(Self.bytes(UInt32(payload.count)))
        record.append(payload)
        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return nil }
        defer { try? handle.close() }
        let position = size
        do {
            try handle.seek(toOffset: position)
            try handle.write(contentsOf: record)
        } catch {
            return nil
        }
        size += UInt64(record.count)
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
    /// one, so a crash mid-rewrite leaves the previous copy whole.
    private func rewrite(keeping kept: [Entry]) {
        var old: FileHandle?
        if !kept.isEmpty { old = try? FileHandle(forReadingFrom: url) }
        defer { try? old?.close() }
        var out = Data()
        var rewritten: [Entry] = []
        func put(_ kind: Kind, _ payload: Data) {
            out.append(kind.rawValue)
            out.append(Self.bytes(UInt32(payload.count)))
            out.append(payload)
        }
        if let origin { put(.origin, Self.bytes(origin)) }
        for event in [state, exit].compactMap({ $0 }) {
            if let json = try? JSONEncoder().encode(event) { put(.event, json) }
        }
        for entry in kept {
            guard let old, (try? old.seek(toOffset: entry.filePosition)) != nil,
                  let data = try? old.read(upToCount: entry.length), data.count == entry.length
            else { break }
            var payload = Data([Self.code(entry.stream)])
            payload.append(Self.bytes(entry.offset))
            payload.append(data)
            let position = UInt64(out.count)
            put(.output, payload)
            rewritten.append(Entry(stream: entry.stream, offset: entry.offset, filePosition: position + 14, length: entry.length))
        }
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let temp = url.appendingPathExtension("compact")
        guard (try? out.write(to: temp)) != nil, rename(temp.path, url.path) == 0 else { return }
        entries = rewritten
        size = UInt64(out.count)
    }

    /// The spool's marker, so a reader cannot tell which copy answered.
    private func marker(from position: Int64) -> Chunk {
        let dropped = start - position
        var text = Data("[flightdeck: \(dropped) bytes of earlier output dropped (spool cap)]\n".utf8)
        if Int64(text.count) > dropped { text = Data(text.prefix(Int(dropped) - 1)) + Data("\n".utf8) }
        return Chunk(stream: .stderr, offset: start - Int64(text.count), data: text)
    }

    // MARK: Encoding

    private static let streams: [RunOutputStream] = [.stdout, .stderr, .pty]
    private static func code(_ stream: RunOutputStream) -> UInt8 { UInt8(streams.firstIndex(of: stream) ?? 0) }
    private static func stream(_ code: UInt8) -> RunOutputStream? { Int(code) < streams.count ? streams[Int(code)] : nil }

    private static func bytes(_ value: Int64) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }
    private static func bytes(_ value: UInt32) -> Data { withUnsafeBytes(of: value.bigEndian) { Data($0) } }

    private static func int64(_ data: Data, _ at: Int) -> Int64 {
        data.subdata(in: (data.startIndex + at)..<(data.startIndex + at + 8)).reduce(Int64(0)) { $0 << 8 | Int64($1) }
    }

    private static func uint32(_ data: Data, _ at: Int) -> UInt32 {
        data.subdata(in: (data.startIndex + at)..<(data.startIndex + at + 4)).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }
}
