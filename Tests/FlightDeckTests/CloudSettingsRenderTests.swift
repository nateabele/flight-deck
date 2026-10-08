import AppKit
import HostKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Offscreen PNGs of Settings → Cloud, the setup sheet and a cloud host's row in Settings →
/// Hosts, for layout review — skipped by default. Set `FD_CLOUD_RENDER_DIR` to an output
/// directory to run it. `PlanningRender` (parked `NSHostingView`, `layer.render(in:)`), because
/// the app must never be launched to look at it. Every account and API is a fake.
@MainActor
final class CloudSettingsRenderTests: XCTestCase {
    private func outputDirectory() throws -> URL {
        guard let dir = ProcessInfo.processInfo.environment["FD_CLOUD_RENDER_DIR"] else {
            throw XCTSkip("set FD_CLOUD_RENDER_DIR to render the Cloud tab and setup sheet PNGs")
        }
        return URL(fileURLWithPath: dir)
    }

    func testRenderCloudTabSheetAndHostRow() async throws {
        let dir = try outputDirectory()
        let h = try CloudSetupHarness(aws: .signedOut(fix: "aws sso login --profile dev"),
                                      quota: QuotaCheck(ok: false, have: 0, need: 2, increaseURL: URL(string: "https://example.invalid/quota")))
        try h.infra.readyMachine("gpu")
        var failed = InfraMachine.fixture(name: "db", state: .failed)
        failed.failure = "apply: InsufficientInstanceCapacity"
        try h.infra.registry.upsert(failed)

        let prefs = PreferencesStore(persistence: nil)
        let context = CloudSettingsContext(service: h.infra.service, tailnet: h.tailnet,
                                           listGCPProjects: { ["example-project", "example-two"] }, makeSetup: { h.model })
        try PlanningRender.write(CloudSettingsTab(preferences: prefs, context: context), size: NSSize(width: 720, height: 1100),
                                 to: dir.appendingPathComponent("cloud-tab.png"))

        await h.model.refresh()
        _ = await h.model.applyPolicy(token: "tskey-api-EXAMPLE")
        try PlanningRender.write(CloudSetupSheet(model: h.model), size: NSSize(width: 560, height: 640),
                                 to: dir.appendingPathComponent("cloud-setup-sheet.png"))
        try PlanningRender.write(CloudSetupSheet(model: h.model), size: NSSize(width: 560, height: 640),
                                 to: dir.appendingPathComponent("cloud-setup-sheet-scrolled.png")) { view in
            Self.scrollToBottom(view)
        }
        try PlanningRender.write(CloudSetupSheet(model: h.model), size: NSSize(width: 560, height: 640),
                                 to: dir.appendingPathComponent("cloud-setup-sheet-light.png"), appearance: .aqua)

        try PlanningRender.write(HostsSettingsTab(hostService: h.infra.hosts, infra: h.infra.service),
                                 size: NSSize(width: 720, height: 320), to: dir.appendingPathComponent("hosts-cloud-row.png"))
    }

    private static func scrollToBottom(_ view: NSView) {
        if let scroll = view as? NSScrollView, let doc = scroll.documentView {
            doc.scroll(NSPoint(x: 0, y: doc.isFlipped ? doc.bounds.height : 0))
            return
        }
        view.subviews.forEach(scrollToBottom)
    }
}
