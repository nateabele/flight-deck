import Foundation
import XCTest
@testable import FlightDeck

/// A fake index daemon: a real Unix socket that answers each request line with the next canned
/// reply line and records what it was sent. Never the machine's real daemon socket.
final class FakeIndexSocket: @unchecked Sendable {
    let path: String
    private let dir: String
    private let fd: Int32
    private let lock = NSLock()
    private var replies: [String]
    private var received: [String] = []
    /// When set, the server reads the request and never answers (a wedged daemon).
    let silent: Bool

    init(replies: [String], silent: Bool = false) {
        // Short and in /tmp: a unix socket path is capped at 103 bytes.
        dir = "/tmp/fdis-\(UUID().uuidString.prefix(8))"
        mkdir(dir, 0o700)
        path = dir + "/fdindex.sock"
        self.replies = replies
        self.silent = silent
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        _ = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        listen(fd, 8)
        let thread = Thread { [self] in serve() }
        thread.start()
    }

    var requests: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return received.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    func close() {
        shutdown(fd, SHUT_RDWR)
        Darwin.close(fd)
        unlink(path)
        rmdir(dir)
    }

    private func serve() {
        while true {
            let conn = accept(fd, nil, nil)
            if conn < 0 { return }
            var line = Data()
            var byte: UInt8 = 0
            while read(conn, &byte, 1) == 1, byte != UInt8(ascii: "\n") { line.append(byte) }
            lock.lock()
            received.append(String(decoding: line, as: UTF8.self))
            let reply = replies.isEmpty ? nil : replies.removeFirst()
            lock.unlock()
            if silent {
                // Hold the connection open until the client gives up.
                while read(conn, &byte, 1) == 1 {}
            } else if let reply {
                let out = Array((reply + "\n").utf8)
                _ = out.withUnsafeBytes { write(conn, $0.baseAddress, $0.count) }
            }
            Darwin.close(conn)
        }
    }
}

enum IndexStatusFixture {
    /// A `status` reply shaped like `Service::status`'s, trimmed to what the app reads plus a
    /// field it does not (`graphs`), which must be ignored.
    static let running = """
    {"id":1,"ok":true,"text":"fdindex 0.1.0","data":{"version":"0.1.0","protocol":1,"pid":4242,"uptime_seconds":125,\
    "rss_bytes":327680000,"memory_target":1073741824,"requests":90,"errors":2,\
    "last_error":{"state":"ERROR","tool":"read","message":"git cat-file failed","seconds_ago":300},\
    "views":[{"worktree":"/w/tessera-wt/feature-x","repo":"tessera","requests":7,"idle_seconds":4,"dirty_files":2},\
    {"worktree":"/w/formula-editor","repo":"formula-editor","requests":1,"idle_seconds":600}],\
    "builds":[{"worktree":"/w/tessera-wt/feature-x","phase":"Parsing","done":40,"total":1636,"running_seconds":1.5}],\
    "stores":[{"name":"a.db","repo":"/w/tessera/.git","bytes":52428800},{"name":"b.db","repo":"/w/fe/.git","bytes":31457280}],\
    "graphs":{"count":1}}}
    """
}

final class IndexDaemonClientTests: XCTestCase {
    private var servers: [FakeIndexSocket] = []

    override func tearDown() {
        servers.forEach { $0.close() }
        servers = []
        super.tearDown()
    }

    private func server(_ replies: [String], silent: Bool = false) -> FakeIndexSocket {
        let s = FakeIndexSocket(replies: replies, silent: silent)
        servers.append(s)
        return s
    }

    func testStatusSendsAVersionlessStatusRequestAndDecodesTheData() throws {
        let s = server([IndexStatusFixture.running])
        let status = try IndexDaemonClient(socketPath: s.path).status()
        XCTAssertEqual(s.requests.first?["tool"] as? String, "status")
        // No `v`: a daemon newer than the app still answers instead of VERSION_MISMATCH.
        XCTAssertNil(s.requests.first?["v"])
        XCTAssertEqual(status.version, "0.1.0")
        XCTAssertEqual(status.pid, 4242)
        XCTAssertEqual(status.rssBytes, 327_680_000)
        XCTAssertEqual(status.memoryTarget, 1_073_741_824)
        XCTAssertEqual(status.views?.count, 2)
        XCTAssertEqual(status.views?.first?.idleSeconds, 4)
        XCTAssertEqual(status.builds?.first?.total, 1636)
        XCTAssertEqual(status.storeBytes, 83_886_080)
        XCTAssertEqual(status.lastError?.tool, "read")
        XCTAssertEqual(status.lastError?.secondsAgo, 300)
    }

    func testAnOlderDaemonWithFewerFieldsStillDecodes() throws {
        let s = server([#"{"id":1,"ok":true,"data":{"pid":7}}"#])
        let status = try IndexDaemonClient(socketPath: s.path).status()
        XCTAssertEqual(status.pid, 7)
        XCTAssertNil(status.views)
        XCTAssertNil(status.lastError)
        XCTAssertEqual(status.storeBytes, 0)
    }

    func testNoSocketIsNotRunning() {
        let path = "/tmp/fdis-none-\(UUID().uuidString.prefix(8)).sock"
        XCTAssertThrowsError(try IndexDaemonClient(socketPath: path).status()) {
            XCTAssertEqual($0 as? IndexDaemonError, .notRunning)
        }
    }

    func testARefusalCarriesTheDaemonsMessage() {
        let s = server([#"{"id":1,"ok":false,"error":"store is locked","state":"ERROR"}"#])
        XCTAssertThrowsError(try IndexDaemonClient(socketPath: s.path).status()) {
            XCTAssertEqual($0 as? IndexDaemonError, .refused(state: "ERROR", message: "store is locked"))
        }
    }

    func testGarbageAndAMissingDataFieldAreProtocolErrors() {
        let s = server(["not json", #"{"id":1,"ok":true,"text":"no data"}"#])
        let client = IndexDaemonClient(socketPath: s.path)
        XCTAssertThrowsError(try client.status()) { XCTAssertEqual($0 as? IndexDaemonError, .protocolError) }
        XCTAssertThrowsError(try client.status()) { XCTAssertEqual($0 as? IndexDaemonError, .protocolError) }
    }

    func testAWedgedDaemonTimesOutInsteadOfHanging() {
        let s = server([], silent: true)
        var client = IndexDaemonClient(socketPath: s.path)
        client.timeout = 0.3
        let start = Date()
        XCTAssertThrowsError(try client.status()) { XCTAssertEqual($0 as? IndexDaemonError, .timedOut) }
        XCTAssertLessThan(Date().timeIntervalSince(start), 2)
    }

    func testShutdownSendsShutdown() throws {
        let s = server([#"{"id":1,"ok":true,"text":"shutting down"}"#])
        try IndexDaemonClient(socketPath: s.path).shutdown()
        XCTAssertEqual(s.requests.first?["tool"] as? String, "shutdown")
    }

    func testTheDefaultSocketFollowsTheDaemonsOwnRules() {
        XCTAssertEqual(IndexDaemonClient.defaultSocketPath(environment: [:], home: "/Users/n"),
                       "/Users/n/Library/Application Support/FlightDeck/index/fdindex.sock")
        XCTAssertEqual(IndexDaemonClient.defaultSocketPath(environment: ["FLIGHTDECK_INDEX_DIR": "/s/idx"], home: "/Users/n"),
                       "/s/idx/fdindex.sock")
        XCTAssertEqual(IndexDaemonClient.defaultSocketPath(
            environment: ["FLIGHTDECK_INDEX_DIR": "/s/idx", "FLIGHTDECK_INDEX_SOCKET": "/tmp/x.sock"], home: "/Users/n"),
                       "/tmp/x.sock")
    }

    func testRestarterWithoutABinaryStopsOverTheSocketAndSaysSo() throws {
        let s = server([#"{"id":1,"ok":true,"text":"shutting down"}"#])
        let note = try FdindexServiceRestarter(binary: nil, client: IndexDaemonClient(socketPath: s.path)).restart()
        XCTAssertEqual(s.requests.first?["tool"] as? String, "shutdown")
        XCTAssertNotNil(note)
    }

    func testRestarterRunsServiceRestartAndReportsAFailingExit() throws {
        // A stand-in `fdindex` that records its arguments; never the real binary.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fdis-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let args = dir.appendingPathComponent("args")
        let ok = dir.appendingPathComponent("fdindex-ok")
        try "#!/bin/sh\necho \"$@\" > '\(args.path)'\necho stopped\n".write(to: ok, atomically: true, encoding: .utf8)
        let bad = dir.appendingPathComponent("fdindex-bad")
        try "#!/bin/sh\necho 'error: the daemon did not open its socket' >&2\nexit 1\n".write(to: bad, atomically: true, encoding: .utf8)
        for f in [ok, bad] { chmod(f.path, 0o755) }
        let client = IndexDaemonClient(socketPath: "/tmp/fdis-unused.sock")

        XCTAssertNil(try FdindexServiceRestarter(binary: ok, client: client).restart())
        XCTAssertEqual(try String(contentsOf: args, encoding: .utf8), "service restart\n")
        XCTAssertThrowsError(try FdindexServiceRestarter(binary: bad, client: client).restart()) {
            XCTAssertEqual($0 as? IndexDaemonError, .system("error: the daemon did not open its socket"))
        }
    }
}

/// The view model against fake transports and a fake restarter: no socket the real daemon owns
/// is ever opened, and nothing is restarted.
@MainActor
final class IndexStatusModelTests: XCTestCase {
    /// Answers from a script of outcomes, one per round trip; the last repeats.
    final class ScriptedTransport: IndexDaemonTransport, @unchecked Sendable {
        private let lock = NSLock()
        private var script: [Result<String, IndexDaemonError>]
        private(set) var calls = 0
        init(_ script: [Result<String, IndexDaemonError>]) { self.script = script }
        func roundTrip(_ line: Data, socketPath: String, timeout: TimeInterval) throws -> Data {
            lock.lock(); defer { lock.unlock() }
            calls += 1
            let next = script.count > 1 ? script.removeFirst() : script[0]
            return Data(try next.get().utf8)
        }
    }

    final class FakeRestarter: IndexDaemonRestarting, @unchecked Sendable {
        var outcome: Result<String?, IndexDaemonError> = .success(nil)
        var onRestart: (() -> Void)?
        private(set) var restarts = 0
        func restart() throws -> String? {
            restarts += 1
            onRestart?()
            return try outcome.get()
        }
    }

    private func model(_ transport: ScriptedTransport, _ restarter: FakeRestarter = FakeRestarter()) -> IndexStatusModel {
        IndexStatusModel(client: IndexDaemonClient(socketPath: "/tmp/fdis-fake.sock", transport: transport),
                         restarter: restarter)
    }

    func testStartsUnknownAndReadsNothingUntilRefreshed() {
        let t = ScriptedTransport([.success(IndexStatusFixture.running)])
        let m = model(t)
        XCTAssertEqual(m.state, .unknown)
        XCTAssertEqual(t.calls, 0)
    }

    func testRefreshPublishesRunningStatus() async {
        let m = model(ScriptedTransport([.success(IndexStatusFixture.running)]))
        await m.refresh().value
        guard case .running(let s) = m.state else { return XCTFail("\(m.state)") }
        XCTAssertEqual(s.pid, 4242)
    }

    func testNoDaemonReadsNotRunningAndAWedgedOneFailed() async {
        let m = model(ScriptedTransport([.failure(.notRunning), .failure(.timedOut)]))
        await m.refresh().value
        XCTAssertEqual(m.state, .notRunning)
        await m.refresh().value
        XCTAssertEqual(m.state, .failed("The index daemon is not answering."))
    }

    func testRefreshesDoNotStack() async {
        let t = ScriptedTransport([.success(IndexStatusFixture.running)])
        let m = model(t)
        let a = m.refresh(), b = m.refresh()
        await a.value; await b.value
        XCTAssertEqual(t.calls, 1)
    }

    func testRestartRunsTheRestarterThenReadsTheStatusBack() async {
        let t = ScriptedTransport([.failure(.notRunning), .success(IndexStatusFixture.running)])
        let r = FakeRestarter()
        let m = model(t, r)
        await m.refresh().value
        XCTAssertEqual(m.state, .notRunning)
        let task = m.restart()
        XCTAssertTrue(m.restarting)
        await task.value
        XCTAssertEqual(r.restarts, 1)
        XCTAssertFalse(m.restarting)
        XCTAssertNil(m.actionError)
        guard case .running = m.state else { return XCTFail("\(m.state)") }
    }

    func testASecondRestartWhileOneRunsIsIgnored() async {
        let r = FakeRestarter()
        let m = model(ScriptedTransport([.success(IndexStatusFixture.running)]), r)
        let a = m.restart(), b = m.restart()
        await a.value; await b.value
        XCTAssertEqual(r.restarts, 1)
    }

    func testAFailedRestartIsShownApartFromTheState() async {
        let r = FakeRestarter()
        r.outcome = .failure(.system("launchctl: service not found"))
        let m = model(ScriptedTransport([.success(IndexStatusFixture.running)]), r)
        await m.restart().value
        XCTAssertEqual(m.actionError, "Restart failed: launchctl: service not found")
        guard case .running = m.state else { return XCTFail("\(m.state)") }
    }

    func testARestartNoteIsShown() async {
        let r = FakeRestarter()
        r.outcome = .success("Stopped.")
        let m = model(ScriptedTransport([.failure(.notRunning)]), r)
        await m.restart().value
        XCTAssertEqual(m.actionNote, "Stopped.")
    }

    func testAStatusReadBeforeARestartCannotOverwriteWhatCameAfter() async {
        // The refresh in flight when Restart is pressed read the old daemon; its answer must
        // not land after the restart's own read-back.
        final class GatedTransport: IndexDaemonTransport, @unchecked Sendable {
            let gate = DispatchSemaphore(value: 0)
            private let lock = NSLock()
            private var restarted = false
            func markRestarted() {
                lock.lock(); restarted = true; lock.unlock()
                gate.signal()
            }
            func roundTrip(_ line: Data, socketPath: String, timeout: TimeInterval) throws -> Data {
                lock.lock(); let after = restarted; lock.unlock()
                if after { return Data(#"{"id":1,"ok":true,"data":{"pid":2}}"#.utf8) }   // the new daemon
                gate.wait()   // held until the restart has happened, then answers for the old one
                return Data(#"{"id":1,"ok":true,"data":{"pid":1}}"#.utf8)
            }
        }
        let transport = GatedTransport()
        let r = FakeRestarter()
        r.onRestart = { transport.markRestarted() }
        let m = IndexStatusModel(client: IndexDaemonClient(socketPath: "/tmp/fdis-fake.sock", transport: transport),
                                 restarter: r)
        let stale = m.refresh()
        await m.restart().value
        await stale.value
        guard case .running(let s) = m.state else { return XCTFail("\(m.state)") }
        XCTAssertEqual(s.pid, 2)
    }
}

final class IndexStatusTextTests: XCTestCase {
    private func fixture() throws -> IndexDaemonStatus {
        let reply = try JSONSerialization.jsonObject(with: Data(IndexStatusFixture.running.utf8)) as! [String: Any]
        let data = try JSONSerialization.data(withJSONObject: reply["data"]!)
        return try JSONDecoder().decode(IndexDaemonStatus.self, from: data)
    }

    func testBytesAndDurationsReadAsTheCLIPrintsThem() {
        XCTAssertEqual(IndexStatusText.bytes(104_857_600), "100.0 MB")
        XCTAssertEqual(IndexStatusText.bytes(1_610_612_736), "1.5 GB")
        XCTAssertEqual(IndexStatusText.duration(45), "45s")
        XCTAssertEqual(IndexStatusText.duration(125), "2m05s")
        XCTAssertEqual(IndexStatusText.duration(11_220), "3h07m")
    }

    func testLines() throws {
        let s = try fixture()
        XCTAssertEqual(IndexStatusText.running(s), "Running · fdindex 0.1.0 · pid 4242 · up 2m05s")
        XCTAssertEqual(IndexStatusText.memory(s), "312.5 MB of 1.0 GB target")
        XCTAssertEqual(IndexStatusText.memoryFraction(s)!, 327_680_000.0 / 1_073_741_824.0, accuracy: 1e-9)
        XCTAssertEqual(IndexStatusText.store(s), "80.0 MB in 2 repositories")
        XCTAssertEqual(IndexStatusText.view(s.views![0]), "feature-x (tessera)")
        XCTAssertEqual(IndexStatusText.view(s.views![1]), "formula-editor")
        XCTAssertEqual(IndexStatusText.build(s.builds![0]), "feature-x: Parsing 40 of 1636")
        XCTAssertEqual(IndexStatusText.lastError(s), "read: git cat-file failed (5m00s ago)")
    }

    func testMissingFieldsDegradeLineByLine() {
        let s = IndexDaemonStatus()
        XCTAssertEqual(IndexStatusText.running(s), "Running")
        XCTAssertEqual(IndexStatusText.memory(s), "Unknown")
        XCTAssertNil(IndexStatusText.memoryFraction(s))
        XCTAssertNil(IndexStatusText.lastError(s))
        XCTAssertEqual(IndexStatusText.store(s), "0.0 MB in 0 repositories")
        var noTarget = s
        noTarget.rssBytes = 1_048_576
        noTarget.memoryTarget = 0
        XCTAssertEqual(IndexStatusText.memory(noTarget), "1.0 MB resident")
        XCTAssertNil(IndexStatusText.memoryFraction(noTarget))
    }
}
