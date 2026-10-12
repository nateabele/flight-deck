import Foundation
import HostKit
import NIOCore
import NIOEmbedded
import NIOWebSocket
import XCTest
@testable import HostDaemonLinux

/// The delegation router behind the Linux hostd's real NIO frame handlers: a controller's
/// requests in as WebSocket text, its sync bundle in as binary channel frames, and the run's
/// events back out as text, through `LinuxHostd`'s own transport routing. An async testing
/// channel, because the router answers from its own tasks, off the loop.
final class DelegationRouterTests: XCTestCase {
    private enum Inbound: Sendable {
        case text(String)
        case binary(Data)
    }

    private final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var frames: [HostServerFrame] = []
        func add(_ frame: HostServerFrame) { lock.withLock { frames.append(frame) } }

        func wait(_ what: String, _ match: (HostServerFrame) -> Bool) async throws -> HostServerFrame {
            let deadline = Date().addingTimeInterval(60)
            while Date() < deadline {
                if let hit = lock.withLock({ frames.first(where: match) }) { return hit }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            XCTFail("timed out waiting for \(what)")
            throw CancellationError()
        }

        func events(_ runID: String) -> [RunEvent] {
            lock.withLock { frames.compactMap { if case .event(runID, let ev) = $0 { return ev }; return nil } }
        }
    }

    private func scratch(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name)-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url.resolvingSymlinksInPath()
    }

    @discardableResult
    private func git(_ args: [String], in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git"] + args
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_CONFIG_NOSYSTEM"] = "1"; env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_AUTHOR_NAME"] = "T"; env["GIT_AUTHOR_EMAIL"] = "t@example.com"
        env["GIT_COMMITTER_NAME"] = "T"; env["GIT_COMMITTER_EMAIL"] = "t@example.com"
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        try? out.fileHandleForReading.close()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw CocoaError(.executableLoad) }
        return String(decoding: data, as: UTF8.self)
    }

    func testSyncThenRunThroughTheNIOHandlers() async throws {
        let root = try scratch("fd-hostd"), repo = try scratch("fd-repo")
        try git(["init", "-q"], in: repo)
        try Data("from-linux\n".utf8).write(to: repo.appendingPathComponent("a.txt"))
        try git(["add", "-A"], in: repo)
        try git(["commit", "-q", "-m", "c"], in: repo)

        let workspace = Workspace(root: root)
        let screen = ScreenLease()
        let runner = Runner(runsRoot: root.appendingPathComponent("runs"), shell: "/bin/sh", screen: screen,
                            lifecycle: .workspace(workspace))
        let hostd = LinuxHostd(root: root, port: 47499, hostName: "linux-test", delegation: DelegationHost(
            runner: runner, workspace: workspace, screen: screen, portCheck: PortCheck(run: { _, _ in nil }),
            screenSupported: false))

        let channel = NIOAsyncTestingChannel()
        let connection = PSKWebSocketServer.Connection(identity: UUID().uuidString.uppercased(), channel: channel)
        // Built on the loop, so the (non-Sendable) handlers never cross into this task.
        try await channel.eventLoop.submit {
            try channel.pipeline.syncOperations.addHandlers(PSKWebSocketServer.frameHandlers(
                connection: connection, maxMessageBytes: PSKWebSocketServer.maxMessageBytes,
                onText: { hostd.received($1, on: $0) },
                onClose: { hostd.closed($0) },
                onBinary: { hostd.received(binary: $1, on: $0) }))
        }.get()

        // In: one ordered stream for text and binary, as one WebSocket would carry them.
        let (inbound, send) = AsyncStream<Inbound>.makeStream()
        let writer = Task {
            for await message in inbound {
                switch message {
                case .text(let text):
                    try await channel.writeInbound(WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(string: text)))
                case .binary(let data):
                    try await channel.writeInbound(WebSocketFrame(fin: true, opcode: .binary, data: ByteBuffer(bytes: data)))
                }
            }
        }
        let controller = ChannelMux(role: .controller) { send.yield(.binary($0)) }
        // Out: binary to the controller's mux, text to the log.
        let log = Log()
        let reader = Task {
            while !Task.isCancelled {
                let frame = try await channel.waitForOutboundWrite(as: WebSocketFrame.self)
                let bytes = Data(frame.unmaskedData.readableBytesView)
                if frame.opcode == .binary {
                    controller.receive(binary: bytes)
                } else if let decoded = try? HostWire.decode(HostServerFrame.self, from: String(decoding: bytes, as: UTF8.self)) {
                    log.add(decoded)
                }
            }
        }
        defer { writer.cancel(); reader.cancel(); send.finish() }

        func post(_ id: Int, _ request: HostRequest) throws {
            send.yield(.text(try HostWire.encode(HostClientFrame.request(id: id, request))))
        }
        func reply(_ id: Int) async throws -> DelegationReply {
            let frame = try await log.wait("reply \(id)") {
                if case .reply(id, _) = $0 { return true }
                if case .error(id, _, _) = $0 { return true }
                return false
            }
            guard case .reply(_, .delegation(let reply)) = frame else { throw CocoaError(.featureUnsupported, userInfo: ["frame": "\(frame)"]) }
            return reply
        }

        send.yield(.text(try HostWire.encode(HostClientFrame.hello(protocolVersion: .current, capabilities: [.hostInfo],
                                                                   controllerName: "laptop"))))
        let ack = try await log.wait("helloAck") { if case .helloAck = $0 { return true }; return false }
        guard case .helloAck(_, let caps, _, _) = ack else { return XCTFail("\(ack)") }
        XCTAssertEqual(Set(caps), [.hostInfo, .run, .sync, .service, .submodules], "no screen capability on Linux")

        let ref = try await Snapshotter().snapshot(worktree: repo, host: "linux-test", include: [])
        try post(1, .delegation(.syncTips(repoRoot: ref.repoRoot, wtKey: ref.wtKey)))
        guard case .syncTips(let tips) = try await reply(1) else { return XCTFail("sync.tips") }
        let bundle = try await BundleMaker().bundle(worktree: repo, snapshot: ref, haves: tips)
        let push = try await controller.open()
        try post(2, .delegation(.syncPush(ref: ref, channel: push.id)))
        try await push.write(try Data(contentsOf: bundle))
        await push.finish()
        let pushed = try await reply(2)
        XCTAssertEqual(pushed, .syncPush)

        let spec = RunSpec(command: "cat a.txt; exit 7", subdir: "", env: [:], pty: false, screen: false,
                           service: false, downCommand: nil, ports: [])
        try post(3, .delegation(.runStart(ref: ref, spec: spec, owner: "tab", apply: true)))
        guard case .runStart(let runID) = try await reply(3) else { return XCTFail("run.start") }
        _ = try await log.wait("exit") { if case .event(runID, .exited) = $0 { return true }; return false }
        let events = log.events(runID)
        let text = events.reduce(into: "") { if case .output(_, _, let d) = $1 { $0 += String(decoding: d, as: UTF8.self) } }
        XCTAssertEqual(text, "from-linux\n")
        XCTAssertEqual(events.last, .exited(.code(7)))
    }
}
