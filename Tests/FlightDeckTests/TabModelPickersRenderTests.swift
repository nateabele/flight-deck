import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Offscreen PNGs of the grok and gemini model panes in Settings → Agents and → Projects, light
/// and dark, for layout review — skipped by default. Set `FD_TAB_MODEL_RENDER_DIR` to an output
/// directory to run it. `PlanningRender` parks an `NSHostingView` and draws it with
/// `layer.render(in:)`: screencapture is denied here, and the app is never launched to look.
/// Detection is handed in (`modelSource`), so no real `grok models` or `agy models` runs.
@MainActor
final class TabModelPickersRenderTests: XCTestCase {
    private let size = NSSize(width: 720, height: 520)

    private func outputDirectory() throws -> URL {
        guard let dir = ProcessInfo.processInfo.environment["FD_TAB_MODEL_RENDER_DIR"] else {
            throw XCTSkip("set FD_TAB_MODEL_RENDER_DIR to render the model picker PNGs")
        }
        let url = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// grok signed in with a synthetic list; gemini signed out, so its pane shows planning's reason.
    private func detection(geminiSignedIn: Bool) -> IntakeService {
        var available = AvailableModels(choices: [:])
        available.models[.grok] = ["grok-4.7", "grok-4.7-build-fast", "grok-4.6"]
        if geminiSignedIn {
            available.models[.gemini] = ["gemini-3.1-pro-high", "gemini-3.8-flash-high", "gemini-3.8-flash-low"]
        } else {
            available.unavailable[.gemini] = GeminiProfile.signInHint
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fd-render-tab-model-\(UUID().uuidString)")
        return IntakeService(store: IntakeStore(root: root), triageSettings: TriageSettings(agent: .codex, model: "m1", effort: "high"),
                             availableModels: available, inject: { _, _, _, _ in true }, hasSession: { _, _ in false })
    }

    private func preferences(first: AgentID) -> PreferencesStore {
        let store = PreferencesStore(persistence: nil)
        // Synthetic accounts: a bare store would show whatever login this Mac really has.
        store.preferences.accountList = AccountList(entries: [
            .account(account("Personal", .claude)), .account(account("Work", .claude)),
            .account(account("Personal", .grok)), .account(account("Work", .grok)),
            .account(account("Default", .gemini)),
        ])
        let rows: [AgentSettings] = [
            AgentSettings(id: .grok, options: .grok(GrokOptions(model: "grok-4.7-build-fast", effort: "low"))),
            AgentSettings(id: .gemini, options: .gemini(GeminiOptions(mode: "plan"))),
            AgentSettings(id: .claude, options: .claude(FlagSet())),
            AgentSettings(id: .codex, options: .codex(CodexThreadOptions())),
        ]
        store.preferences.agents = rows.filter { $0.id == first } + rows.filter { $0.id != first }
        return store
    }

    private func account(_ name: String, _ agent: AgentID) -> AgentAccount {
        AgentAccount(agent: agent, displayName: name,
                     home: URL(fileURLWithPath: "/tmp/fd-render-tab-model/\(agent.rawValue)-\(name.lowercased())"),
                     cachedIdentity: AccountIdentity(email: "\(name.lowercased())@example.com", organization: nil))
    }

    private func sessions() -> SessionStore { SessionStore(provider: nil, persistence: nil) }

    func testRenderAgentsPanes() throws {
        let dir = try outputDirectory()
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            for (agent, signedIn) in [(AgentID.grok, true), (.gemini, true), (.gemini, false)] {
                let file = "agents-\(agent.rawValue)\(signedIn ? "" : "-signed-out")-\(name).png"
                try PlanningRender.write(
                    AgentsSettingsTab(preferences: preferences(first: agent), sessions: sessions(),
                                      modelSource: detection(geminiSignedIn: signedIn)),
                    size: size, to: dir.appendingPathComponent(file), appearance: appearance)
            }
        }
    }

    func testRenderProjectsPanes() throws {
        let dir = try outputDirectory()
        let path = "/tmp/fd-render-project"
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            // grok: the project overrides only the effort, so the model row shows the global one
            // as inherited.
            let grok = preferences(first: .claude)
            grok.setProjectSettings(path, ProjectSettings(defaultAgent: .grok, options: [.grok: .grok(GrokOptions(effort: "high"))]))
            grok.selectedProjectPath = URL(fileURLWithPath: path).standardizedFileURL.path
            try PlanningRender.write(ProjectsSettingsTab(preferences: grok, sessions: sessions(),
                                                         modelSource: detection(geminiSignedIn: true)),
                                     size: size, to: dir.appendingPathComponent("projects-grok-\(name).png"),
                                     appearance: appearance)

            // gemini: a non-Gemini model, so the pane says the tab starts on the default.
            let gemini = preferences(first: .claude)
            gemini.setProjectSettings(path, ProjectSettings(defaultAgent: .gemini,
                                                            options: [.gemini: .gemini(GeminiOptions(model: "claude-opus-5-5-high"))]))
            gemini.selectedProjectPath = URL(fileURLWithPath: path).standardizedFileURL.path
            try PlanningRender.write(ProjectsSettingsTab(preferences: gemini, sessions: sessions(),
                                                         modelSource: detection(geminiSignedIn: true)),
                                     size: size, to: dir.appendingPathComponent("projects-gemini-\(name).png"),
                                     appearance: appearance)
        }
    }
}
