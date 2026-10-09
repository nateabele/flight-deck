import XCTest
import IntakeKit
@testable import FlightDeck

/// grok and gemini tabs choose a model the way claude and codex tabs do: one `AgentOptions` arm
/// per agent, edited in Settings → Agents and per project, merged field by field, and applied
/// at launch AND resume. Every model id and reason below is synthetic or a probed public slug.
@MainActor
final class TabModelOptionsTests: XCTestCase {

    // MARK: Merge

    /// A project that sets only the effort must keep the global model, and vice versa — the
    /// old resolver handed back the project's payload whole, so a project override of one
    /// field silently cleared the other.
    func testGrokProjectOverridesMergeFieldByField() {
        let store = PreferencesStore(persistence: nil)
        store.preferences.agents = [AgentSettings(id: .grok, options: .grok(GrokOptions(model: "grok-4.6", effort: "high")))]
        store.setProjectSettings("/tmp/repo", ProjectSettings(options: [.grok: .grok(GrokOptions(model: nil, effort: "low"))]))
        XCTAssertEqual(store.resolvedOptions(for: .grok, project: "/tmp/repo"),
                       .grok(GrokOptions(model: "grok-4.6", effort: "low")))
        XCTAssertEqual(store.resolvedOptions(for: .grok, project: "/tmp/other"),
                       .grok(GrokOptions(model: "grok-4.6", effort: "high")))
    }

    func testGeminiProjectOverridesMergeFieldByField() {
        let store = PreferencesStore(persistence: nil)
        store.preferences.agents = [AgentSettings(id: .gemini, options: .gemini(GeminiOptions(model: "gemini-3.8-flash-low", mode: "plan")))]
        store.setProjectSettings("/tmp/repo", ProjectSettings(options: [.gemini: .gemini(GeminiOptions(model: "gemini-3.1-pro-high"))]))
        XCTAssertEqual(store.resolvedOptions(for: .gemini, project: "/tmp/repo"),
                       .gemini(GeminiOptions(model: "gemini-3.1-pro-high", mode: "plan")))
    }

    /// A row stored before `mode` existed still decodes, and an emptied gemini override is
    /// still recognised as empty (so the project loses its badge rather than keeping a husk).
    func testGeminiOptionsDecodeWithoutModeAndEmptyStaysEmpty() throws {
        let decoded = try JSONDecoder().decode(GeminiOptions.self, from: Data(#"{"model":"gemini-3.8-flash-low"}"#.utf8))
        XCTAssertEqual(decoded, GeminiOptions(model: "gemini-3.8-flash-low"))
        XCTAssertNil(decoded.mode)
        XCTAssertTrue(AgentOptions.gemini(GeminiOptions()).isEmpty)
        XCTAssertFalse(AgentOptions.gemini(GeminiOptions(mode: "plan")).isEmpty)
    }

    // MARK: Launch and resume

    private func geminiSession() -> Session {
        Session(title: "t", workingDirectory: "/tmp/project",
                pinnedConversationID: UUID(uuidString: "5e7b8b6d-c690-43b3-877e-0049c1db7ca8")!, agent: .gemini)
    }

    /// `agy --mode accept-edits|plan` (agy 1.3.1 `--help`, probed in its TUI): applied at launch
    /// and at resume, and anything else — a value typed at a shell — is dropped, not typed.
    func testGeminiModeIsAppliedAtLaunchAndResume() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fd-tab-model-\(UUID().uuidString)")
        var adapter = GeminiAdapter(paths: GeminiPaths(root: root))
        let s = geminiSession(), b = adapter.binding(for: s)
        let plan = AgentOptions.gemini(GeminiOptions(model: "gemini-3.8-flash-low", mode: "plan"))
        XCTAssertEqual(adapter.launchCommand(b, s, plan), "agy --model gemini-3.8-flash-low --mode plan\n")
        adapter.exists = { _ in true }
        XCTAssertEqual(adapter.resumeCommand(b, s, plan),
                       "agy --conversation=5e7b8b6d-c690-43b3-877e-0049c1db7ca8 --model gemini-3.8-flash-low --mode plan\n")
        XCTAssertEqual(adapter.launchCommand(b, s, .gemini(GeminiOptions(mode: "yolo; rm -rf ~"))),
                       "agy --model gemini-3.1-pro-high\n")
    }

    /// The Settings preview and the tab type the same tail, so the preview cannot drift.
    func testGrokFlagTailIsWhatLaunchTypes() {
        let options = GrokOptions(model: "grok-4.7-build-fast", effort: "low")
        XCTAssertEqual(GrokAdapter.flagTail(options), " -m 'grok-4.7-build-fast' --effort 'low'")
        XCTAssertEqual(GrokAdapter.flagTail(GrokOptions()), "")
    }

    /// The pane's "Launch command" preview is the adapters' own spelling, gemini's fallback
    /// for a non-Gemini model included.
    func testLaunchPreviewIsTheAdaptersCommand() {
        XCTAssertEqual(TabModelOptionsForm.launchPreview(.grok(GrokOptions(model: "grok-4.6", effort: "high"))),
                       "grok -s ⟨generated⟩ -m 'grok-4.6' --effort 'high'")
        XCTAssertEqual(TabModelOptionsForm.launchPreview(.gemini(GeminiOptions(model: "claude-opus-5-5-high", mode: "accept-edits"))),
                       "agy --model gemini-3.1-pro-high --mode accept-edits")
    }

    // MARK: Picker choices (from planning's detection, never a second probe)

    private func detected(grok: [String]? = nil, gemini: [String]? = nil,
                          unavailable: [AgentID: String] = [:]) -> AvailableModels {
        var available = AvailableModels(choices: [:])
        if let grok { available.models[.grok] = grok }
        if let gemini { available.models[.gemini] = gemini }
        available.unavailable = unavailable
        return available
    }

    func testGrokOffersTheDetectedListOverTheStaleAliases() {
        let choices = TabModelChoices(agent: .grok, available: detected(grok: ["grok-5", "grok-4.7"]), chosenModel: nil)
        XCTAssertEqual(choices.models, ["grok-5", "grok-4.7"])
        XCTAssertEqual(choices.efforts, GrokProfile().modelCatalog.effortValues)
        XCTAssertEqual(choices.modes, [])
        XCTAssertEqual(choices.defaultModelTitle, "Default (grok-5)")
        XCTAssertEqual(choices.notes, [])
    }

    /// Before detection lands (or when it could not list), the profile's fallbacks are offered
    /// and the pane says so, rather than presenting a stale list as the account's.
    func testBeforeDetectionTheFallbackListIsOfferedAndLabelled() {
        let choices = TabModelChoices(agent: .grok, available: nil, chosenModel: nil)
        XCTAssertEqual(choices.models, GrokProfile().modelCatalog.aliases)
        XCTAssertEqual(choices.defaultModelTitle, "grok's default")
        XCTAssertEqual(choices.notes, ["Still asking grok for this account's models; showing the built-in list."])
    }

    /// An agent planning found unusable says why, in planning's words — never silently empty.
    func testAnUnavailableAgentShowsPlanningsReason() {
        let choices = TabModelChoices(agent: .gemini,
                                      available: detected(unavailable: [.gemini: GeminiProfile.signInHint]),
                                      chosenModel: nil)
        XCTAssertEqual(choices.models, [GeminiAdapter.defaultModel])
        XCTAssertEqual(choices.notes.first, "Unavailable: \(GeminiProfile.signInHint)")
    }

    func testAChosenModelTheAccountDoesNotListIsFlagged() {
        let choices = TabModelChoices(agent: .grok, available: detected(grok: ["grok-4.7"]), chosenModel: "grok-3")
        XCTAssertEqual(choices.notes, ["`grok models` does not list grok-3 for this account."])
    }

    /// agy also serves Claude and GPT-OSS models; a gemini tab silently launches its default
    /// instead (`GeminiAdapter.model(for:)`), so the pane has to say that out loud.
    func testANonGeminiModelSaysTheTabStartsOnTheDefault() {
        let choices = TabModelChoices(agent: .gemini, available: detected(gemini: ["gemini-3.1-pro-high"]),
                                      chosenModel: "claude-opus-5-5-high")
        XCTAssertEqual(choices.defaultModelTitle, "Default (gemini-3.1-pro-high)")
        XCTAssertEqual(choices.modes, GeminiOptions.modes)
        XCTAssertEqual(choices.efforts, [])
        XCTAssertEqual(choices.notes,
                       ["A gemini tab runs Gemini models only; this one starts on gemini-3.1-pro-high instead."])
    }

    // MARK: Which pane

    /// grok and gemini rows used to fall through to Claude's flag pane — editing claude's
    /// global flags from under grok's name.
    func testEveryAgentGetsItsOwnOptionsPane() {
        XCTAssertEqual(AgentOptionsPane(agent: .claude), .claudeFlags)
        XCTAssertEqual(AgentOptionsPane(agent: .codex), .codex)
        XCTAssertEqual(AgentOptionsPane(agent: .grok), .model(.grok))
        XCTAssertEqual(AgentOptionsPane(agent: .gemini), .model(.gemini))
    }
}
