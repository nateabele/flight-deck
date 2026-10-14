import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Renders the Rounds editor's model menu, effort and Account rows offscreen to PNGs (the
/// technique of `RoundConfigEditorRenderTests`), into `FD_ROUNDS_RENDER_DIR` or, by default,
/// `DerivedData/fd-test-shards/rounds-renders` — the directory the remote unit run copies back.
/// A menu's open popup is not part of a view's layer, so these show the closed buttons, the
/// effort control present or absent, and the Account row as a line or a picker.
@MainActor
final class RoundEditorModelsRenderTests: XCTestCase {
    private var outputDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["FD_ROUNDS_RENDER_DIR"] { return URL(fileURLWithPath: dir) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        return root.appendingPathComponent("DerivedData/fd-test-shards/rounds-renders", isDirectory: true)
    }

    private var available: AvailableModels {
        var a = AvailableModels(choices: [
            .claude: ClaudeProfile().defaultPlanningChoice, .codex: CodexProfile().defaultPlanningChoice,
            .gemini: GeminiProfile().defaultPlanningChoice,
            .opencode: ModelChoice(agent: .opencode, model: "opencode/big-pickle", effort: ""),
        ])
        a.options = [
            .claude: [ModelOption(id: "claude-opus-5-5", name: "Opus 5.5", efforts: ["low", "medium", "high", "xhigh", "max"]),
                      ModelOption(id: "claude-haiku-4-5-20251001", name: "Haiku 4.5", efforts: []),
                      ModelOption(id: "opus", name: "Opus 5.5 (latest)", efforts: ["low", "medium", "high", "xhigh", "max"])],
            .codex: [ModelOption(id: "gpt-6-sol", name: "GPT 6 Sol", efforts: ["low", "medium", "high", "xhigh", "max"])],
            .gemini: [ModelOption(id: GeminiProfile.defaultPlanningModel, name: "Gemini 3.8 Flash (High)")],
            .opencode: [ModelOption(id: "opencode/big-pickle", name: "Big Pickle")],
        ]
        a.unavailable[.grok] = "Grok: run `grok login`"
        return a
    }

    private func config() throws -> RoundConfig {
        var cfg = try XCTUnwrap(PresetExpansion.config(for: .featurePlan, available: available))
        cfg.drafters = [
            Slot(ModelChoice(agent: .claude, model: "claude-opus-5-5", effort: "high"), persona: .arbiter,
                 fallback: ModelChoice(agent: .codex, model: "gpt-6-sol", effort: "high")),
            Slot(ModelChoice(agent: .codex, model: "gpt-6-sol", effort: "high"), persona: .realist),
        ]
        return cfg
    }

    private func editor(_ cfg: RoundConfig, section: RoundsSection, accounts: [AgentID: AccountMenu]) -> some View {
        RoundConfigEditor(preset: .featurePlan, config: .constant(cfg), available: available, accounts: accounts,
                          selection: .constant(RoundTimeline.Selection(section: section, round: nil)))
    }

    func testRenderModelMenusEffortAndAccounts() throws {
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let single: [AgentID: AccountMenu] = [.claude: AccountMenu(projectDefault: "Personal"), .codex: AccountMenu(projectDefault: "Work pool")]
        let team = AccountChoice.pool("team"), work = AccountChoice.account(UUID())
        let several: [AgentID: AccountMenu] = [
            .claude: AccountMenu(projectDefault: "Personal", options: [
                .init(choice: work, title: "Work", isPool: false), .init(choice: team, title: "Team", isPool: true)], offersChoice: true),
            .codex: AccountMenu(projectDefault: "Work pool"),
        ]
        var held = try config()
        held.reviewer = Slot(ModelChoice(agent: .claude, model: "claude-opus-5-5", effort: "high", account: team))
        held.reviewer?.fallback = ModelChoice(agent: .claude, model: "claude-haiku-4-5-20251001", effort: "", account: work)
        held.reviewers = nil

        var hidden = try config()
        hidden.reviewer = Slot(ModelChoice(agent: .claude, model: "claude-haiku-4-5-20251001", effort: ""))
        hidden.integrator = ModelChoice(agent: .gemini, model: GeminiProfile.defaultPlanningModel, effort: "")
        hidden.integrators = nil
        hidden.reviewers = nil

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            try render(editor(try config(), section: .draft, accounts: single), size: NSSize(width: 460, height: 420),
                       to: "rounds-models-draft-single-account-\(name)", appearance: appearance)
            try render(editor(hidden, section: .refine, accounts: single), size: NSSize(width: 460, height: 620),
                       to: "rounds-models-effort-hidden-\(name)", appearance: appearance)
            try render(editor(held, section: .refine, accounts: several), size: NSSize(width: 460, height: 620),
                       to: "rounds-models-account-picker-\(name)", appearance: appearance)
        }
    }

    private func render(_ view: some View, size: NSSize, to name: String, appearance: NSAppearance.Name) throws {
        let url = outputDirectory.appendingPathComponent("\(name).png")
        let root = view.padding(16).frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        host.layoutSubtreeIfNeeded()
        let scale: CGFloat = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
                                                 pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                 bytesPerRow: 0, bitsPerPixel: 0))
        let context = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: rep)).cgContext
        context.translateBy(x: 0, y: size.height * scale)
        context.scaleBy(x: scale, y: -scale)
        try XCTUnwrap(host.layer).render(in: context)
        window.orderOut(nil)
        let png = try XCTUnwrap(rep.representation(using: .png, properties: [:]))
        XCTAssertGreaterThan(png.count, 2_000, name)
        try png.write(to: url)
    }
}
