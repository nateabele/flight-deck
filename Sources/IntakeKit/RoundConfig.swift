import Foundation

/// The angle a drafter is asked to take. `.general` is the only persona a single-drafter
/// round (Sketch) ever uses; Feature/Full plan assign the rest to spread disagreement across
/// drafts rather than have every model converge on the same read.
public enum DrafterPersona: String, Codable, Sendable, CaseIterable {
    case general, arbiter, realist, coverage, stressTest
}

/// One harness/model/effort triple. Distinct from `HarnessSession` (which also carries a
/// live `sessionID`) — a `RoundConfig` describes what to run, before any session exists.
public struct ModelChoice: Codable, Equatable, Sendable {
    public var harness: Harness
    public var model: String
    public var effort: String
    /// The account this seat bills (grok/gemini spec §3.0), picked in the Rounds editor. nil is
    /// the built-in account, which every config written before accounts reached planning
    /// decodes to — the key is absent from those files, and stays absent when nil is encoded,
    /// so an untouched config is byte-identical. Carries the home, not just the id: the runner
    /// is a separate process with no preferences to resolve an id against.
    public var account: AgentAccountRef?
    public init(harness: Harness, model: String, effort: String, account: AgentAccountRef? = nil) {
        self.harness = harness
        self.model = model
        self.effort = effort
        self.account = account
    }
}

public extension AgentProfile {
    /// The model and effort a fresh planning seat on this harness starts at — the profile's
    /// catalog default, so triage, `AvailableModels.defaults` and the editor's harness switch
    /// can never name different defaults.
    var defaultPlanningChoice: ModelChoice {
        ModelChoice(harness: id, model: modelCatalog.defaultPlanningModel, effort: modelCatalog.defaultPlanningEffort)
    }
}

/// A single seat in a round: the model doing the work, the persona it's asked to take, and
/// the model to retry with if the first one fails outright (not a quality fallback — an
/// availability one).
public struct Slot: Codable, Equatable, Sendable {
    public var choice: ModelChoice
    public var persona: DrafterPersona
    public var fallback: ModelChoice?
    public init(_ choice: ModelChoice, persona: DrafterPersona = .general, fallback: ModelChoice? = nil) {
        self.choice = choice
        self.persona = persona
        self.fallback = fallback
    }
}

/// How far an armed round is allowed to run before it stops and hands back to the human.
/// `.step` runs one stage; `.nextMajor` runs to the next major checkpoint (e.g. through
/// refinement or through polish); `.toReview` runs everything and lands on release review.
public enum PlayMode: String, Codable, Sendable { case step, nextMajor, toReview }

/// Which Refine rounds a second model family reviews in parallel (coverage spec §3). Synthesis
/// never does: the synthesizer merges drafts rather than searching the plan for problems, so its
/// proposals are not a review sample.
public enum CrossCheckPolicy: String, Codable, Sendable, CaseIterable { case off, firstAndLast, every }

/// A model's vendor lineage — what "cross-family" and coverage are counted over. Derived from the
/// harness today; a later harness (Qwen, say) adds a case here and nothing else changes.
public enum ModelFamily: String, Codable, Sendable {
    case codex, claude, grok, gemini
    public init(_ harness: Harness) {
        switch harness {
        case .codex: self = .codex
        case .claude: self = .claude
        case .grok: self = .grok
        case .gemini: self = .gemini
        }
    }
    public var displayName: String {
        switch self {
        case .codex: "Codex"
        case .claude: "Claude"
        case .grok: "Grok"
        case .gemini: "Gemini"
        }
    }
}

/// The fully expanded shape of a shaping round: every seat, every cap, and the play mode a
/// "Continue" click uses by default. `PresetExpansion` builds the initial one from a
/// `Preset`; the config editor (Task 13) lets the human edit it in place, at which point
/// `customized` flips true so later tooling can tell an edited config from a stock one.
public struct RoundConfig: Codable, Equatable, Sendable {
    public var drafters: [Slot]
    public var synthesizer: Slot?
    public var reviewer: Slot?
    public var integrator: ModelChoice
    public var encoder: ModelChoice
    public var polisher: ModelChoice?
    public var refinementCap: Int
    public var polishCap: Int
    public var freshEyesAndDedup: Bool
    public var defaultPlay: PlayMode
    public var customized: Bool
    /// The second family's reviewer on cross-check rounds. No fallback, ever: its fallback
    /// would be the primary's family, and a same-family "cross-check" is not independent.
    /// Optional so an `intake.json` written before cross-checks decodes unchanged.
    public var crossReviewer: Slot?
    /// nil reads as `.off` — every intake from before this existed, larkOS included.
    public var crossCheck: CrossCheckPolicy?

    /// Whether any round can cross-check: a policy, both reviewers, and two different families.
    public var crossChecks: Bool {
        guard let policy = crossCheck, policy != .off, let reviewer, let crossReviewer else { return false }
        return ModelFamily(reviewer.choice.harness) != ModelFamily(crossReviewer.choice.harness)
    }

    public init(drafters: [Slot], synthesizer: Slot?, reviewer: Slot?, integrator: ModelChoice,
                encoder: ModelChoice, polisher: ModelChoice?, refinementCap: Int, polishCap: Int,
                freshEyesAndDedup: Bool, defaultPlay: PlayMode, customized: Bool,
                crossReviewer: Slot? = nil, crossCheck: CrossCheckPolicy? = nil) {
        self.drafters = drafters
        self.synthesizer = synthesizer
        self.reviewer = reviewer
        self.integrator = integrator
        self.encoder = encoder
        self.polisher = polisher
        self.refinementCap = refinementCap
        self.polishCap = polishCap
        self.freshEyesAndDedup = freshEyesAndDedup
        self.defaultPlay = defaultPlay
        self.customized = customized
        self.crossReviewer = crossReviewer
        self.crossCheck = crossCheck
    }
}

/// Which harnesses are actually installed, and the model/effort each should run at. Any
/// harness can be missing — a machine with only one CLI installed still gets a usable, if
/// single-model, round.
///
/// A map rather than one field per harness (grok/gemini spec §3.2), so Tracks G and M each add
/// a harness without touching the other's lines. GATED: `choices` never holds a harness outside
/// `AgentProfiles.headlessReady`, whatever a caller passes in. Without that, a detected `grok`
/// binary would be offered in the Rounds editor and then fail at round time, because its
/// `HarnessCommand.build` arm only refuses until Track G lands.
public struct AvailableModels: Sendable, Equatable {
    public private(set) var choices: [Harness: ModelChoice]

    public init(choices: [Harness: ModelChoice]) {
        self.choices = choices.filter { AgentProfiles.headlessReady.contains($0.key) }
    }

    public init(codex: ModelChoice?, claude: ModelChoice?) {
        var choices: [Harness: ModelChoice] = [:]
        choices[.codex] = codex
        choices[.claude] = claude
        self.init(choices: choices)
    }

    /// Each harness's model ids, as its CLI listed them at detection (`grok models`), for the
    /// editor's model picker. Absent for a harness with no list command (claude, codex), whose
    /// model stays a free text field. Generic over `Harness` so Track M's gemini list lands here
    /// too rather than in a field of its own.
    public var models: [Harness: [String]] = [:]

    /// Why a harness this build CAN run is not offered: its CLI is missing ("not installed") or
    /// signed out (its profile's hint, e.g. "Grok: run `grok login`"). The editor shows these,
    /// so a harness is never silently missing from a picker (spec §3.2).
    public var unavailable: [Harness: String] = [:]

    public func choice(for harness: Harness) -> ModelChoice? { choices[harness] }

    /// Every available harness, in `Harness.allCases` order — the order pickers list them in.
    public var harnesses: [Harness] { Harness.allCases.filter { choices[$0] != nil } }

    public var codex: ModelChoice? {
        get { choices[.codex] }
        set { choices[.codex] = newValue }
    }
    public var claude: ModelChoice? {
        get { choices[.claude] }
        set { choices[.claude] = newValue }
    }

    /// Each profile's planning default — codex gpt-6-sol/high and claude opus/high — when
    /// both are present.
    public static let defaults = AvailableModels(
        codex: CodexProfile().defaultPlanningChoice,
        claude: ClaudeProfile().defaultPlanningChoice
    )
}

/// Turns a chosen fidelity preset into a starting `RoundConfig`, before any human edits it.
public enum PresetExpansion {
    /// "A" is the first available model, codex if present, else claude. "B" is the other one
    /// if present, else A — so a single-harness machine gets every seat filled with the one
    /// model it has, and no fallback pointing at a model that doesn't exist.
    public static func config(for preset: Preset, available: AvailableModels) -> RoundConfig? {
        guard preset != .bead else { return nil }
        let a: ModelChoice
        let b: ModelChoice
        if let codex = available.codex {
            a = codex
            b = available.claude ?? codex
        } else if let claude = available.claude {
            a = claude
            b = claude
        } else {
            return nil
        }
        // Fallbacks only make sense when there's a second model to fall back to — otherwise
        // the "fallback" is the same model that just failed.
        let hasFallback = available.codex != nil && available.claude != nil
        let integrator = available.claude ?? a
        let encoder = a

        switch preset {
        case .bead:
            return nil
        case .sketch:
            return RoundConfig(
                drafters: [Slot(a, persona: .general, fallback: hasFallback ? b : nil)],
                synthesizer: nil,
                reviewer: Slot(a, fallback: hasFallback ? b : nil),
                integrator: integrator, encoder: encoder, polisher: nil,
                refinementCap: 2, polishCap: 0, freshEyesAndDedup: false,
                defaultPlay: .toReview, customized: false,
                crossReviewer: hasFallback ? Slot(b) : nil, crossCheck: hasFallback ? .off : nil)
        case .featurePlan:
            return RoundConfig(
                drafters: [
                    Slot(a, persona: .arbiter, fallback: hasFallback ? b : nil),
                    Slot(b, persona: .realist, fallback: hasFallback ? a : nil),
                ],
                synthesizer: Slot(a, persona: .arbiter, fallback: hasFallback ? b : nil),
                reviewer: Slot(a, fallback: hasFallback ? b : nil),
                integrator: integrator, encoder: encoder, polisher: available.claude ?? a,
                refinementCap: 3, polishCap: 2, freshEyesAndDedup: false,
                defaultPlay: .nextMajor, customized: false,
                crossReviewer: hasFallback ? Slot(b) : nil, crossCheck: hasFallback ? .firstAndLast : nil)
        case .fullPlan:
            return RoundConfig(
                drafters: [
                    Slot(a, persona: .arbiter, fallback: hasFallback ? b : nil),
                    Slot(b, persona: .realist, fallback: hasFallback ? a : nil),
                    Slot(a, persona: .coverage, fallback: hasFallback ? b : nil),
                    Slot(b, persona: .stressTest, fallback: hasFallback ? a : nil),
                ],
                synthesizer: Slot(a, persona: .arbiter, fallback: hasFallback ? b : nil),
                reviewer: Slot(a, fallback: hasFallback ? b : nil),
                integrator: integrator, encoder: encoder, polisher: available.claude ?? a,
                refinementCap: 5, polishCap: 6, freshEyesAndDedup: true,
                defaultPlay: .nextMajor, customized: false,
                crossReviewer: hasFallback ? Slot(b) : nil, crossCheck: hasFallback ? .firstAndLast : nil)
        }
    }
}
