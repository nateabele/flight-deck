import Foundation

// Channels: numbered byte streams beside the JSON control frames on one host WebSocket (spec
// §2.1 `ChannelMux`). Every byte stream of delegated execution rides one: a sync bundle, a
// result bundle, an artifact tar, each forwarded port's connection.
//
// Binary WebSocket message layout, one frame per message:
//
//   [u32 BE channel][u8 kind][payload]
//     kind 0 data    payload: the bytes
//     kind 1 credit  payload: u32 BE, bytes the sender of this frame may now receive
//     kind 2 eof     payload: empty. Half-close: the sender writes no more on this channel.
//     kind 3 close   payload: empty. Abrupt close, both directions.
//
// Each side grants `ChannelFrame.initialCredit` per channel per direction on open, implicitly
// (no credit frame is sent for it). Credit is what keeps one fast stream from starving the
// control frames and every other channel on the same connection; a writer suspends when its
// credit runs out, rather than buffering without bound.
//
// Channel ids are allocated by whoever opens the channel. In this contract every channel a
// request names (`sync.push`, `run.result`, `run.artifacts`, `port.open`) is opened by the
// controller, which then names its id in the request; the host claims it with
// `ChannelAccepting.accept`.
//
// Rules both muxes follow (C1 implements them; each names the failure it prevents):
//   - A credit frame is an additive increment, never an absolute window: frames can cross in
//     flight, and an absolute value would let a stale grant shrink or double the window.
//   - Odd ids belong to the controller, even ids to the host, and no id is reused on a
//     connection. Two sides opening at once can then never collide, and a late frame for a
//     closed channel can never land in a new one.
//   - A frame for an unknown or closed id is dropped, not answered: the other side may have
//     closed it a moment ago, and an error reply would race its own close.
//   - Data that arrives before the host's `accept` is buffered up to `initialCredit`; anything
//     past that closes the channel. The sender may write that much before the request that
//     names the channel is even read, and a peer exceeding its credit is broken.
//   - When a request naming a channel fails, both sides cancel that channel, so neither keeps
//     a buffer for bytes nobody will read.
//   - A data payload is at most `maxPayload` (64 KiB), so one channel's frame never holds the
//     shared connection long enough to stall the control frames behind it.

public typealias ChannelID = UInt32

/// One open channel. Implemented by the mux (track C1); consumed by sync, runs and ports.
public protocol ByteChannel: AnyObject, Sendable {
    var id: ChannelID { get }
    /// Suspends while the peer has granted no credit, so a slow reader backs up its writer
    /// rather than the whole connection.
    func write(_ data: Data) async throws
    /// The next chunk the peer wrote, or nil at EOF.
    func read() async throws -> Data?
    /// Half-close: the peer reads EOF after everything written so far.
    func finish() async
    /// Abrupt close, both ways. Pending reads and writes on both ends fail.
    func cancel()
}

/// Opens a fresh channel to the peer: the controller's half of every channel in this contract.
public protocol ChannelOpening: Sendable {
    func open() async throws -> any ByteChannel
}

/// Claims a channel the peer opened and named in a request: the host's half. Without this a
/// request naming channel 7 would have no way to reach the bytes the mux is holding for it.
public protocol ChannelAccepting: Sendable {
    func accept(_ id: ChannelID) async throws -> any ByteChannel
}

public enum ChannelFrameKind: UInt8, Sendable, Equatable {
    case data = 0
    case credit = 1
    case eof = 2
    case close = 3
}

public enum ChannelFrameError: Error, Equatable {
    /// Fewer than the five header bytes.
    case truncated
    case unknownKind(UInt8)
    /// A credit payload that is not exactly four bytes, or a payload on eof/close.
    case badPayload(ChannelFrameKind)
}

/// One binary message, as the layout above. A codec only: flow control is the mux's.
public struct ChannelFrame: Sendable, Equatable {
    public static let headerLength = 5
    /// 256 KiB per channel per direction, granted implicitly at open.
    public static let initialCredit: UInt32 = 256 * 1024
    /// The largest data payload one frame may carry.
    public static let maxPayload = 64 * 1024

    public let channel: ChannelID
    public let kind: ChannelFrameKind
    public let payload: Data

    public init(channel: ChannelID, kind: ChannelFrameKind, payload: Data = Data()) {
        self.channel = channel
        self.kind = kind
        self.payload = payload
    }

    public static func credit(channel: ChannelID, bytes: UInt32) -> ChannelFrame {
        ChannelFrame(channel: channel, kind: .credit, payload: bigEndian(bytes))
    }

    /// The granted byte count of a credit frame; nil for any other kind.
    public var creditBytes: UInt32? {
        guard kind == .credit, payload.count == 4 else { return nil }
        return payload.reduce(0) { $0 << 8 | UInt32($1) }
    }

    public func encoded() -> Data {
        var out = ChannelFrame.bigEndian(channel)
        out.append(kind.rawValue)
        out.append(payload)
        return out
    }

    /// Throws on any frame the layout does not allow; see `ChannelFrameError`.
    public init(decoding data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= Self.headerLength else { throw ChannelFrameError.truncated }
        guard let kind = ChannelFrameKind(rawValue: bytes[4]) else {
            throw ChannelFrameError.unknownKind(bytes[4])
        }
        let payload = Data(bytes[Self.headerLength...])
        switch kind {
        case .data: break
        case .credit: guard payload.count == 4 else { throw ChannelFrameError.badPayload(kind) }
        case .eof, .close: guard payload.isEmpty else { throw ChannelFrameError.badPayload(kind) }
        }
        self.init(channel: bytes[0..<4].reduce(0) { $0 << 8 | UInt32($1) }, kind: kind, payload: payload)
    }

    private static func bigEndian(_ v: UInt32) -> Data {
        Data([UInt8(v >> 24 & 0xFF), UInt8(v >> 16 & 0xFF), UInt8(v >> 8 & 0xFF), UInt8(v & 0xFF)])
    }
}
