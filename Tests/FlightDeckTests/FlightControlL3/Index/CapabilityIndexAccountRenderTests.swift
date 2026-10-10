import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Offscreen PNGs of the capability index pane with its Refresh agent account picker, light and
/// dark, for layout review — skipped by default. Set `FD_INDEX_ACCOUNT_RENDER_DIR` to an output
/// directory to run it. Uses `PlanningRender` (parked `NSHostingView`, `layer.render(in:)`):
/// screencapture is denied here and the app must never be launched to look at it.
@MainActor
final class CapabilityIndexAccountRenderTests: XCTestCase {
    private func outputDirectory() throws -> URL {
        guard let dir = ProcessInfo.processInfo.environment["FD_INDEX_ACCOUNT_RENDER_DIR"] else {
            throw XCTSkip("set FD_INDEX_ACCOUNT_RENDER_DIR to render the capability index account PNGs")
        }
        let url = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func account(_ name: String) -> AgentAccount {
        AgentAccount(agent: .claude, displayName: name,
                     home: URL(fileURLWithPath: "/tmp/fd-render-index/\(name.lowercased())"))
    }

    private func preferences(_ assignment: AccountAssignment?) -> PreferencesStore {
        let store = PreferencesStore(persistence: nil)
        store.preferences.accountList = AccountList(entries: [
            .account(account("Personal")),
            .pool(AccountPool(id: "pool-team", label: "Team Max", agent: .claude,
                              members: [account("Work 1"), account("Work 2")])),
        ])
        store.indexAccount = assignment
        return store
    }

    /// The UI test's fixture snapshots, copied so nothing writes into the repo.
    private func service() throws -> CapabilityIndexService {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/FlightControlL3/Index/ui", isDirectory: true)
        let scratch = IndexFixtures.scratch()
        try? FileManager.default.removeItem(at: scratch)
        try FileManager.default.copyItem(at: fixture, to: scratch)
        addTeardownBlock { try? FileManager.default.removeItem(at: scratch) }
        return CapabilityIndexService(directory: scratch, runner: IndexRefreshRunner(headless: ScriptedIndexHeadless()))
    }

    func testRenderIndexAccountPicker() throws {
        let dir = try outputDirectory()
        let size = NSSize(width: 900, height: 1080)
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try PlanningRender.write(CapabilityIndexPane(service: try service(), preferences: preferences(nil)),
                                     size: size, to: dir.appendingPathComponent("index-account-default-\(name).png"),
                                     appearance: appearance)
            try PlanningRender.write(CapabilityIndexPane(service: try service(), preferences: preferences(.pool("pool-team"))),
                                     size: size, to: dir.appendingPathComponent("index-account-pool-\(name).png"),
                                     appearance: appearance)
        }
    }
}
