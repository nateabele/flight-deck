import FleetKit
import Foundation

/// `CLITransport` over the real local socket. The runner is transport-agnostic so its tests can
/// drive it frame by frame. This is the only file that touches a socket.
final class LocalFleetTransport: CLITransport {
    // `onReady` fires from `FleetClient` at `.ready` — the runner's only proof of reachability
    // when a caught-up resume sends no frame. Forwarded exactly like `onFrame`/`onDisconnect`.
    var onReady: (() -> Void)? { didSet { client.onReady = onReady } }
    var onFrame: ((ServerFrame) -> Void)? { didSet { client.onFrame = onFrame } }
    var onDisconnect: ((Error?) -> Void)? { didSet { client.onDisconnect = onDisconnect } }
    private let client: FleetClient
    private let path: String
    init(path: String, caller: String?) {
        self.path = path
        client = FleetClient(localCaller: caller)
    }
    func connect(lastSeq: Int) { client.connect(toLocal: path, lastSeq: lastSeq) }
    func send(_ command: FleetCommand) -> Int { client.send(command) }
    func send(_ request: FleetRequest) -> Int { client.send(request) }
    func send(raw frame: ClientFrame) { client.answer(frame) }
    func disconnect() { client.disconnect() }
}
