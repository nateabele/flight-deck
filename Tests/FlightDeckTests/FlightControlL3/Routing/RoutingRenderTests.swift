import AppKit
import IntakeKit
import SwiftUI
import XCTest
@testable import FlightDeck

/// Renders Settings → Flight Control → Routing offscreen, light and dark, for design review:
/// the real tab and pane over a real `RoutingService`, with fixture rules in every row state
/// (live with a hint, waiting for Use, live and adjusted, failed, compiling), plus each popover.
/// Skipped unless `FD_ROUTING_RENDER_DIR` names an output directory. Pictures, not assertions:
/// layout is looked at without launching the app (AGENTS.md rule 2).
@MainActor
final class RoutingRenderTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory.appendingPathComponent("RoutingRenderTests-\(UUID())", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
        super.tearDown()
    }

    private final class StubProvider: SurfaceProvider {
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? { nil }
        func tick() {}
        var defaultFontSize: Float { 12 }
    }

    /// Never answers within the render, so the rule it was asked about stays mid-compile.
    private struct HangingCompiler: RuleCompiling {
        var ref: CompilerRef { CompilerRef(agent: .claude, model: "haiku") }
        func propose(_ input: RuleCompilerInput) async -> RuleProposal {
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            return .unavailable("render")
        }
    }

    private func service() async throws -> (RoutingService, PreferencesStore, String) {
        let project = root.appendingPathComponent("fixture-project", isDirectory: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".flightdeck"), withIntermediateDirectories: true)
        try Data(RoutingUIFixture.kindsJSON.utf8).write(to: KindRegistryStore.fileURL(project: project))
        try Data(RoutingUIFixture.routingJSON.utf8).write(to: ProjectRoutingStore.fileURL(project: project))

        let prefs = PreferencesStore(persistence: nil)
        let at = Date(timeIntervalSince1970: 1_790_000_000)
        let haiku = CompilerRef(agent: .claude, model: "haiku")
        prefs.globalRoutingRules = [
            RoutingRule(id: "g1", sentence: "Use Codex for unit and integration tests, and for complex algorithms",
                        compiled: CompiledRule(match: .any([.dimension("test-authoring", atLeast: 0.5),
                                                            .dimension("algorithmic-reasoning", atLeast: 0.6), .kind("tests")]),
                                               assign: RuleAssign(agent: .codex, model: "gpt-6-sol", knobs: ["effort": "high"],
                                                                  pool: "codex-default")),
                        state: .compiled, compiledAt: at, compiler: haiku),
            RoutingRule(id: "g2", sentence: "Simple implementation tasks go to Claude Haiku",
                        compiled: CompiledRule(match: .any([.kind("implement-simple")]),
                                               assign: RuleAssign(agent: .claude, model: "haiku", knobs: ["effort": "low"],
                                                                  pool: "claude-default")),
                        state: .confirmed, compiledAt: at, compiler: haiku, adjusted: true),
            RoutingRule(id: "g3", sentence: "Anything UI-heavy uses Sonnet", state: .failed,
                        failure: RuleValidationError.unknownModel("claude", "Sonnet", suggestion: "sonnet").message,
                        compiledAt: at, compiler: haiku),
            RoutingRule(id: "g4", sentence: "Debugging goes to Codex at high effort"),
        ]
        let svc = RoutingService(preferences: prefs, kindStore: KindRegistryStore(),
                                 makeCompiler: { HangingCompiler() }, loadCatalogs: { RoutingUIFixture.catalogs },
                                 pools: DefaultPoolDirectory(agents: [.claude, .codex]), hints: FixtureHints(),
                                 tasks: FixtureOpenTasks(), writer: FixtureBlockWriter(), fixtureProjects: [project.path])
        _ = await svc.catalogs()
        svc.startCompile("g4", in: .global)
        return (svc, prefs, project.path)
    }

    func testRenderRoutingPane() async throws {
        guard let dir = ProcessInfo.processInfo.environment["FD_ROUTING_RENDER_DIR"] else {
            throw XCTSkip("set FD_ROUTING_RENDER_DIR to render the routing PNGs")
        }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let (svc, prefs, project) = try await service()
        let sessions = SessionStore(provider: StubProvider(), persistence: nil)
        let size = NSSize(width: 720, height: 600)

        let g1 = try XCTUnwrap(prefs.globalRoutingRules.first)
        let p1 = try XCTUnwrap(svc.rules(.project(project)).first)
        let hint = try XCTUnwrap(svc.hint(for: p1, scope: .project(project)))

        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let tab = FlightControlSettingsTab(preferences: prefs, sessions: sessions, routing: svc)
            try Self.write(tab, size: size, appearance: appearance, to: out.appendingPathComponent("routing-\(name).png"))
            // Mid-typing: a sentence being reworded inline and a new rule half typed. A grouped
            // form pushes a TextField's text to the trailing edge unless told otherwise.
            try Self.write(FlightControlRoutingPane(routing: svc, preferences: prefs, project: project,
                                                    drafts: [.global: "Use Claude for frontend work"], editing: "g2"),
                           size: size, appearance: appearance, to: out.appendingPathComponent("routing-typing-\(name).png"))
            // Narrower than the Settings window, as its grouped form's wider insets leave it in
            // practice: the pills must wrap here, never truncate.
            try Self.write(FlightControlSettingsTab(preferences: prefs, sessions: sessions, routing: svc),
                           size: NSSize(width: 560, height: 640), appearance: appearance,
                           to: out.appendingPathComponent("routing-narrow-\(name).png"))
            try Self.write(FlightControlSettingsTab(preferences: prefs, sessions: sessions, routing: svc, initialSection: .kinds),
                           size: size, appearance: appearance, to: out.appendingPathComponent("kinds-\(name).png"))

            // Popovers composited over the pane where they anchor: AppKit draws a real popover
            // in its own window, which an offscreen capture of the pane cannot see.
            let target = RoutingTargetEditor(routing: svc, ruleID: g1.id, scope: .global, assign: g1.compiled!.assign)
            try Self.write(Self.over(FlightControlSettingsTab(preferences: prefs, sessions: sessions, routing: svc),
                                     popover: target, at: CGPoint(x: 330, y: 300)),
                           size: size, appearance: appearance, to: out.appendingPathComponent("routing-target-popover-\(name).png"))

            let condition = RoutingConditionEditor(routing: svc, ruleID: g1.id, scope: .global, match: g1.compiled!.match,
                                                   index: 0, close: {})
            try Self.write(Self.over(FlightControlSettingsTab(preferences: prefs, sessions: sessions, routing: svc),
                                     popover: condition, at: CGPoint(x: 40, y: 300)),
                           size: size, appearance: appearance, to: out.appendingPathComponent("routing-condition-popover-\(name).png"))

            // Each popover alone too, at 2x, to check its grid edges up close.
            let newCondition = RoutingConditionEditor(routing: svc, ruleID: g1.id, scope: .global, match: g1.compiled!.match,
                                                      index: nil, close: {})
            let kindCondition = RoutingConditionEditor(routing: svc, ruleID: g1.id, scope: .global, match: g1.compiled!.match,
                                                       index: 2, close: {})
            let pieces: [(String, AnyView)] = [
                ("target", AnyView(target)),
                ("condition", AnyView(condition)),
                ("condition-kind", AnyView(kindCondition)),
                ("condition-new", AnyView(newCondition)),
                ("hint", AnyView(RoutingHintPopover(routing: svc, hint: hint, scope: .project(project), close: {}))),
                ("compiler", AnyView(RoutingCompilerPopover(routing: svc, preferences: prefs))),
            ]
            for (piece, view) in pieces {
                try Self.write(Self.chrome(view).padding(24), size: nil, appearance: appearance,
                               to: out.appendingPathComponent("popover-\(piece)-\(name).png"))
            }
        }
    }

    // MARK: - Rendering

    /// A popover's own chrome, approximated: the content on the popover material's colour, a
    /// hairline and a soft shadow.
    private static func chrome(_ content: some View) -> some View {
        content
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(nsColor: .windowBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.28), radius: 16, y: 6)
    }

    private static func over(_ base: some View, popover: some View, at point: CGPoint) -> some View {
        ZStack(alignment: .topLeading) {
            base
            chrome(popover).offset(x: point.x, y: point.y)
        }
    }

    /// The offscreen technique: an `NSHostingView` parked in a borderless window far off-screen,
    /// captured with `cacheDisplay`. `size` nil sizes the view to fit.
    private static func write(_ view: some View, size: NSSize?, appearance: NSAppearance.Name, to url: URL) throws {
        let root = view
            .frame(width: size?.width, height: size?.height, alignment: .topLeading)
            .background(Color(nsColor: .windowBackgroundColor))
            .environment(\.controlActiveState, .key)
        let host = NSHostingView(rootView: root)
        let fitted = size ?? host.fittingSize
        host.frame = NSRect(origin: .zero, size: fitted)
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: fitted.width, height: fitted.height),
                              styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        host.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.orderFrontRegardless()
        host.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        host.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: rep)
        window.orderOut(nil)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }
}
