import AppKit
import FleetKit
import HostKit
import ServiceManagement
import SwiftUI
import XCTest
@testable import FlightDeck

/// Offscreen PNGs of the Hosts and Hosting tabs and their sheets, for layout review — skipped
/// by default. Set `FD_HOSTS_RENDER_DIR` to an output directory to run it. Uses
/// `PlanningRender` (parked `NSHostingView`, `layer.render(in:)`), because screencapture is
/// denied here and the app must never be launched to look at it.
@MainActor
final class HostsSettingsRenderTests: XCTestCase {
    private final class Agent: AgentServiceRegistering {
        var status: SMAppService.Status
        init(_ status: SMAppService.Status) { self.status = status }
        func register() throws {}
        func unregister() throws {}
    }

    private func outputDirectory() throws -> URL {
        guard let dir = ProcessInfo.processInfo.environment["FD_HOSTS_RENDER_DIR"] else {
            throw XCTSkip("set FD_HOSTS_RENDER_DIR to render the Hosts and Hosting PNGs")
        }
        return URL(fileURLWithPath: dir)
    }

    private let tabSize = NSSize(width: 720, height: 520)

    func testRenderHostsTab() throws {
        let dir = try outputDirectory()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hosts-\(UUID()).json")
        let registry = HostRegistry(fileURL: file, secrets: InMemoryHostSecretStore())
        let service = HostService(registry: registry, controllerName: "render")
        try PlanningRender.write(HostsSettingsTab(hostService: service), size: tabSize,
                                 to: dir.appendingPathComponent("hosts-empty.png"))

        for (name, platform) in [("studio", "macOS"), ("build-box", "Linux"), ("mini", nil)] {
            var record = try registry.add(key: FleetDeviceKey(slot: UUID(), secret: Data(repeating: 1, count: 32)),
                                          name: name, serviceName: name, endpoints: [])
            record.platform = platform
            record.lastSeenAt = Date().addingTimeInterval(-3600)
            registry.update(record)
        }
        try PlanningRender.write(HostsSettingsTab(hostService: service), size: tabSize,
                                 to: dir.appendingPathComponent("hosts-list.png"))

        // Every dot colour and detail, which a fresh service (no links) cannot show.
        let rows = VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(zip(registry.hosts, [HostLinkState.online(hostName: "studio"),
                                                .connecting, .offline(lastSeen: nil)])), id: \.0.slot) { pair in
                HostRow(record: pair.0, status: pair.1)
            }
            HostRow(record: registry.hosts[0], status: .refused("Update Flight Deck on studio"))
        }
        .padding(20)
        try PlanningRender.write(rows, size: NSSize(width: 520, height: 170),
                                 to: dir.appendingPathComponent("hosts-row-states.png"))
        try PlanningRender.write(rows, size: NSSize(width: 520, height: 170),
                                 to: dir.appendingPathComponent("hosts-row-states-light.png"), appearance: .aqua)
    }

    func testRenderAddHostSheet() throws {
        let dir = try outputDirectory()
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hosts-\(UUID()).json")
        let service = HostService(registry: HostRegistry(fileURL: file, secrets: InMemoryHostSecretStore()),
                                  controllerName: "render")
        try PlanningRender.write(AddHostSheet(hostService: service, kind: .mac),
                                 size: NSSize(width: 460, height: 380),
                                 to: dir.appendingPathComponent("add-host-mac.png"))
        try PlanningRender.write(AddHostSheet(hostService: service, kind: .linux),
                                 size: NSSize(width: 460, height: 420),
                                 to: dir.appendingPathComponent("add-host-linux.png"))
    }

    func testRenderHostingTab() async throws {
        let dir = try outputDirectory()

        let off = HostingController(service: Agent(.notRegistered), adminPath: "/tmp/fd-none.sock")
        await off.refresh().value
        try PlanningRender.write(HostingSettingsTab(controller: off), size: tabSize,
                                 to: dir.appendingPathComponent("hosting-off.png"))

        let approval = HostingController(service: Agent(.requiresApproval), adminPath: "/tmp/fd-none.sock")
        await approval.refresh().value
        try PlanningRender.write(HostingSettingsTab(controller: approval), size: tabSize,
                                 to: dir.appendingPathComponent("hosting-needs-approval.png"))

        let stopped = HostingController(service: Agent(.enabled), adminPath: "/tmp/fd-none.sock",
                                        startingGrace: 0)
        await stopped.refresh().value
        try PlanningRender.write(HostingSettingsTab(controller: stopped), size: tabSize,
                                 to: dir.appendingPathComponent("hosting-not-running.png"))

        let socketDir = "/tmp/fdrender-\(UUID().uuidString.prefix(8))"
        mkdir(socketDir, 0o700)
        let path = socketDir + "/admin.sock"
        defer { rmdir(socketDir) }
        let controllers = [
            AdminController(slot: UUID(), name: "laptop", pairedAt: Date().addingTimeInterval(-86_400 * 3)),
            AdminController(slot: UUID(), name: "studio", pairedAt: Date().addingTimeInterval(-600)),
        ]
        let server = try AdminSocketServer(path: path) { r in
            switch r {
            case .status: .status(paired: 2, armedUntil: .distantFuture, listeningPort: 47410, hostName: "Dana's MacBook Pro")
            case .listControllers: .controllers(controllers)
            case .arm: .armed(code: "7KQ2-M9XD-4RTA", expiresAt: Date().addingTimeInterval(118))
            default: .ok
            }
        }
        defer { server.stop() }
        let on = HostingController(service: Agent(.enabled), adminPath: path)
        await on.refresh().value
        try PlanningRender.write(HostingSettingsTab(controller: on), size: tabSize,
                                 to: dir.appendingPathComponent("hosting-on.png"))
        try PlanningRender.write(HostingSettingsTab(controller: on), size: tabSize,
                                 to: dir.appendingPathComponent("hosting-on-light.png"), appearance: .aqua)

        await on.arm().value
        guard let armed = on.armed else { return XCTFail("arm opened no window") }
        try PlanningRender.write(ControllerPairingSheet(controller: on, code: armed.code, expiresAt: armed.expiresAt),
                                 size: NSSize(width: 380, height: 330),
                                 to: dir.appendingPathComponent("hosting-pair-sheet.png"))
    }
}
