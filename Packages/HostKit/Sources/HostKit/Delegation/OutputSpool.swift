import Foundation
#if canImport(Glibc)
import Glibc
#endif

// A run's output on the host's disk (spec §6.1): what lets a run outlive its controller, and a
// reattaching CLI resume from its last offset with nothing lost or repeated.

/// A contiguous piece of one stream at a run-wide byte offset.
public struct SpoolChunk: Sendable, Equatable {
    public let stream: RunOutputStream
    public let offset: Int64
    public let data: Data

    public init(stream: RunOutputStream, offset: Int64, data: Data) {
        self.stream = stream
        self.offset = offset
        self.data = data
    }
}

/// One file per stream under `runs/<id>/`, plus an in-memory index that orders the chunks
/// across streams by a single run-wide offset.
///
/// The index is not persisted: a run does not outlive hostd (its pipes end with it), so there
/// is never a spool to reopen.
///
/// **Cap.** Past `cap` retained bytes the oldest chunks are dropped, down to half the cap, by
/// rewriting the stream files. Dropping half rather than just enough keeps the rewrite cost to
/// about one copied byte per byte written; trimming to exactly the cap would rewrite up to
/// 64 MiB on every chunk of a chatty build.
///
/// **Handles.** Open while the run writes; `closeHandles()` at its end, after which each read
/// opens and closes what it needs. hostd's soft limit is 256 fds, and a spool per finished
/// run holding its files open would exhaust it within about a hundred runs.
///
/// **Marker.** Synthesized on every read and never written to the files: a read from before
/// the retained window starts with a marker line on
/// `markerStream`, placed so it *ends* exactly at the first retained byte. A client resuming at
/// `offset + count` therefore lands on retained output and never skips any of it; the marker
/// stands in for the tail of what was dropped.
public final class OutputSpool: @unchecked Sendable {
    public static let defaultCap: Int64 = 64 << 20
    /// The largest chunk `read` returns, matching the wire's largest event payload (§A3).
    public static let maxChunk = 64 << 10

    private struct Entry {
        let stream: RunOutputStream
        let offset: Int64
        /// Where the bytes sit in the stream's file.
        let fileOffset: UInt64
        let length: Int
    }

    private let directory: URL
    private let cap: Int64
    private let markerStream: RunOutputStream
    private let lock = NSLock()
    private var entries: [Entry] = []
    private var handles: [RunOutputStream: FileHandle] = [:]
    private var keepHandles = true
    private var fileSizes: [RunOutputStream: UInt64] = [:]
    private var _start: Int64 = 0
    private var _end: Int64 = 0

    public init(directory: URL, cap: Int64 = OutputSpool.defaultCap, markerStream: RunOutputStream = .stderr) throws {
        self.directory = directory
        self.cap = cap
        self.markerStream = markerStream
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit {
        for handle in handles.values { try? handle.close() }
    }

    /// The first retained offset.
    public var start: Int64 { lock.withLock { _start } }
    /// One past the last byte ever appended: every byte the run produced, dropped or not.
    public var end: Int64 { lock.withLock { _end } }

    /// Closes the stream files; later reads reopen them only for as long as they need.
    public func closeHandles() {
        lock.withLock {
            keepHandles = false
            closeIdleHandles()
        }
    }

    /// Appends `data` and returns its run-wide offset.
    @discardableResult
    public func append(_ data: Data, to stream: RunOutputStream) throws -> Int64 {
        guard !data.isEmpty else { return end }
        return try lock.withLock {
            defer { closeIdleHandles() }
            let handle = try handle(for: stream)
            let fileOffset = fileSizes[stream, default: 0]
            try handle.seek(toOffset: fileOffset)
            try handle.write(contentsOf: data)
            fileSizes[stream] = fileOffset + UInt64(data.count)
            let offset = _end
            entries.append(Entry(stream: stream, offset: offset, fileOffset: fileOffset, length: data.count))
            _end += Int64(data.count)
            if _end - _start > cap { try compact() }
            return offset
        }
    }

    /// Chunks from `offset` on, at most `maxBytes` of them (but always at least one chunk when
    /// any output lies past `offset`), none larger than `maxChunk`.
    public func read(from offset: Int64, maxBytes: Int = 1 << 20) throws -> [SpoolChunk] {
        try lock.withLock {
            defer { closeIdleHandles() }
            var out: [SpoolChunk] = []
            var budget = maxBytes
            var pos = max(offset, 0)
            if pos < _start {
                out.append(marker(from: pos))
                pos = _start
            }
            // Entries are in offset order; skip to the one containing `pos`.
            var i = firstEntry(containing: pos)
            while i < entries.count {
                let e = entries[i]
                let skip = Int(pos - e.offset)
                let take = min(e.length - skip, Self.maxChunk, max(budget, out.isEmpty ? 1 : 0))
                guard take > 0 else { break }
                let handle = try handle(for: e.stream)
                try handle.seek(toOffset: e.fileOffset + UInt64(skip))
                let data = try handle.read(upToCount: take) ?? Data()
                guard data.count == take else { throw CocoaError(.fileReadCorruptFile) }
                out.append(SpoolChunk(stream: e.stream, offset: pos, data: data))
                budget -= take
                pos += Int64(take)
                if pos == e.offset + Int64(e.length) { i += 1 }
                if budget <= 0 { break }
            }
            return out
        }
    }

    // MARK: - Private (lock held)

    private func handle(for stream: RunOutputStream) throws -> FileHandle {
        if let h = handles[stream] { return h }
        let url = directory.appendingPathComponent(stream.rawValue)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try FileHandle(forUpdating: url)
        handles[stream] = h
        return h
    }

    private func closeIdleHandles() {
        guard !keepHandles else { return }
        for handle in handles.values { try? handle.close() }
        handles = [:]
    }

    private func firstEntry(containing pos: Int64) -> Int {
        var lo = 0, hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if entries[mid].offset + Int64(entries[mid].length) <= pos { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    private func marker(from pos: Int64) -> SpoolChunk {
        let dropped = _start - pos
        var text = Data("[flightdeck: \(dropped) bytes of earlier output dropped (spool cap)]\n".utf8)
        // Never longer than the gap, or the marker would overlap retained offsets.
        if Int64(text.count) > dropped {
            text = Data(text.prefix(Int(dropped) - 1)) + Data("\n".utf8)
        }
        return SpoolChunk(stream: markerStream, offset: _start - Int64(text.count), data: text)
    }

    /// Drops whole chunks from the front until at most half the cap remains, then rewrites
    /// each stream file with only what is kept.
    private func compact() throws {
        var dropCount = 0
        var newStart = _start
        while dropCount < entries.count - 1, _end - newStart > cap / 2 {
            newStart += Int64(entries[dropCount].length)
            dropCount += 1
        }
        let kept = Array(entries[dropCount...])

        var rewritten: [Entry] = []
        var newSizes: [RunOutputStream: UInt64] = [:]
        var temps: [RunOutputStream: FileHandle] = [:]
        defer { for h in temps.values { try? h.close() } }
        for e in kept {
            let src = try handle(for: e.stream)
            try src.seek(toOffset: e.fileOffset)
            let data = try src.read(upToCount: e.length) ?? Data()
            let dst: FileHandle
            if let h = temps[e.stream] {
                dst = h
            } else {
                let tmp = directory.appendingPathComponent(e.stream.rawValue + ".compact")
                FileManager.default.createFile(atPath: tmp.path, contents: nil)
                dst = try FileHandle(forWritingTo: tmp)
                temps[e.stream] = dst
            }
            try dst.write(contentsOf: data)
            let at = newSizes[e.stream, default: 0]
            rewritten.append(Entry(stream: e.stream, offset: e.offset, fileOffset: at, length: e.length))
            newSizes[e.stream] = at + UInt64(e.length)
        }
        // Every stream ever written, not just those with an open handle, so a stream with
        // nothing retained is still emptied.
        for stream in Set(fileSizes.keys).union(handles.keys) {
            try handles[stream]?.close()
            let url = directory.appendingPathComponent(stream.rawValue)
            let tmp = directory.appendingPathComponent(stream.rawValue + ".compact")
            if let t = temps.removeValue(forKey: stream) {
                try t.close()
                // rename(2), not FileManager: atomic over the old file on both platforms.
                guard rename(tmp.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            } else {
                // Nothing of this stream survived: empty its file rather than keep dropped bytes.
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
        }
        handles = [:]
        fileSizes = newSizes
        entries = rewritten
        _start = newStart
    }
}
