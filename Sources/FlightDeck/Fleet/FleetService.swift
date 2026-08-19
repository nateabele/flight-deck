import Combine
import FleetKit
import Foundation
import Network
import OSLog

/// Binds the fleet to the socket.
///
/// The only type that knows both a `SessionStore` and an `NWListener`, which is deliberate:
/// `FleetSocketServer` stays testable without a store, `SessionStore` stays testable without
/// a network, and everything that needs both is here where it can be read at once.
@MainActor
final class FleetService: ObservableObject {
    /// How many phones are watching right now. Published because the Mac shows it — a
    /// remotely-driveable machine that gives no sign of being attached to is the thing §11
    /// of the spec calls out as not-polish.
    @Published private(set) var attachedDeviceCount = 0

    private static let logger = Logger(
        subsystem: "dev.flightdeck.FlightDeck", category: "fleet"
    )

    private let store: SessionStore
    private let keys: @MainActor () -> [FleetDeviceKey]
    private let server: FleetSocketServer
    private let replicator: FleetReplicator

    init(store: SessionStore, keys: @escaping @MainActor () -> [FleetDeviceKey]) {
        self.store = store
        self.keys = keys
        self.server = FleetSocketServer()
        self.replicator = FleetReplicator { [weak store] in
            guard let store else { return .empty }
            return FleetProjection.snapshot(of: store)
        }

        store.replicator = replicator
        replicator.onEvents = { [weak self] batch in
            for entry in batch {
                self?.server.broadcast(.event(seq: entry.seq, entry.event))
            }
        }
        server.onHello = { [weak self] _, lastSeq in
            guard let self else { return [] }
            switch self.replicator.resume(from: lastSeq) {
            case .replay(let events):
                return events.map { .event(seq: $0.seq, $0.event) }
            case .resnapshot(let reason):
                let current = self.replicator.snapshot()
                return [.snapshot(seq: current.seq, fleet: current.fleet, reason: reason)]
            }
        }
        server.onCommand = { [weak self] _, cid, command in
            self?.apply(command, cid: cid) ?? .err(cid: cid, code: "stopped")
        }
        server.onAttachedCountChanged = { [weak self] count in
            MainActor.assumeIsolated { self?.attachedDeviceCount = count }
        }
    }

    /// `port: nil` asks the OS for one. Plan 2's Bonjour advertisement publishes whatever
    /// comes back — no port is hard-coded anywhere, because a fixed port is a collision
    /// waiting for a second Mac app.
    /// `async` because the listener half is: it awaits the OS reporting the bound port rather
    /// than polling for it. The previous shape blocked its caller for up to five seconds, and
    /// this type is main-actor — a visible stall in a terminal app.
    @discardableResult
    func start(port: NWEndpoint.Port? = nil) async throws -> NWEndpoint.Port {
        let bound = try await server.start(keys: keys(), port: port)
        Self.logger.info("fleet listener bound to port \(bound.rawValue, privacy: .public)")
        return bound
    }

    func stop() {
        server.stop()
        attachedDeviceCount = 0
    }

    /// Restart the listener so a change to the paired-device list takes effect. Revoking a
    /// device is deleting its key, and a listener started with the old set would keep
    /// honouring it until the app quit.
    func reloadKeys(port: NWEndpoint.Port? = nil) async throws {
        try await start(port: port)
    }

    private func apply(_ command: FleetCommand, cid: Int) -> ServerFrame {
        switch command {
        case .markRead(let id):
            guard store.sessionExists(id) else { return .err(cid: cid, code: "unknown_session") }
            store.markRead(id)
        case .markUnread(let id):
            guard store.sessionExists(id) else { return .err(cid: cid, code: "unknown_session") }
            store.markUnread(id)
        }
        // `ack` means dispatched, not done. The observable effect arrives separately as the
        // northbound `session.unread` event this command's store call just recorded.
        return .ack(cid: cid)
    }
}
