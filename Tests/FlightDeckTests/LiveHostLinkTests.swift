import Foundation
import HostKit
import XCTest
@testable import FlightDeck

/// A host connection on cue: records every request, answers from a script, and lets the test
/// push event frames and drop the link.
@MainActor
final class ScriptedTransport: DelegationTransport {
    var isOnline = true
    var capabilities: Set<HostCapability>? = [.hostInfo, .run, .sync, .service, .screen]
    var sent: [(request: DelegationRequest, timeout: TimeInterval)] = []
    var failNext: Error?
    var progresses: [(@MainActor () -> Date)?] = []
    var attachError: Error?
    /// Answers anything the script below does not.
    var answer: ((DelegationRequest) -> DelegationReply?)?

    var attaches: [Int64] {
        sent.compactMap { if case .runAttach(_, let offset) = $0.request { return offset } else { return nil } }
    }

    func send(_ request: DelegationRequest, timeout: TimeInterval,
              progress: (@MainActor () -> Date)?) async throws -> DelegationReply {
        sent.append((request, timeout))
        progresses.append(progress)
        if let failNext {
            self.failNext = nil
            throw failNext
        }
        if let reply = answer?(request) { return reply }
        switch request {
        case .runStart: return .runStart(runID: "r1")
        case .runAttach:
            if let attachError { throw attachError }
            return .runAttach
        case .syncPush: return .syncPush
        default: return .runCancel
        }
    }

    private var nextChannel: ChannelID = 1
    func openChannel() async throws -> any ByteChannel {
        defer { nextChannel += 2 }
        return FakeByteChannel(id: nextChannel, toRead: [])
    }
}

@MainActor
final class LiveHostLinkTests: XCTestCase {
    private var directory: URL!
    private var transport: ScriptedTransport!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-link-\(UUID().uuidString)")
        transport = ScriptedTransport()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// Lets the link's `run.attach` task run.
    private func drain() async {
        for _ in 0..<20 { await Task.yield() }
    }

    private func makeLink() -> LiveHostLink {
        LiveHostLink(name: "mini", transport: transport, mirrors: directory, mirrorPrefix: "slot")
    }

    private func start(_ link: LiveHostLink) async throws {
        let ref = SnapshotRef(repoRoot: String(repeating: "a", count: 40), wtKey: "k", worktreeName: "w",
                              commit: String(repeating: "b", count: 40), tree: String(repeating: "c", count: 40))
        _ = try await link.request(.runStart(ref: ref, spec: RunSpec(command: "make", subdir: "", env: [:], pty: false,
                                                                     screen: false, service: false, downCommand: nil, ports: []),
                                            owner: "tab", apply: true))
    }

    private func out(_ offset: Int64, _ text: String, _ stream: RunOutputStream = .stdout) -> RunEvent {
        .output(stream: stream, offset: offset, data: Data(text.utf8))
    }

    /// Everything one subscriber sees, as text: output as `offset:text`, the rest by kind.
    private func collect(_ stream: AsyncThrowingStream<RunEvent, Error>) async throws -> [String] {
        var seen: [String] = []
        for try await event in stream {
            switch event {
            case .output(_, let offset, let data): seen.append("\(offset):\(String(decoding: data, as: UTF8.self))")
            case .queued: seen.append("queued")
            case .started: seen.append("started")
            case .exited(let exit): seen.append("exited \(exit.cliStatus)")
            case .serviceDied: seen.append("died")
            }
        }
        return seen
    }

    func testEventsBeforeTheStartReplyAreHeldForTheFirstSubscriber() async throws {
        let link = makeLink()
        // `run.start`'s output beats its reply.
        link.received(runID: "r1", .started(runID: "r1"))
        link.received(runID: "r1", out(0, "hello "))
        try await start(link)
        let stream = link.events(runID: "r1", from: 0)
        link.received(runID: "r1", out(6, "world"))
        link.received(runID: "r1", .exited(.code(0)))
        let seen = try await collect(stream)
        XCTAssertEqual(seen, ["started", "0:hello ", "6:world", "exited 0"])
        XCTAssertEqual(transport.attaches, [], "run.start's own attach serves it")
    }

    func testTwoSubscribersAtDifferentOffsetsShareOneAttachAndCutAStraddlingChunk() async throws {
        let link = makeLink()
        try await start(link)
        link.received(runID: "r1", .started(runID: "r1"))
        link.received(runID: "r1", out(0, "0123456789"))
        let fromStart = link.events(runID: "r1", from: 0)
        let fromFour = link.events(runID: "r1", from: 4)
        // Live, straddling a third subscriber's offset.
        let fromTwelve = link.events(runID: "r1", from: 12)
        link.received(runID: "r1", out(10, "abcde", .stderr))
        link.received(runID: "r1", .exited(.signal(15)))
        let a = try await collect(fromStart)
        let b = try await collect(fromFour)
        let c = try await collect(fromTwelve)
        XCTAssertEqual(a, ["started", "0:0123456789", "10:abcde", "exited 143"])
        XCTAssertEqual(b, ["started", "4:456789", "10:abcde", "exited 143"])
        XCTAssertEqual(c, ["started", "12:cde", "exited 143"])
        XCTAssertEqual(transport.attaches, [])
    }

    func testASubscriberAfterTheExitReplaysFromDiskWithNoAttach() async throws {
        let link = makeLink()
        try await start(link)
        link.received(runID: "r1", .started(runID: "r1"))
        link.received(runID: "r1", out(0, "built\n"))
        link.received(runID: "r1", .exited(.code(2)))
        let late = try await collect(link.events(runID: "r1", from: 0))
        XCTAssertEqual(late, ["started", "0:built\n", "exited 2"])
        let tail = try await collect(link.events(runID: "r1", from: 3))
        XCTAssertEqual(tail, ["started", "3:lt\n", "exited 2"])
        XCTAssertEqual(transport.attaches, [])
    }

    func testTheCopySurvivesARelaunch() async throws {
        do {
            let link = makeLink()
            try await start(link)
            link.received(runID: "r1", .started(runID: "r1"))
            link.received(runID: "r1", out(0, "one "))
            link.received(runID: "r1", out(4, "two", .stderr))
            link.received(runID: "r1", .exited(.code(0)))
        }
        transport = ScriptedTransport()
        let relaunched = makeLink()
        let seen = try await collect(relaunched.events(runID: "r1", from: 0))
        XCTAssertEqual(seen, ["started", "0:one ", "4:two", "exited 0"])
        XCTAssertEqual(transport.attaches, [], "the copy on disk answers; the host is not asked")
    }

    func testAMissingRangeTriggersExactlyOneAttach() async throws {
        // A fresh install: no copy of r1 at all. Two subscribers ask before the host answers.
        let link = makeLink()
        let first = link.events(runID: "r1", from: 0)
        let second = link.events(runID: "r1", from: 3)
        await drain()
        XCTAssertEqual(transport.attaches, [0])
        link.received(runID: "r1", .started(runID: "r1"))
        link.received(runID: "r1", out(0, "abcdef"))
        link.received(runID: "r1", .exited(.code(0)))
        let a = try await collect(first)
        let b = try await collect(second)
        XCTAssertEqual(a, ["started", "0:abcdef", "exited 0"])
        XCTAssertEqual(b, ["started", "3:def", "exited 0"])
        XCTAssertEqual(transport.attaches, [0])
    }

    func testASubscriberFromBeforeTheCopyReplaysOnceWhileLiveOutputContinues() async throws {
        // This install first saw r1 from byte 6 (a `logs` from there); now a monitor wants it all.
        let link = makeLink()
        let tail = link.events(runID: "r1", from: 6)
        await drain()
        XCTAssertEqual(transport.attaches, [6])
        link.received(runID: "r1", .started(runID: "r1"))
        link.received(runID: "r1", out(6, "ghi"))
        let whole = link.events(runID: "r1", from: 0)
        await drain()
        XCTAssertEqual(transport.attaches, [6, 0])
        // The old stream is still flowing until the host switches; the replay repeats it.
        link.received(runID: "r1", out(9, "jk"))
        link.received(runID: "r1", .started(runID: "r1"))
        link.received(runID: "r1", out(0, "abcdefghi"))
        link.received(runID: "r1", out(9, "jkl"))
        link.received(runID: "r1", .exited(.code(0)))
        let t = try await collect(tail)
        let w = try await collect(whole)
        XCTAssertEqual(t, ["started", "6:ghi", "9:jkl", "exited 0"], "nothing twice")
        XCTAssertEqual(w, ["started", "0:abcdefghi", "9:jkl", "exited 0"])
        XCTAssertEqual(transport.attaches, [6, 0])
    }

    func testAReconnectReattachesFromTheLastOffsetWithNoGapAndNoDuplicate() async throws {
        let link = makeLink()
        try await start(link)
        let stream = link.events(runID: "r1", from: 0)
        link.received(runID: "r1", .started(runID: "r1"))
        link.received(runID: "r1", out(0, "abcde"))
        transport.isOnline = false
        link.connectionChanged(online: false)
        transport.isOnline = true
        link.connectionChanged(online: true)
        await drain()
        XCTAssertEqual(transport.attaches, [5])
        // The host's replay starts where asked, but a chunk may begin before it.
        link.received(runID: "r1", .started(runID: "r1"))
        link.received(runID: "r1", out(3, "defgh"))
        link.received(runID: "r1", .exited(.code(0)))
        let seen = try await collect(stream)
        XCTAssertEqual(seen, ["started", "0:abcde", "5:fgh", "exited 0"])
    }

    func testOutputTheHostDroppedIsSkippedRatherThanAwaited() async throws {
        let link = makeLink()
        let stream = link.events(runID: "r1", from: 0)
        await drain()
        // The spool kept only from 100: its marker ends exactly there.
        link.received(runID: "r1", .started(runID: "r1"))
        link.received(runID: "r1", out(90, "[dropped]\n", .stderr))
        link.received(runID: "r1", out(100, "tail"))
        link.received(runID: "r1", .exited(.code(0)))
        let seen = try await collect(stream)
        XCTAssertEqual(seen, ["started", "90:[dropped]\n", "100:tail", "exited 0"])
    }

    func testARunTheHostForgotFailsItsSubscribers() async throws {
        transport.attachError = HostLinkError.remote(code: "unknown_run", message: "no run r1")
        let link = makeLink()
        do {
            _ = try await collect(link.events(runID: "r1", from: 0))
            XCTFail("expected unknown_run")
        } catch let error as DelegationError {
            XCTAssertEqual(error.code, "unknown_run")
            XCTAssertTrue(error.message.hasPrefix("mini has no such run"), error.message)
        }
    }

    func testPruneDeletesTheCopySoTheNextReaderAsksTheHost() async throws {
        let link = makeLink()
        try await start(link)
        link.received(runID: "r1", out(0, "x"))
        link.received(runID: "r1", .exited(.code(0)))
        _ = try await collect(link.events(runID: "r1", from: 0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.mirrorURL("r1").path))
        link.prune(runIDs: ["r1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.mirrorURL("r1").path))
        let again = link.events(runID: "r1", from: 0)
        await drain()
        XCTAssertEqual(transport.attaches, [0])
        link.received(runID: "r1", out(0, "x"))
        link.received(runID: "r1", .exited(.code(0)))
        _ = try await collect(again)
    }

    // MARK: request

    func testRequestErrorsAreMapped() async throws {
        let link = makeLink()
        transport.failNext = HostLinkError.remote(code: "tree_mismatch", message: "nope")
        do { _ = try await link.request(.runCancel(runID: "r1")); XCTFail() } catch HostLinkError.remote(let code, _) {
            XCTAssertEqual(code, "tree_mismatch", "a host err reaches DelegationService.hostLine untouched")
        }
        transport.failNext = HostLinkError.offline
        do { _ = try await link.request(.runCancel(runID: "r1")); XCTFail() } catch let error as DelegationError {
            XCTAssertEqual(error.code, "host_unavailable")
            XCTAssertTrue(error.message.hasPrefix("mini went offline before answering run.cancel"), error.message)
        }
        transport.failNext = HostLinkError.timedOut
        do { _ = try await link.request(.runCancel(runID: "r1")); XCTFail() } catch let error as DelegationError {
            XCTAssertEqual(error.code, "host_timeout")
        }
    }

    func testATransferTimesOutOnIdlenessAndOtherBulkRepliesGetTheLongBound() async throws {
        let link = makeLink()
        let ref = SnapshotRef(repoRoot: "a", wtKey: "k", worktreeName: "w", commit: "b", tree: "c")
        let channel = try await link.openChannel()
        let before = Date()
        try await channel.write(Data("bundle".utf8))
        _ = try await link.request(.syncPush(ref: ref, channel: channel.id))
        _ = try await link.request(.serviceDown(service: "r1"))
        _ = try await link.request(.runCancel(runID: "r1"))
        XCTAssertEqual(transport.sent.map(\.timeout),
                       [LiveHostLink.transferIdleTimeout, LiveHostLink.bulkReplyTimeout, HostLink.requestTimeout])
        let progress = try XCTUnwrap(transport.progresses[0], "the push times out on the channel going quiet")
        XCTAssertGreaterThanOrEqual(progress(), before, "the write counted as activity")
        XCTAssertNil(transport.progresses[1])
    }

    func testAnOfflineHostRefusesWithTheDirectorysLineButStillReplaysItsCopy() async throws {
        do {
            let link = makeLink()
            try await start(link)
            link.received(runID: "r1", out(0, "kept"))
            link.received(runID: "r1", .exited(.code(0)))
        }
        transport = ScriptedTransport()
        transport.isOnline = false
        let link = makeLink()
        link.unavailable = { DelegationError(code: "host_offline", message: "mini is offline (last seen 4m ago)") }
        do { _ = try await link.request(.runCancel(runID: "r1")); XCTFail() } catch let error as DelegationError {
            XCTAssertEqual(error.message, "mini is offline (last seen 4m ago)")
        }
        let seen = try await collect(link.events(runID: "r1", from: 0))
        XCTAssertEqual(seen, ["0:kept", "exited 0"])
        XCTAssertTrue(transport.sent.isEmpty)
    }
}

@MainActor
final class RunMirrorTests: XCTestCase {
    func testTheCapDropsTheOldestOutputAsTheSpoolDoes() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cap: Int64 = 1000
        let spool = try OutputSpool(directory: directory.appendingPathComponent("spool"), cap: cap)
        let mirror = RunMirror(url: directory.appendingPathComponent("r1.out"), cap: cap)
        mirror.reset(origin: 0)
        for i in 0..<9 {
            let data = Data(repeating: UInt8(65 + i), count: 150)
            let stream: RunOutputStream = i % 2 == 0 ? .stdout : .stderr
            let offset = try spool.append(data, to: stream)
            mirror.append(RunMirror.Chunk(stream: stream, offset: offset, data: data))
        }
        XCTAssertEqual(mirror.start, spool.start)
        XCTAssertEqual(mirror.end, spool.end)
        let fromSpool = try spool.read(from: 0, maxBytes: .max).map { RunMirror.Chunk(stream: $0.stream, offset: $0.offset, data: $0.data) }
        XCTAssertEqual(mirror.read(from: 0), fromSpool, "same marker, same retained bytes")

        // And reopened from disk, as after a relaunch.
        let reopened = RunMirror(url: directory.appendingPathComponent("r1.out"), cap: cap)
        XCTAssertEqual(reopened.read(from: 0), fromSpool)
        XCTAssertEqual(reopened.origin, 0)
    }

    func testATornLastRecordIsDroppedOnOpen() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-\(UUID().uuidString).out")
        defer { try? FileManager.default.removeItem(at: url) }
        let mirror = RunMirror(url: url)
        mirror.reset(origin: 0)
        mirror.append(RunMirror.Chunk(stream: .stdout, offset: 0, data: Data("whole".utf8)))
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([1, 0, 0, 0, 50, 0]))
        try handle.close()
        let reopened = RunMirror(url: url)
        XCTAssertEqual(reopened.read(from: 0), [RunMirror.Chunk(stream: .stdout, offset: 0, data: Data("whole".utf8))])
        reopened.append(RunMirror.Chunk(stream: .stdout, offset: 5, data: Data("!".utf8)))
        XCTAssertEqual(RunMirror(url: url).read(from: 0).count, 2)
    }
}
