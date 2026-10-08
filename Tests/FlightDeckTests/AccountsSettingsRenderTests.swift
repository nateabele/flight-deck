import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Offscreen PNGs of Settings → Accounts, its sheets and pool popover, and the Projects pane's
/// account pickers, light and dark, for layout review — skipped by default. Set
/// `FD_ACCOUNTS_RENDER_DIR` to an output directory to run it. Uses `PlanningRender` (parked
/// `NSHostingView`, `layer.render(in:)`): screencapture is denied here and the app must never be
/// launched to look at it. A popover or sheet is its own window, which a capture of the pane
/// cannot see, so those are drawn alone and composited with approximated chrome.
@MainActor
final class AccountsSettingsRenderTests: XCTestCase {
    private let size = NSSize(width: 720, height: 520)

    private func outputDirectory() throws -> URL {
        guard let dir = ProcessInfo.processInfo.environment["FD_ACCOUNTS_RENDER_DIR"] else {
            throw XCTSkip("set FD_ACCOUNTS_RENDER_DIR to render the Accounts PNGs")
        }
        let url = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func account(_ name: String, _ agent: AgentID, email: String?, org: String? = nil) -> AgentAccount {
        AgentAccount(agent: agent, displayName: name,
                     home: URL(fileURLWithPath: "/tmp/fd-render-accounts/\(agent.rawValue)-\(name.lowercased())"),
                     cachedIdentity: email.map { AccountIdentity(email: $0, organization: org) })
    }

    /// One account per agent, as a fresh install has.
    private func sparse() -> PreferencesStore {
        let store = PreferencesStore(persistence: nil)
        store.preferences.accountList = AccountList(entries: [
            .account(account("Personal", .claude, email: "dana@example.com")),
            .account(account("Personal", .codex, email: "dana@example.com")),
            .account(account("Default", .grok, email: nil)),
            .account(account("Default", .gemini, email: "dana@example.com")),
        ])
        return store
    }

    private let team: PoolID = "pool-team"

    /// Pools on two agents, one with a customized threshold.
    private func pooled() -> PreferencesStore {
        let store = PreferencesStore(persistence: nil)
        store.preferences.accountList = AccountList(entries: [
            .account(account("Personal", .claude, email: "dana@example.com")),
            .pool(AccountPool(id: team, label: "Team Max", agent: .claude, members: [
                account("Work 1", .claude, email: "dana@work.example", org: "Example Co"),
                account("Work 2", .claude, email: "ops@work.example", org: "Example Co"),
                account("Work 3", .claude, email: nil),
            ], softThreshold: 0.75, hardThreshold: 0.95)),
            .account(account("Client", .claude, email: "dana@client.example", org: "Client Ltd")),
            .pool(AccountPool(id: "pool-codex", label: "Codex Pro", agent: .codex, members: [
                account("Pro A", .codex, email: "dana@example.com"),
                account("Pro B", .codex, email: "build@example.com"),
            ])),
            .account(account("Default", .grok, email: nil)),
            .account(account("Default", .gemini, email: "dana@example.com")),
        ])
        return store
    }

    private func sessions() -> SessionStore { SessionStore(provider: nil, persistence: nil) }

    func testRenderAccountsTab() throws {
        let dir = try outputDirectory()
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try PlanningRender.write(AccountsSettingsTab(preferences: sparse(), sessions: sessions()),
                                     size: size, to: dir.appendingPathComponent("accounts-sparse-\(name).png"),
                                     appearance: appearance)
            try PlanningRender.write(AccountsSettingsTab(preferences: pooled(), sessions: sessions()),
                                     size: NSSize(width: 720, height: 760),
                                     to: dir.appendingPathComponent("accounts-pools-\(name).png"),
                                     appearance: appearance)
            let prefs = pooled()
            let popover = PoolSettingsPopover(preferences: prefs, poolID: team, agent: .claude,
                                              onRemove: {}, close: {})
            try PlanningRender.write(Self.over(AccountsSettingsTab(preferences: prefs, sessions: sessions()),
                                               popover: popover, at: CGPoint(x: 250, y: 150)),
                                     size: NSSize(width: 720, height: 760),
                                     to: dir.appendingPathComponent("accounts-pool-popover-\(name).png"),
                                     appearance: appearance)
            try PlanningRender.write(Self.chrome(popover).padding(24), size: NSSize(width: 520, height: 330),
                                     to: dir.appendingPathComponent("popover-pool-\(name).png"), appearance: appearance)
            let defaults = PoolSettingsPopover(preferences: prefs, poolID: CapacityPool.defaultID(for: .claude),
                                               agent: .claude, close: {})
            try PlanningRender.write(Self.chrome(defaults).padding(24), size: NSSize(width: 520, height: 330),
                                     to: dir.appendingPathComponent("popover-default-pool-\(name).png"), appearance: appearance)
        }
    }

    func testRenderSheets() throws {
        let dir = try outputDirectory()
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try PlanningRender.write(Self.sheet(AddAccountSheet(preferences: sparse(), agent: .claude) { _ in }),
                                     size: NSSize(width: 520, height: 260),
                                     to: dir.appendingPathComponent("add-account-\(name).png"), appearance: appearance)
            try PlanningRender.write(Self.sheet(AddAccountSheet(preferences: sparse(), agent: .gemini) { _ in }),
                                     size: NSSize(width: 520, height: 230),
                                     to: dir.appendingPathComponent("add-account-gemini-refused-\(name).png"),
                                     appearance: appearance)
            try PlanningRender.write(Self.sheet(AddPoolSheet(preferences: sparse(), agent: .claude) { _ in }),
                                     size: NSSize(width: 520, height: 260),
                                     to: dir.appendingPathComponent("add-pool-\(name).png"), appearance: appearance)
        }
    }

    func testRenderProjectPicker() throws {
        let dir = try outputDirectory()
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let prefs = pooled()
            let path = "/tmp/fd-render-project"
            prefs.setProjectSettings(path, ProjectSettings(defaultAgent: .claude, accounts: [.claude: .pool(team)]))
            prefs.selectedProjectPath = URL(fileURLWithPath: path).standardizedFileURL.path
            try PlanningRender.write(ProjectsSettingsTab(preferences: prefs, sessions: sessions()), size: size,
                                     to: dir.appendingPathComponent("projects-account-picker-\(name).png"),
                                     appearance: appearance)
        }
    }

    // MARK: Chrome

    /// A popover's own chrome, approximated as `RoutingRenderTests` does.
    private static func chrome(_ content: some View) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
    }

    private static func sheet(_ content: some View) -> some View {
        chrome(content).padding(24)
    }

    private static func over(_ base: some View, popover: some View, at point: CGPoint) -> some View {
        ZStack(alignment: .topLeading) {
            base
            chrome(popover).offset(x: point.x, y: point.y)
        }
    }
}
