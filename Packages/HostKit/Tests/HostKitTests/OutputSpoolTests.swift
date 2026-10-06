import XCTest
@testable import HostKit

final class OutputSpoolTests: XCTestCase {
    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spool-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testAppendAssignsOffsetsAcrossStreamsAndReplaysInOrder() throws {
        let spool = try OutputSpool(directory: try tempDir())
        XCTAssertEqual(try spool.append(Data("ab".utf8), to: .stdout), 0)
        XCTAssertEqual(try spool.append(Data("cde".utf8), to: .stderr), 2)
        XCTAssertEqual(try spool.append(Data("f".utf8), to: .stdout), 5)
        XCTAssertEqual(spool.end, 6)

        let all = try spool.read(from: 0)
        XCTAssertEqual(all, [
            SpoolChunk(stream: .stdout, offset: 0, data: Data("ab".utf8)),
            SpoolChunk(stream: .stderr, offset: 2, data: Data("cde".utf8)),
            SpoolChunk(stream: .stdout, offset: 5, data: Data("f".utf8)),
        ])
        // From mid-chunk: only the bytes at and after the offset, so a resume repeats nothing.
        XCTAssertEqual(try spool.read(from: 3), [
            SpoolChunk(stream: .stderr, offset: 3, data: Data("de".utf8)),
            SpoolChunk(stream: .stdout, offset: 5, data: Data("f".utf8)),
        ])
        XCTAssertEqual(try spool.read(from: 6), [])
    }

    /// One file per stream under the run's directory, so `logs` survives in plain files.
    func testEachStreamHasItsOwnFile() throws {
        let dir = try tempDir()
        let spool = try OutputSpool(directory: dir)
        try spool.append(Data("out".utf8), to: .stdout)
        try spool.append(Data("err".utf8), to: .stderr)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("stdout")), Data("out".utf8))
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent("stderr")), Data("err".utf8))
    }

    func testSpoolCapDropsOldestWithMarker() throws {
        let dir = try tempDir()
        let cap: Int64 = 1000
        let spool = try OutputSpool(directory: dir, cap: cap, markerStream: .stderr)
        var written = Data()
        for i in 0..<100 {
            let line = Data(String(format: "line %04d ----------------------------------\n", i).utf8)
            written.append(line)
            try spool.append(line, to: .stdout)
        }
        XCTAssertEqual(spool.end, Int64(written.count), "offsets count every byte ever produced")
        XCTAssertGreaterThan(spool.start, 0, "the oldest output was dropped")
        XCTAssertLessThanOrEqual(spool.end - spool.start, cap)

        // On disk too: the cap is what bounds the host's disk, not just what is replayed.
        let onDisk = try FileManager.default.attributesOfItem(
            atPath: dir.appendingPathComponent("stdout").path)[.size] as! NSNumber
        XCTAssertLessThanOrEqual(onDisk.int64Value, cap)

        let chunks = try spool.read(from: 0, maxBytes: Int(cap) * 2)
        let marker = try XCTUnwrap(chunks.first)
        XCTAssertEqual(marker.stream, .stderr)
        XCTAssertTrue(String(decoding: marker.data, as: UTF8.self).contains("dropped"))
        // The marker ends exactly where retained output begins, so a client resuming after it
        // (offset + count) lands on the first retained byte: nothing retained is skipped.
        XCTAssertEqual(marker.offset + Int64(marker.data.count), spool.start)

        let rest = chunks.dropFirst()
        XCTAssertEqual(rest.first?.offset, spool.start)
        let retained = rest.reduce(into: Data()) { $0.append($1.data) }
        XCTAssertEqual(retained, written.suffix(retained.count), "what is kept is the newest output, intact")
        XCTAssertEqual(Int64(retained.count), spool.end - spool.start)

        // Reading from inside the retained window carries no marker.
        XCTAssertEqual(try spool.read(from: spool.start).first?.offset, spool.start)
    }

    func testReadIsBoundedByMaxBytes() throws {
        let spool = try OutputSpool(directory: try tempDir())
        for _ in 0..<10 { try spool.append(Data(repeating: 65, count: 100), to: .stdout) }
        let first = try spool.read(from: 0, maxBytes: 250)
        XCTAssertLessThanOrEqual(first.reduce(0) { $0 + $1.data.count }, 250)
        XCTAssertFalse(first.isEmpty)
    }
}

extension OutputSpoolTests {
    /// The pump appends whatever one `read(2)` returned, so a chatty build is many small
    /// appends. An index entry per append grew hostd's memory with every line a run ever
    /// printed; contiguous appends to one stream now share an entry, up to one read chunk.
    func testContiguousAppendsShareAnIndexEntry() throws {
        let spool = try OutputSpool(directory: try tempDir())
        var expected = Data()
        for i in 0..<100_000 {
            let line = Data("l\(i % 10)\n".utf8)
            try spool.append(line, to: .stdout)
            expected.append(line)
        }
        // 300 KB in 64 KiB entries.
        XCTAssertLessThanOrEqual(spool.entryCount, 5)

        var replay = Data()
        var pos: Int64 = 0
        while case let chunks = try spool.read(from: pos), !chunks.isEmpty {
            for c in chunks {
                XCTAssertEqual(c.offset, pos)
                XCTAssertLessThanOrEqual(c.data.count, OutputSpool.maxChunk)
                replay.append(c.data)
                pos += Int64(c.data.count)
            }
        }
        XCTAssertEqual(replay, expected)

        // A switch of stream starts a new entry, so interleaved output keeps its order.
        try spool.append(Data("e".utf8), to: .stderr)
        try spool.append(Data("o".utf8), to: .stdout)
        XCTAssertEqual(try spool.read(from: Int64(expected.count)).map(\.stream), [.stderr, .stdout])
    }

    /// Merged entries still let the cap drop old output: an entry never outgrows one chunk.
    func testMergedEntriesStillCompactUnderTheCap() throws {
        let cap: Int64 = 256 << 10
        let spool = try OutputSpool(directory: try tempDir(), cap: cap)
        for _ in 0..<20_000 { try spool.append(Data(repeating: 0x61, count: 64), to: .stdout) }
        XCTAssertLessThanOrEqual(spool.end - spool.start, cap)
        XCTAssertGreaterThan(spool.start, 0)
    }
}
