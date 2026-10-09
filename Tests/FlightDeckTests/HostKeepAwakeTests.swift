import Foundation
import HostKit
import ServiceManagement
import XCTest
@testable import FlightDeck

/// "Keep this Mac awake while plugged in", end to end on this side of IOKit: the macOS hostd's
/// admin handler persisting and applying it, and the Hosting tab's model reading and writing
/// it over a real admin socket. The holder runs against fakes, so no test keeps this Mac awake.
@MainActor
final class HostKeepAwakeTests: XCTestCase {
    final class FakePower: PowerAsserting, @unchecked Sendable {
        private let lock = NSLock()
        private var live = 0
        var held: Int { lock.withLock { live } }
        func hold(_ kind: PowerAssertionKind, reason: String) -> PowerAssertion {
            lock.withLock { live += 1 }
            return PowerAssertion { [self] in lock.withLock { live -= 1 } }
        }
    }

    final class FakeSource: PowerSourceMonitoring, @unchecked Sendable {
        let current: PowerSource
        init(_ source: PowerSource) { current = source }
        func start(onChange: @escaping @Sendable (PowerSource) -> Void) {}
        func stop() {}
    }

    private var dirs: [URL] = []

    /// Short and in /tmp, for the 103-byte socket path cap; 0700, because the admin socket
    /// refuses a parent others can write.
    private func makeRoot() throws -> URL {
        let root = URL(fileURLWithPath: "/tmp/fdka-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        dirs.append(root)
        return root
    }

    override func tearDown() {
        for dir in dirs { try? FileManager.default.removeItem(at: dir) }
        dirs = []
        super.tearDown()
    }

    // MARK: - hostd

    func testSetKeepAwakeIsSavedThenAppliedAndReadBack() throws {
        let root = try makeRoot(), power = FakePower()
        let holder = KeepAwakeHolder(power: power, source: FakeSource(.ac), enabled: false)
        let server = DarwinHostServer(root: root, port: nil, hostName: { "loop" }, keepAwake: holder)

        XCTAssertEqual(server.handle(.keepAwake), .keepAwake(KeepAwakeStatus(enabled: false, holding: false, power: .ac)))
        XCTAssertEqual(server.handle(.setKeepAwake(true)),
                       .keepAwake(KeepAwakeStatus(enabled: true, holding: true, power: .ac)))
        XCTAssertEqual(power.held, 2)
        // What the next hostd launch reads, so the setting survives a restart and a reboot.
        XCTAssertEqual(HostingSettings.load(root: root).keepAwakeWhilePluggedIn, true)

        XCTAssertEqual(server.handle(.setKeepAwake(false)),
                       .keepAwake(KeepAwakeStatus(enabled: false, holding: false, power: .ac)))
        XCTAssertEqual(power.held, 0)
        XCTAssertEqual(HostingSettings.load(root: root).keepAwakeWhilePluggedIn, false)
    }

    /// A setting that could not be saved is not applied: the tab must never show "on" for a
    /// value the next launch drops.
    func testAFailedSaveAppliesNothing() throws {
        let root = try makeRoot(), power = FakePower()
        // A directory where the file goes makes the atomic write fail.
        try FileManager.default.createDirectory(at: root.appendingPathComponent(HostingSettings.fileName),
                                                withIntermediateDirectories: true)
        let holder = KeepAwakeHolder(power: power, source: FakeSource(.ac), enabled: false)
        let server = DarwinHostServer(root: root, port: nil, hostName: { "loop" }, keepAwake: holder)
        guard case .failed = server.handle(.setKeepAwake(true)) else { return XCTFail("save failure not reported") }
        XCTAssertEqual(power.held, 0)
        XCTAssertFalse(holder.status.enabled)
    }

    func testAServerWithoutAHolderSaysItCannot() throws {
        let server = DarwinHostServer(root: try makeRoot(), port: nil, hostName: { "loop" })
        guard case .failed = server.handle(.keepAwake) else { return XCTFail() }
        guard case .failed = server.handle(.setKeepAwake(true)) else { return XCTFail() }
    }

    // MARK: - Hosting tab

    final class FakeAgent: AgentServiceRegistering {
        var status: SMAppService.Status = .enabled
        func register() throws {}
        func unregister() throws { status = .notRegistered }
    }

    private func status() -> AdminReply {
        .status(paired: 0, armedUntil: nil, listeningPort: 47410, hostName: "m")
    }

    func testRefreshReadsTheHostsSettingAndTheToggleWritesIt() async throws {
        let root = try makeRoot(), power = FakePower()
        let holder = KeepAwakeHolder(power: power, source: FakeSource(.ac), enabled: false)
        let server = DarwinHostServer(root: root, port: nil, hostName: { "m" }, keepAwake: holder)
        let path = root.appendingPathComponent("admin.sock").path
        let status = status()
        let admin = try AdminSocketServer(path: path) { request in
            if case .status = request { return status }
            return server.handle(request)
        }
        defer { admin.stop() }

        let c = HostingController(service: FakeAgent(), adminPath: path)
        await c.refresh().value
        XCTAssertEqual(c.keepAwake, .available(KeepAwakeStatus(enabled: false, holding: false, power: .ac)))

        await c.setKeepAwake(true).value
        XCTAssertEqual(c.keepAwake, .available(KeepAwakeStatus(enabled: true, holding: true, power: .ac)))
        XCTAssertEqual(power.held, 2)
        XCTAssertNil(c.actionError)
    }

    /// A hostd from before the option answers `failed("bad request")`: the toggle says the
    /// host service needs restarting, rather than vanishing or claiming to be off.
    func testAnOlderHostdReadsAsNeedingARestart() async throws {
        let root = try makeRoot()
        let path = root.appendingPathComponent("admin.sock").path
        let status = status()
        let admin = try AdminSocketServer(path: path) { request in
            if case .status = request { return status }
            if case .listControllers = request { return .controllers([]) }
            return .failed("bad request")
        }
        defer { admin.stop() }
        let c = HostingController(service: FakeAgent(), adminPath: path)
        await c.refresh().value
        XCTAssertEqual(c.keepAwake, .unsupported)
    }

    func testAStoppedHostShowsNoKeepAwakeState() async throws {
        let root = try makeRoot()
        let c = HostingController(service: FakeAgent(), adminPath: root.appendingPathComponent("admin.sock").path,
                                  startingGrace: 0)
        await c.refresh().value
        XCTAssertEqual(c.keepAwake, .unknown)
    }

    func testStatusWording() {
        XCTAssertNil(HostingSettingsTab.keepAwakeText(KeepAwakeStatus(enabled: false, holding: false, power: .ac)))
        XCTAssertEqual(HostingSettingsTab.keepAwakeText(KeepAwakeStatus(enabled: true, holding: true, power: .ac)),
                       "Keeping awake — on power adapter")
        XCTAssertEqual(HostingSettingsTab.keepAwakeText(KeepAwakeStatus(enabled: true, holding: false, power: .battery)),
                       "Not holding: on battery")
        XCTAssertEqual(HostingSettingsTab.keepAwakeText(KeepAwakeStatus(enabled: true, holding: false, power: .unknown)),
                       "Not holding: power source unknown")
    }
}
