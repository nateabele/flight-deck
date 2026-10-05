import Foundation
import HostKit

/// A `HostLinkConnection` that also carries binary messages: the controller's half of the
/// byte channels (contract amendment A6). A separate protocol so the scripted test
/// connections that only speak text keep compiling; a winner that does not conform simply
/// has no channels, and `openChannel()` says the link is offline.
@MainActor
protocol HostLinkBinaryConnection: HostLinkConnection {
    var onBinary: ((Data) -> Void)? { get set }
    func send(binary: Data)
}

extension NetworkHostConnection: HostLinkBinaryConnection {}

extension HostLink {
    /// A fresh channel to the host, named in a delegation request by its id. Throws
    /// `HostLinkError.offline` when there is no live connection to carry it. A channel dies
    /// with the connection that opened it (its reads and writes fail with
    /// `ChannelMuxError.shutdown`), because ids and credit mean nothing on the next one.
    func openChannel() async throws -> any ByteChannel {
        guard case .online = state, let channelMux else { throw HostLinkError.offline }
        return try await channelMux.open()
    }

    /// On a win: a new mux whose frames go out on `connection`, and whose input is that
    /// connection's binary messages.
    func attachChannels(to connection: HostLinkConnection) {
        detachChannels()
        guard let connection = connection as? HostLinkBinaryConnection else { return }
        let mux = ChannelMux(role: .controller) { [weak connection] data in
            // The mux sends from whatever task wrote. The main queue is FIFO, so frames
            // from one writer reach the socket in the order it wrote them; a Task per
            // frame would not promise that, and reordered data is corrupted data.
            DispatchQueue.main.async {
                MainActor.assumeIsolated { connection?.send(binary: data) }
            }
        }
        connection.onBinary = { [weak mux] data in mux?.receive(binary: data) }
        channelMux = mux
    }

    /// The winner is gone: every channel fails now rather than waiting on bytes that will
    /// never arrive.
    func detachChannels() {
        channelMux?.shutdown()
        channelMux = nil
    }
}
