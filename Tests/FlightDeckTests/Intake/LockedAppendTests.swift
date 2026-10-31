import XCTest
import IntakeKit

/// `commands.jsonl` is appended by the app, the phone path and the runner, so "read the max seq,
/// then write one above it" has to be one step across processes, not just across threads.
final class LockedAppendTests: XCTestCase {
    private var root: URL!
    private static let childDirKey = "FD_LOCKED_APPEND_DIR"
    private static let childKindKey = "FD_LOCKED_APPEND_KIND"
    private static let linesPerProcess = 500

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("LockedAppend-\(UUID())", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    // MARK: - Two real processes

    /// Not a child on its own: when the parent test re-launches `xctest` on just this method with
    /// the directory in the environment, this is the process that appends. Without the variable
    /// (a normal run) it does nothing.
    func testChildAppender() throws {
        guard let dir = ProcessInfo.processInfo.environment[Self.childDirKey] else {
            throw XCTSkip("only meaningful as the child of the two-process test")
        }
        let kind = ProcessInfo.processInfo.environment[Self.childKindKey] ?? "tape"
        let directory = URL(fileURLWithPath: dir)
        for _ in 0..<Self.linesPerProcess {
            if kind == "thread" {
                _ = try ThreadCommandStore(intakeDirectory: directory).append(.resolve(ThreadID(UUID())))
            } else {
                _ = try TapeStore(intakeDirectory: directory).appendCommand(.step)
            }
        }
    }

    private func runTwoChildren(kind: String) throws {
        let bundle = Bundle(for: Self.self).bundlePath
        let executable = CommandLine.arguments[0]
        var children: [Process] = []
        for _ in 0..<2 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: executable)
            p.arguments = ["-XCTest", "LockedAppendTests/testChildAppender", bundle]
            var env = ProcessInfo.processInfo.environment
            env[Self.childDirKey] = root.path
            env[Self.childKindKey] = kind
            p.environment = env
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            children.append(p)
        }
        // Both started before either is waited on, so their appends genuinely overlap.
        for p in children { try p.run() }
        for p in children { p.waitUntilExit(); XCTAssertEqual(p.terminationStatus, 0) }
    }

    private func assertDistinctSeqs(at url: URL) throws {
        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2 * Self.linesPerProcess)
        var seqs: [Int] = []
        for line in lines {
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            seqs.append(try XCTUnwrap(object?["seq"] as? Int, "torn or seq-less line: \(line)"))
        }
        XCTAssertEqual(Set(seqs).count, 2 * Self.linesPerProcess, "a seq was reused")
        XCTAssertEqual(Set(seqs), Set(1...(2 * Self.linesPerProcess)))
    }

    func testConcurrentAppendsFromTwoProcessesNeverReuseSeq() throws {
        try runTwoChildren(kind: "tape")
        try assertDistinctSeqs(at: TapeStore(intakeDirectory: root).commandsURL)
    }

    func testConcurrentThreadCommandAppendsFromTwoProcessesNeverReuseSeq() throws {
        try runTwoChildren(kind: "thread")
        try assertDistinctSeqs(at: ThreadCommandStore(intakeDirectory: root).commandsURL)
    }

    // MARK: - Torn tail

    /// A crash mid-write can stop inside a multi-byte character. Decoding the whole file as one
    /// UTF-8 string then fails for EVERY line, the max seq reads as 0, and the next command
    /// reuses seq 1, below the runner's cursor, so it is never read.
    func testTornMultibyteTailLosesOnlyTheTornLine() throws {
        let tapes = TapeStore(intakeDirectory: root)
        XCTAssertEqual(try tapes.appendCommand(.step), 1)
        XCTAssertEqual(try tapes.appendCommand(.pause), 2)
        try Self.appendRaw(Data(#"{"seq":3,"command":{"kind":"note","text":"caf"#.utf8) + Data([0xC3]), to: tapes.commandsURL)
        XCTAssertEqual(tapes.commands(after: 0).map(\.seq), [1, 2])
        XCTAssertEqual(try tapes.appendCommand(.stop), 3)
        XCTAssertEqual(tapes.commands(after: 0).map(\.seq), [1, 2, 3])

        let threads = ThreadCommandStore(intakeDirectory: root)
        let id = ThreadID(UUID())
        XCTAssertEqual(try threads.append(.resolve(id)), 1)
        XCTAssertEqual(try threads.append(.resolve(id)), 2)
        try Self.appendRaw(Data(#"{"seq":3,"command":{"text":"caf"#.utf8) + Data([0xC3]), to: threads.commandsURL)
        XCTAssertEqual(threads.commands(after: 0).map(\.seq), [1, 2])
        XCTAssertEqual(try threads.append(.resolve(id)), 3)
    }

    private static func appendRaw(_ data: Data, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}
