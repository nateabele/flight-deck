import FleetKit
import Foundation
import HostKit
import Security
import XCTest
@testable import FlightDeck

/// A secret store whose reads can be held, the way `securityd` holds a legacy-keychain read
/// while its "Flight Deck wants to use … dev.flightdeck.host" prompt waits on the user, and
/// can be scripted to fail, the way a denied prompt does.
final class GatedHostSecretStore: HostSecretStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [UUID: Data] = [:]
    private var gates: [UUID: DispatchSemaphore] = [:]
    private var scripted: [UUID: [HostSecretRead]] = [:]
    private var readCounts: [UUID: Int] = [:]

    /// Reads of `slot` block until `release(slot)`.
    func hold(_ slot: UUID) { lock.withLock { gates[slot] = DispatchSemaphore(value: 0) } }

    /// Lets every held and future read of `slot` through.
    func release(_ slot: UUID) {
        guard let gate = lock.withLock({ gates.removeValue(forKey: slot) }) else { return }
        gate.signal()
    }

    /// The next reads of `slot` return these, in order, before the stored secret.
    func script(_ slot: UUID, _ results: [HostSecretRead]) { lock.withLock { scripted[slot] = results } }

    func reads(of slot: UUID) -> Int { lock.withLock { readCounts[slot, default: 0] } }

    func read(_ slot: UUID) -> HostSecretRead {
        if let gate = lock.withLock({ gates[slot] }) {
            gate.wait()
            // Pass it on, so a second read held on the same gate is released too.
            gate.signal()
        }
        return lock.withLock {
            readCounts[slot, default: 0] += 1
            if var queue = scripted[slot], !queue.isEmpty {
                let next = queue.removeFirst()
                scripted[slot] = queue
                return next
            }
            return secrets[slot].map(HostSecretRead.found) ?? .missing
        }
    }

    func set(_ secret: Data, for slot: UUID) { lock.withLock { secrets[slot] = secret } }
    func remove(slot: UUID) { _ = lock.withLock { secrets.removeValue(forKey: slot) } }
}

@MainActor
final class HostKeyReadTests: XCTestCase {
    var url: URL!
    let clock = ManualHostLinkClock()
    let dialer = FakeHostDialer()
    let secrets = GatedHostSecretStore()
    var held: [UUID] = []

    override func setUp() {
        super.setUp()
        url = FileManager.default.temporaryDirectory.appendingPathComponent("hosts-\(UUID()).json")
    }

    override func tearDown() {
        // A read left held is a GCD thread parked for the rest of the run.
        for slot in held { secrets.release(slot) }
        try? FileManager.default.removeItem(at: url)
        super.tearDown()
    }

    private func dials(to text: String) -> [FakeHostConnection] {
        dialer.connections.filter { $0.endpoint == HostLink.endpoint(from: text) }
    }

    private func isKeyUnavailable(_ state: HostLinkState?) -> Bool {
        if case .keyUnavailable = state { return true }
        return false
    }

    /// The 2026-10-10 outage: a re-signed release prompted for m3's key at launch, nobody
    /// answered, and because every key was read in one task before any link opened, jeeves —
    /// whose own read would have needed nothing — was never dialled either.
    func testOneHostsBlockedKeyReadDoesNotHoldAnotherHostOffline() async throws {
        let registry = HostRegistry(fileURL: url, secrets: secrets)
        let m3 = try registry.add(key: .mint(), name: "m3", serviceName: "m3", endpoints: ["10.0.0.3:47410"])
        let jeeves = try registry.add(key: .mint(), name: "jeeves", serviceName: "jeeves",
                                      endpoints: ["10.0.0.4:47410"])
        secrets.hold(m3.slot)
        held.append(m3.slot)
        let service = HostService(registry: registry, controllerName: "c", dial: dialer, clock: clock)
        service.start()

        try await waitUntil { self.dials(to: "10.0.0.4:47410").count == 1 }
        let jeevesConnection = dials(to: "10.0.0.4:47410")[0]
        jeevesConnection.onReady?()
        jeevesConnection.say(.helloAck(protocolVersion: .current, capabilities: [.hostInfo], hostName: "jeeves"))
        XCTAssertEqual(service.statuses[jeeves.slot], .online(hostName: "jeeves"))
        XCTAssertEqual(dials(to: "10.0.0.3:47410").count, 0, "m3 has no key yet")

        // A read this slow is waiting on the user, and the host says so instead of a bare offline.
        clock.advance(by: HostService.keyReadPatience)
        XCTAssertEqual(service.statuses[m3.slot],
                       .keyUnavailable("waiting for Keychain access: approve Flight Deck's Keychain prompt"))

        // The prompt is answered: m3's link opens with no restart.
        secrets.release(m3.slot)
        try await waitUntil { self.dials(to: "10.0.0.3:47410").count == 1 }
        XCTAssertFalse(isKeyUnavailable(service.statuses[m3.slot]))
        XCTAssertEqual(secrets.reads(of: m3.slot), 1, "one prompt per host, not one per patience tick")
        service.forget(slot: m3.slot)
        service.forget(slot: jeeves.slot)
    }

    /// A denied prompt is not a dead end: the read is retried on a capped backoff, and the
    /// host shows why it is offline while it waits.
    func testAFailedKeyReadIsRetriedWithBackoffUntilItSucceeds() async throws {
        let registry = HostRegistry(fileURL: url, secrets: secrets)
        let mini = try registry.add(key: .mint(), name: "mini", serviceName: "mini", endpoints: ["10.0.0.5:47410"])
        secrets.script(mini.slot, [.failed(status: errSecUserCanceled), .failed(status: errSecAuthFailed),
                                   .failed(status: errSecInteractionNotAllowed)])
        let service = HostService(registry: registry, controllerName: "c", dial: dialer, clock: clock)
        service.start()

        try await waitUntil { self.isKeyUnavailable(service.statuses[mini.slot]) }
        XCTAssertEqual(service.statuses[mini.slot], .keyUnavailable("Keychain access denied; retrying in 5s"))
        XCTAssertEqual(dialer.connections.count, 0)

        clock.advance(by: 4.9)
        XCTAssertEqual(secrets.reads(of: mini.slot), 1, "not before the backoff")
        clock.advance(by: 0.1)
        try await waitUntil { self.secrets.reads(of: mini.slot) == 2 }
        try await waitUntil {
            service.statuses[mini.slot] == .keyUnavailable("Keychain access denied; retrying in 15s")
        }

        clock.advance(by: 15)
        try await waitUntil {
            service.statuses[mini.slot] == .keyUnavailable("Keychain is locked; retrying in 30s")
        }

        clock.advance(by: 30)
        try await waitUntil { self.dialer.connections.count == 1 }
        XCTAssertEqual(secrets.reads(of: mini.slot), 4)
        service.forget(slot: mini.slot)
    }

    func testTheRetryBackoffIsCappedAndNeverGivesUp() async throws {
        let registry = HostRegistry(fileURL: url, secrets: secrets)
        let mini = try registry.add(key: .mint(), name: "mini", serviceName: "mini", endpoints: ["10.0.0.5:47410"])
        let failures = Array(repeating: HostSecretRead.failed(status: errSecUserCanceled), count: 10)
        secrets.script(mini.slot, failures)
        let service = HostService(registry: registry, controllerName: "c", dial: dialer, clock: clock)
        service.start()

        for (i, delay) in [5, 15, 30, 60, 120, 300, 300, 300, 300, 300].enumerated() {
            try await waitUntil { service.keyAttempts[mini.slot] == i + 1 }
            XCTAssertEqual(secrets.reads(of: mini.slot), i + 1)
            try await waitUntil {
                service.statuses[mini.slot] == .keyUnavailable("Keychain access denied; retrying in \(delay)s")
            }
            clock.advance(by: TimeInterval(delay))
        }
        try await waitUntil { self.dialer.connections.count == 1 }
        service.forget(slot: mini.slot)
    }

    func testForgettingAHostWhileItsKeyIsBeingReadOpensNothing() async throws {
        let registry = HostRegistry(fileURL: url, secrets: secrets)
        let mini = try registry.add(key: .mint(), name: "mini", serviceName: "mini", endpoints: ["10.0.0.5:47410"])
        secrets.hold(mini.slot)
        held.append(mini.slot)
        let service = HostService(registry: registry, controllerName: "c", dial: dialer, clock: clock)
        service.start()
        service.forget(slot: mini.slot)
        secrets.release(mini.slot)
        try await waitUntil { self.secrets.reads(of: mini.slot) == 1 }
        try await Task.sleep(nanoseconds: 100_000_000)
        clock.advance(by: 600)
        XCTAssertEqual(dialer.connections.count, 0)
        XCTAssertNil(service.statuses[mini.slot])
    }

    func testForgettingAHostWaitingOutAKeyRetryStopsTheRetries() async throws {
        let registry = HostRegistry(fileURL: url, secrets: secrets)
        let mini = try registry.add(key: .mint(), name: "mini", serviceName: "mini", endpoints: ["10.0.0.5:47410"])
        secrets.script(mini.slot, [.failed(status: errSecUserCanceled)])
        let service = HostService(registry: registry, controllerName: "c", dial: dialer, clock: clock)
        service.start()
        try await waitUntil { self.isKeyUnavailable(service.statuses[mini.slot]) }
        service.forget(slot: mini.slot)
        clock.advance(by: 600)
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(secrets.reads(of: mini.slot), 1)
        XCTAssertEqual(dialer.connections.count, 0)
    }

    // MARK: What the CLI says

    /// `host ls` keeps "offline" — testq and other scripts match on it — and adds the reason
    /// a bare "offline" hid; `run --on` names it too.
    func testAHostWaitingOnItsKeyReadsOfflineWithTheReason() throws {
        let registry = HostRegistry(fileURL: url, secrets: InMemoryHostSecretStore())
        let record = try registry.add(key: .mint(), name: "m3", serviceName: "m3", endpoints: [])
        let reason = "Keychain access denied; retrying in 5s"
        XCTAssertEqual(HostProjection.row(record, .keyUnavailable(reason)),
                       WireHost(name: "m3", platform: nil, status: "offline", detail: reason, lastSeenAt: nil))
        let refusal = HostProjection.refusal(
            for: HostLinkError.offline, name: "m3", registry: registry,
            state: { $0 == record.slot ? .keyUnavailable(reason) : nil }, now: Date())
        XCTAssertEqual(refusal.code, "host_offline")
        XCTAssertEqual(refusal.message, "m3 is offline (never seen): \(reason)")
    }

    func testKeyFailureWording() {
        XCTAssertEqual(HostService.keyFailureText(errSecUserCanceled), "Keychain access denied")
        XCTAssertEqual(HostService.keyFailureText(errSecAuthFailed), "Keychain access denied")
        XCTAssertEqual(HostService.keyFailureText(errSecInteractionNotAllowed), "Keychain is locked")
        XCTAssertEqual(HostService.keyFailureText(-1), "Keychain read failed (OSStatus -1)")
    }
}

extension HostKeyReadTests {
    /// `setEndpoints` (a cloud machine's address arriving, or the Mac's public IP moving) once
    /// reread the key with `registry.key(for:)` on the main thread: a Keychain read, so with a
    /// prompt up it would hang the whole UI. It must reuse the link's key and read nothing.
    func testSetEndpointsReopensTheLinkWithoutReadingTheKeychain() async throws {
        let registry = HostRegistry(fileURL: url, secrets: secrets)
        let gpu = try registry.add(key: .mint(), name: "gpu", serviceName: "gpu", endpoints: ["10.0.0.6:47410"])
        let service = HostService(registry: registry, controllerName: "c", dial: dialer, clock: clock)
        service.start()
        try await waitUntil { self.dials(to: "10.0.0.6:47410").count == 1 }
        XCTAssertEqual(secrets.reads(of: gpu.slot), 1)

        // Not held: a held read here would hang the main thread and the test with it. The
        // read count is what tells the old path (a second read) from the fix.
        service.setEndpoints(slot: gpu.slot, ["10.0.0.7:47410"])

        try await waitUntil { self.dials(to: "10.0.0.7:47410").count == 1 }
        XCTAssertEqual(secrets.reads(of: gpu.slot), 1, "no second Keychain read")
        service.forget(slot: gpu.slot)
    }

    /// With the key read still waiting on a prompt there is no link to reopen: the new address
    /// is saved, and the link opens on it once the read returns.
    func testSetEndpointsDuringAHeldKeyReadIsUsedWhenTheReadReturns() async throws {
        let registry = HostRegistry(fileURL: url, secrets: secrets)
        let gpu = try registry.add(key: .mint(), name: "gpu", serviceName: "gpu", endpoints: ["10.0.0.6:47410"])
        secrets.hold(gpu.slot)
        held.append(gpu.slot)
        let service = HostService(registry: registry, controllerName: "c", dial: dialer, clock: clock)
        service.start()

        service.setEndpoints(slot: gpu.slot, ["10.0.0.7:47410"])
        XCTAssertEqual(dialer.connections.count, 0)

        secrets.release(gpu.slot)
        try await waitUntil { self.dials(to: "10.0.0.7:47410").count == 1 }
        XCTAssertEqual(dials(to: "10.0.0.6:47410").count, 0, "never dialled the stale address")
        XCTAssertEqual(secrets.reads(of: gpu.slot), 1)
        service.forget(slot: gpu.slot)
    }
}
