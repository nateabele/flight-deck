import Foundation
import HostKit
import NIOCore
import NIOEmbedded
import NIOWebSocket
import XCTest
@testable import HostDaemonLinux

/// The Linux hostd's binary path, through the real frame handlers on an `EmbeddedChannel`:
/// a controller's `ChannelMux` frame in as a WebSocket binary message, the host's reply out as
/// one, with text still reaching the core untouched.
final class BinaryFramesTests: XCTestCase {
    private final class Box: @unchecked Sendable {
        let lock = NSLock()
        var texts: [String] = []
        var binaries: [Data] = []
        var mux: ChannelMux?
    }

    private func pipeline(_ box: Box) throws -> (EmbeddedChannel, PSKWebSocketServer.Connection) {
        let channel = EmbeddedChannel()
        let connection = PSKWebSocketServer.Connection(identity: "x", channel: channel)
        try channel.pipeline.syncOperations.addHandlers(PSKWebSocketServer.frameHandlers(
            connection: connection, maxMessageBytes: PSKWebSocketServer.maxMessageBytes,
            onText: { _, text in box.lock.lock(); box.texts.append(text); box.lock.unlock() },
            onClose: nil,
            onBinary: { _, data in
                box.lock.lock(); box.binaries.append(data); let mux = box.mux; box.lock.unlock()
                mux?.receive(binary: data)
            }))
        return (channel, connection)
    }

    private func binary(_ data: Data, fin: Bool = true, opcode: WebSocketOpcode = .binary) -> WebSocketFrame {
        WebSocketFrame(fin: fin, opcode: opcode, data: ByteBuffer(bytes: data))
    }

    /// Before this, binary messages fell through `WebSocketFrameHandler`'s `default: break`.
    func testBinaryMessagesReachOnBinaryAndTextStillReachesOnText() throws {
        let box = Box()
        let (channel, _) = try pipeline(box)
        try channel.writeInbound(binary(Data([1, 2])))
        try channel.writeInbound(binary(Data([3]), fin: false))
        try channel.writeInbound(binary(Data([4, 5]), opcode: .continuation))
        try channel.writeInbound(WebSocketFrame(fin: true, opcode: .text, data: ByteBuffer(string: "hi")))
        XCTAssertEqual(box.binaries, [Data([1, 2]), Data([3, 4, 5])])
        XCTAssertEqual(box.texts, ["hi"])
    }

    func testSendBinaryWritesABinaryFrame() throws {
        let (channel, connection) = try pipeline(Box())
        connection.send(binary: Data([9, 8, 7]))
        channel.embeddedEventLoop.run()
        let frame = try XCTUnwrap(try channel.readOutbound(as: WebSocketFrame.self))
        XCTAssertEqual(frame.opcode, .binary)
        XCTAssertEqual(Array(frame.unmaskedData.readableBytesView), [9, 8, 7])
    }

    /// A channel round trip with the host's mux behind the real handlers: the controller's
    /// bytes arrive on the channel the host claims, and the host's answer leaves as binary.
    func testChannelRoundTripThroughTheHandlers() async throws {
        let box = Box()
        let (channel, connection) = try pipeline(box)
        let host = ChannelMux(role: .host) { connection.send(binary: $0) }
        box.mux = host
        let sentToHost = Box()
        let controller = ChannelMux(role: .controller) { data in
            sentToHost.lock.lock(); sentToHost.binaries.append(data); sentToHost.lock.unlock()
        }

        let mine = try await controller.open()
        try await mine.write(Data("bundle".utf8))
        await mine.finish()
        for data in sentToHost.binaries { try channel.writeInbound(binary(data)) }

        let theirs = try await host.accept(mine.id)
        var got = Data()
        while let chunk = try await theirs.read() { got.append(chunk) }
        XCTAssertEqual(String(decoding: got, as: UTF8.self), "bundle")

        try await theirs.write(Data("ok".utf8))
        await theirs.finish()
        channel.embeddedEventLoop.run()
        while let frame = try channel.readOutbound(as: WebSocketFrame.self) {
            XCTAssertEqual(frame.opcode, .binary)
            controller.receive(binary: Data(frame.unmaskedData.readableBytesView))
        }
        var answer = Data()
        while let chunk = try await mine.read() { answer.append(chunk) }
        XCTAssertEqual(String(decoding: answer, as: UTF8.self), "ok")
    }
}
