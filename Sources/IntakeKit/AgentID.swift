import Foundation

/// Which coding agent something runs: a tab, a planning run, a routing target, a pool, an account.
///
/// The ONE agent identity (unify brief R1/R2). It replaced three that had drifted apart: the
/// app's `AgentID` (claude/codex, tabs), IntakeKit's `Harness` (codex/claude/grok/gemini,
/// headless planning) and Level 3's `HarnessID` (a free string, routing). It lives here rather
/// than in the app because the planning runner (`flightdeck intake run`) is a separate process
/// that links IntakeKit and nothing else, and it has to name the same four agents the app does.
///
/// **The raw values are a storage format, unchanged from all three predecessors** — they are
/// written into `sessions.json`, `preferences.v1` (accounts, project settings, the rule
/// compiler, capacity pools), `intake.json`, round tapes, `routing.json` and execution blocks
/// in task descriptions, mostly under the old JSON key `harness`. Renaming a case, or spelling
/// a raw value differently, makes every one of those files fail to decode.
///
/// Case order is the tab side's order (claude first: ⌘N's historic agent). Planning lists its
/// pickers codex-first instead; that order is `planningOrder`, kept separate so neither side's
/// order silently changes the other's.
public enum AgentID: String, Codable, CaseIterable, Sendable, CodingKeyRepresentable {
    case claude
    case codex
    case grok
    case gemini

    public var displayName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .grok: "Grok"
        case .gemini: "Gemini"
        }
    }

    /// Whether Flight Deck can open a TAB on this agent (unify brief R4). grok and gemini exist
    /// in the enum before their adapters can drive a terminal — planning has run them headless
    /// since the grok/gemini planning work — so every surface that would start a tab asks this
    /// first: the new-tab menus, a project's default-agent picker, the routing targets
    /// (`RoutingCapabilityRegistry.standard`) and the agent list in Settings → Agents. Without
    /// the gate, a stub adapter would be one click away from a tab that types a placeholder
    /// command into a shell.
    ///
    /// Planning availability is NOT this: a planning run is headless, and whether an agent is
    /// offered there stays sign-in detected (`IntakeService.available()`).
    ///
    /// Tracks G and M flip their agent here when its adapter passes its tests — one line, one
    /// place, so "can it run a tab" can never be answered two ways.
    public var tabReady: Bool {
        switch self {
        // grok: Track G's `GrokAdapter`, built from a live probe of grok 1.0.30's TUI.
        case .claude, .codex, .grok: true
        case .gemini: false
        }
    }

    /// The agents a new tab can be opened on, in `allCases` order.
    public static var tabReadyCases: [AgentID] { allCases.filter(\.tabReady) }

    /// The order planning pickers list agents in, and the order `PresetExpansion` and the
    /// cross-check fallback search them: codex first. This was `Harness.allCases`' order, and the
    /// round presets are built around it (seat "A" is codex when codex is installed), so it is
    /// kept verbatim rather than inheriting the tab side's claude-first order.
    public static let planningOrder: [AgentID] = [.codex, .claude, .grok, .gemini]
}
