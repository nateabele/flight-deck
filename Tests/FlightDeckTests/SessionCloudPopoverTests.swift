import AppKit
import FleetKit
import SwiftUI
import XCTest
@testable import FlightDeck

@MainActor
final class SessionCloudPopoverTests: XCTestCase {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func machine(_ name: String, state: String = "ready", hourly: Double? = 0.0832,
                        spent: Double = 0.6, up: TimeInterval = 4200, ttl: TimeInterval = 7800,
                        own: TimeInterval? = nil, failure: String? = nil) -> WireCloudMachine {
        WireCloudMachine(
            name: name, cloud: "aws", instanceType: "c7i.xlarge", region: "us-east-1", state: state,
            network: "public", hourlyUsd: hourly, spentUsd: spent,
            createdAt: now.addingTimeInterval(-up), deadline: now.addingTimeInterval(ttl),
            machineDeadline: own.map { now.addingTimeInterval($0) }, failure: failure)
    }

    /// 72% of a $20 budget used, one ready and one provisioning machine.
    static var busyCloud: WireSessionCloud {
        WireSessionCloud(
            asOf: now, machines: [machine("build-box", own: 9000), machine("test-box", state: "provisioning", spent: 0.04, up: 90, ttl: 14400)],
            spentUsd: 14.4, hourlyUsd: 0.1664, budgetCapUsd: 20, budgetSince: now.addingTimeInterval(-86400),
            budgetExhaustsAt: now.addingTimeInterval(33_600), monthUsd: 41.5, monthCapUsd: 100)
    }

    /// One failed machine and a budget already used up.
    static var failedCloud: WireSessionCloud {
        WireSessionCloud(
            asOf: now, machines: [machine("gpu-box", state: "failed", hourly: nil, spent: 5, up: 20000, ttl: -60,
                                          failure: "tofu apply: InsufficientInstanceCapacity in us-east-1a")],
            spentUsd: 20.4, hourlyUsd: 0, budgetCapUsd: 20, budgetSince: now.addingTimeInterval(-86400),
            budgetExhaustsAt: now.addingTimeInterval(-300), monthUsd: 98, monthCapUsd: 100)
    }

    // MARK: Pure helpers

    func testBudgetFractionClampsAndTreatsZeroCapAsUsed() {
        XCTAssertEqual(SessionCloudFormat.budgetFraction(spent: 5, cap: 20), 0.25, accuracy: 1e-9)
        XCTAssertEqual(SessionCloudFormat.budgetFraction(spent: 30, cap: 20), 1)
        XCTAssertEqual(SessionCloudFormat.budgetFraction(spent: -1, cap: 20), 0)
        XCTAssertEqual(SessionCloudFormat.budgetFraction(spent: 0, cap: 0), 1)
    }

    func testBudgetLevelThresholds() {
        var cloud = Self.busyCloud
        cloud.hourlyUsd = 0
        cloud.budgetExhaustsAt = nil
        cloud.spentUsd = 15.9
        XCTAssertEqual(SessionCloudFormat.budgetLevel(cloud, at: Self.now), .ok)
        cloud.spentUsd = 16
        XCTAssertEqual(SessionCloudFormat.budgetLevel(cloud, at: Self.now), .warning)
        cloud.spentUsd = 20
        XCTAssertEqual(SessionCloudFormat.budgetLevel(cloud, at: Self.now), .exhausted)
        cloud.spentUsd = 1
        cloud.budgetExhaustsAt = Self.now.addingTimeInterval(-1)
        XCTAssertEqual(SessionCloudFormat.budgetLevel(cloud, at: Self.now), .exhausted, "exhaustion time passed")
        cloud.budgetCapUsd = nil
        XCTAssertNil(SessionCloudFormat.budgetLevel(cloud, at: Self.now))
    }

    func testBudgetLevelExtrapolatesTheBaselineAtTheCurrentRate() {
        var cloud = Self.busyCloud
        cloud.hourlyUsd = 4
        cloud.spentUsd = 15
        cloud.budgetExhaustsAt = nil
        XCTAssertEqual(SessionCloudFormat.budgetLevel(cloud, at: Self.now), .ok)
        XCTAssertEqual(SessionCloudFormat.budgetLevel(cloud, at: Self.now.addingTimeInterval(1800)), .warning)
        XCTAssertEqual(SessionCloudFormat.budgetLevel(cloud, at: Self.now.addingTimeInterval(5000)), .exhausted)
    }

    func testExtendRules() {
        // No machine deadline means the limit is the deadline itself: nothing to extend into.
        XCTAssertFalse(SessionCloudFormat.canExtend(Self.machine("a")))
        // 1h of room under the machine's own timer.
        XCTAssertTrue(SessionCloudFormat.canExtend(Self.machine("a", ttl: 3600, own: 7200)))
        // A second of slack, as the service allows.
        XCTAssertTrue(SessionCloudFormat.canExtend(Self.machine("a", ttl: 3600, own: 7199.5)))
        XCTAssertFalse(SessionCloudFormat.canExtend(Self.machine("a", ttl: 3600, own: 7100)))
        // Only a running machine.
        XCTAssertFalse(SessionCloudFormat.canExtend(Self.machine("a", state: "provisioning", ttl: 3600, own: 20000)))
        XCTAssertFalse(SessionCloudFormat.canExtend(Self.machine("a", state: "failed", ttl: 3600, own: 20000)))
        XCTAssertTrue(SessionCloudFormat.canExtend(Self.machine("a", state: "idle", ttl: 3600, own: 20000)))
        XCTAssertTrue(SessionCloudFormat.extendHelp(Self.machine("a")).contains("own time limit"))
    }

    func testSpanAndLines() {
        XCTAssertEqual(SessionCloudFormat.span(45), "45s")
        XCTAssertEqual(SessionCloudFormat.span(725), "12m 05s")
        XCTAssertEqual(SessionCloudFormat.span(11_100), "3h 05m")
        XCTAssertEqual(SessionCloudFormat.span(-5), "0s")
        let m = Self.machine("a")
        XCTAssertEqual(SessionCloudFormat.detailLine(m), "aws · c7i.xlarge · us-east-1 · public")
        var module = m
        module.instanceType = ""
        XCTAssertEqual(SessionCloudFormat.detailLine(module), "aws · us-east-1 · public")
        XCTAssertEqual(SessionCloudFormat.rateText(m), "$0.083/h")
        XCTAssertEqual(SessionCloudFormat.rateText(Self.machine("a", hourly: nil)), "price unknown")
        XCTAssertEqual(SessionCloudFormat.ttlText(m, at: Self.now), "2h 10m left")
        XCTAssertEqual(SessionCloudFormat.ttlText(Self.machine("a", ttl: -1), at: Self.now), "past its deadline")
        XCTAssertEqual(SessionCloudFormat.upText(m, at: Self.now), "up 1h 10m")
    }

    func testExhaustionText() {
        XCTAssertEqual(SessionCloudFormat.exhaustionText(Self.busyCloud, at: Self.now), "runs out in 9h 20m")
        XCTAssertEqual(SessionCloudFormat.exhaustionText(Self.failedCloud, at: Self.now), "used up")
        var none = Self.busyCloud
        none.budgetExhaustsAt = nil
        XCTAssertNil(SessionCloudFormat.exhaustionText(none, at: Self.now))
    }

    func testAccessibilitySummary() {
        var cloud = Self.busyCloud
        cloud.spentUsd = 1.2
        cloud.hourlyUsd = 0
        cloud.machines = [Self.machine("a"), Self.machine("b")]
        XCTAssertEqual(SessionCloudFormat.accessibilitySummary(cloud, at: Self.now), "2 cloud machines, $1.20 of $20.00 budget")
        cloud.machines = [Self.machine("a")]
        cloud.budgetCapUsd = nil
        XCTAssertEqual(SessionCloudFormat.accessibilitySummary(cloud, at: Self.now), "1 cloud machine, $1.20 spent, no budget")
        XCTAssertTrue(SessionCloudFormat.accessibilitySummary(Self.failedCloud, at: Self.now).hasSuffix("needs attention"))
    }

    func testIconSymbolFollowsBadge() {
        XCTAssertEqual(SessionCloudIcon.symbol(.ready), "cloud.fill")
        XCTAssertEqual(SessionCloudIcon.symbol(.busy), "cloud.fill")
        XCTAssertEqual(SessionCloudIcon.symbol(.failed), "exclamationmark.icloud.fill")
    }

    // MARK: Presenter and controls

    func testClickPinsAHoverOpenedPopoverThenToggles() async throws {
        let p = SessionCloudPresenter()
        p.click()
        XCTAssertTrue(p.isShown)
        XCTAssertTrue(p.isPinned)
        p.hoverIcon(true)
        p.hoverIcon(false)
        try await Task.sleep(for: SessionCloudPresenter.closeDelay + .milliseconds(150))
        XCTAssertTrue(p.isShown, "a click-opened popover stays until dismissed")
        p.click()
        XCTAssertFalse(p.isShown)
    }

    func testHoverOpensAfterADelayAndClosesAfterLeavingBoth() async throws {
        let p = SessionCloudPresenter()
        p.hoverIcon(true)
        XCTAssertFalse(p.isShown)
        try await Task.sleep(for: SessionCloudPresenter.openDelay + .milliseconds(150))
        XCTAssertTrue(p.isShown)
        // Pointer crosses from the icon into the popover: stays open.
        p.hoverPopover(true)
        p.hoverIcon(false)
        try await Task.sleep(for: SessionCloudPresenter.closeDelay + .milliseconds(150))
        XCTAssertTrue(p.isShown)
        p.hoverPopover(false)
        try await Task.sleep(for: SessionCloudPresenter.closeDelay + .milliseconds(150))
        XCTAssertFalse(p.isShown)
    }

    func testBriefHoverNeverOpens() async throws {
        let p = SessionCloudPresenter()
        p.hoverIcon(true)
        p.hoverIcon(false)
        try await Task.sleep(for: SessionCloudPresenter.openDelay + .milliseconds(150))
        XCTAssertFalse(p.isShown)
    }

    func testControlsReportErrorsAndClearBusy() async throws {
        struct Boom: Error {}
        let c = SessionCloudControls()
        var actions = SessionCloudActions.unavailable
        actions.extend = { _ in throw Boom() }
        c.extend("a", using: actions)
        XCTAssertTrue(c.busy.contains("a"))
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(c.busy.contains("a"))
        XCTAssertNotNil(c.errors["a"])
        c.pendingDestroy = "a"
        actions.destroy = { _ in }
        c.confirmDestroy(using: actions)
        XCTAssertNil(c.pendingDestroy)
        XCTAssertNil(c.errors["a"], "a new request clears the old error")
    }

    // MARK: Layout

    /// The icon is one more trailing control; it must not move the title.
    func testIconDoesNotShiftTheTitle() {
        func width(_ cloud: WireSessionCloud?) -> CGFloat {
            let row = HStack(spacing: 4) {
                Text("Session")
                Spacer()
                if let cloud { SessionCloudIcon(cloud: cloud) }
            }.frame(width: 240)
            let host = NSHostingView(rootView: row)
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.width
        }
        XCTAssertEqual(width(Self.busyCloud), width(nil), accuracy: 0.5)
    }

    // MARK: Snapshots

    /// Renders the popover to PNGs under `FD_CLOUD_SNAPSHOT_DIR` (when set) for a human to look at.
    func testRenderSnapshots() throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_CLOUD_SNAPSHOT_DIR"] else {
            throw XCTSkip("FD_CLOUD_SNAPSHOT_DIR not set")
        }
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let busyControls = SessionCloudControls()
        busyControls.busy = ["test-box"]
        let failedControls = SessionCloudControls()
        failedControls.errors["gpu-box"] = "gpu-box is failed; only a running machine can be extended"
        let confirming = SessionCloudControls()
        confirming.pendingDestroy = "build-box"
        let live = SessionCloudActions(extend: { _ in }, destroy: { _ in }, openSettings: {})
        var unbudgeted = Self.busyCloud
        unbudgeted.budgetCapUsd = nil
        unbudgeted.budgetExhaustsAt = nil
        unbudgeted.monthCapUsd = nil
        let cases: [(String, WireSessionCloud, SessionCloudControls)] = [
            ("busy", Self.busyCloud, busyControls), ("failed", Self.failedCloud, failedControls),
            ("confirm", Self.busyCloud, confirming), ("nobudget", unbudgeted, SessionCloudControls()),
        ]
        for (name, cloud, controls) in cases {
            for (scheme, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let view = SessionCloudPopoverContent(cloud: cloud, controls: controls, now: Self.now)
                    .environment(\.sessionCloudActions, live)
                    .background(Color(nsColor: .windowBackgroundColor))
                let host = NSHostingView(rootView: view)
                host.appearance = NSAppearance(named: appearance)
                let size = host.fittingSize
                host.frame = NSRect(origin: .zero, size: size)
                let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = host.appearance
                window.contentView = host
                host.layoutSubtreeIfNeeded()
                let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: "\(dir)/cloud-\(name)-\(scheme).png"))
            }
        }
    }
}
