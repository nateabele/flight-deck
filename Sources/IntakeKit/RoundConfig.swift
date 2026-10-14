import Foundation

/// The angle a drafter is asked to take. `.general` is the only persona a single-drafter
/// round (Sketch) ever uses; Feature/Full plan assign the rest to spread disagreement across
/// drafts rather than have every model converge on the same read.
public enum DrafterPersona: String, Codable, Sendable, CaseIterable {
    case general, arbiter, realist, coverage, stressTest
}

/// One agent/model/effort triple. Distinct from `HeadlessSession` (which also carries a
/// live `sessionID`) — a `RoundConfig` describes what to run, before any session exists.
///
/// The agent is stored under the JSON key `harness`, its name before the agent identities were
/// unified (unify brief R1): every `intake.json` and tape on disk spells it that way.
public struct ModelChoice: Codable, Equatable, Sendable {
    public var agent: AgentID
    public var model: String
    public var effort: String
    /// The account or pool this role bills instead of the project's assignment; nil (the usual
    /// case) bills the assignment. The Rounds editor offers it only where the agent has a real
    /// choice, and the app resolves it at each runner start (`RunnerAccounts.overrides`).
    public var account: AccountChoice?
    public init(agent: AgentID, model: String, effort: String, account: AccountChoice? = nil) {
        self.agent = agent
        self.model = model
        self.effort = effort
        self.account = account
    }

    private enum CodingKeys: String, CodingKey {
        case agent = "harness"
        // The override is `accountOverride`, a NEW key. The `account` key an older Rounds editor
        // wrote per seat (before unify brief R9) is deliberately still not read: those configs
        // name whatever account the seat was given months ago, and honouring it would quietly bill
        // a login the project's assignment has since moved off — the failure R9 exists to stop.
        // A keyed decoder skips a key it is not asked for, so they decode, and the next save
        // drops it.
        case model, effort
        case account = "accountOverride"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        agent = try c.decode(AgentID.self, forKey: .agent)
        model = try c.decode(String.self, forKey: .model)
        effort = try c.decode(String.self, forKey: .effort)
        // A value this build cannot read (a newer kind of account) is no override, not a config
        // that fails to load.
        account = try? c.decodeIfPresent(AccountChoice.self, forKey: .account)
    }
}

public extension AgentProfile {
    /// The model and effort a fresh planning seat on this harness starts at — the profile's
    /// catalog default, so triage, `AvailableModels.defaults` and the editor's harness switch
    /// can never name different defaults.
    var defaultPlanningChoice: ModelChoice {
        ModelChoice(agent: id, model: modelCatalog.defaultPlanningModel, effort: modelCatalog.defaultPlanningEffort)
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
    /// Optional rotations for the three roles that repeat round after round, so a long stage is
    /// not one family's. nil or empty is today's single agent (`reviewer`, `integrator`,
    /// `polisher`). With a rotation, Refine round k runs `reviewers[(k-1) % n]` and
    /// `integrators[(k-1) % n]`; the polish stage runs `polishers[i % n]` for polish 1...M as
    /// i = 0...M-1, then fresh eyes (i = M) and dedup (i = M+1). Synthesis keeps the first
    /// integrator. The single fields stay equal to entry 0, so a reader from before rotations
    /// still sees a sensible single agent; `RoundConfigEditor` keeps the two in step.
    /// Optional so an `intake.json` written before rotations decodes unchanged.
    public var reviewers: [Slot]?
    public var integrators: [ModelChoice]?
    public var polishers: [ModelChoice]?

    /// Whether any round can cross-check: a policy, both reviewers, and two different families.
    public var crossChecks: Bool {
        guard let policy = crossCheck, policy != .off, let crossReviewer else { return false }
        return reviewerRotation.contains { $0.choice.agent != crossReviewer.choice.agent }
    }

    public init(drafters: [Slot], synthesizer: Slot?, reviewer: Slot?, integrator: ModelChoice,
                encoder: ModelChoice, polisher: ModelChoice?, refinementCap: Int, polishCap: Int,
                freshEyesAndDedup: Bool, defaultPlay: PlayMode, customized: Bool,
                crossReviewer: Slot? = nil, crossCheck: CrossCheckPolicy? = nil,
                reviewers: [Slot]? = nil, integrators: [ModelChoice]? = nil, polishers: [ModelChoice]? = nil) {
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
        self.reviewers = reviewers
        self.integrators = integrators
        self.polishers = polishers
    }

    /// The reviewer for rotation index `i` (Refine round k is `k - 1`): the rotation's entry, else
    /// the single `reviewer`. nil when the config seats no reviewer (no Refine stage).
    public func reviewer(rotation i: Int) -> Slot? {
        guard reviewer != nil else { return nil }
        return Self.entry(reviewers, i) ?? reviewer
    }

    /// The cross-reviewer for rotation index `i`: `crossReviewer`, unless it is the family of that
    /// round's reviewer, in which case the first other family in the reviewer rotation (no fallback,
    /// like any cross-reviewer). nil when no other family is available, which makes the round no
    /// cross-check. So a rotating reviewer never cross-checks against itself, and a round the policy
    /// marks still cross-checks.
    public func crossReviewer(rotation i: Int) -> Slot? {
        guard let cross = crossReviewer, let reviewer = reviewer(rotation: i) else { return crossReviewer }
        if cross.choice.agent != reviewer.choice.agent { return cross }
        return reviewerRotation.first { $0.choice.agent != reviewer.choice.agent }.map { Slot($0.choice) }
    }

    /// The integrator for rotation index `i`. Synthesis is index 0 — the first integrator.
    public func integrator(rotation i: Int) -> ModelChoice { Self.entry(integrators, i) ?? integrator }

    /// The polisher for rotation index `i` (polish round k is `k - 1`; fresh eyes and dedup follow
    /// the last polish round). nil when the config seats no polisher.
    public func polisher(rotation i: Int) -> ModelChoice? {
        guard polisher != nil else { return nil }
        return Self.entry(polishers, i) ?? polisher
    }

    /// Each role's agents in rotation order — one entry when it does not rotate, none when unseated.
    /// An unseated reviewer or polisher (Sketch's polisher) has none, whatever a stale list says.
    public var reviewerRotation: [Slot] { reviewer == nil ? [] : Self.nonEmpty(reviewers) ?? reviewer.map { [$0] } ?? [] }
    public var integratorRotation: [ModelChoice] { Self.nonEmpty(integrators) ?? [integrator] }
    public var polisherRotation: [ModelChoice] { polisher == nil ? [] : Self.nonEmpty(polishers) ?? polisher.map { [$0] } ?? [] }

    private static func nonEmpty<T>(_ list: [T]?) -> [T]? { list?.isEmpty == false ? list : nil }

    private static func entry<T>(_ list: [T]?, _ i: Int) -> T? {
        guard let list = nonEmpty(list) else { return nil }
        return list[((i % list.count) + list.count) % list.count]
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
/// `HeadlessCommand.build` arm only refuses until Track G lands.
public struct AvailableModels: Sendable, Equatable {
    public private(set) var choices: [AgentID: ModelChoice]

    public init(choices: [AgentID: ModelChoice]) {
        self.choices = choices.filter { AgentProfiles.headlessReady.contains($0.key) }
    }

    public init(codex: ModelChoice?, claude: ModelChoice?) {
        var choices: [AgentID: ModelChoice] = [:]
        choices[.codex] = codex
        choices[.claude] = claude
        self.init(choices: choices)
    }

    /// Each harness's model ids, as its CLI listed them at detection (`grok models`), for the
    /// editor's model picker. Absent for a harness with no list command (claude, codex), whose
    /// model stays a free text field. Generic over `AgentID` so Track M's gemini list lands here
    /// too rather than in a field of its own.
    public var models: [AgentID: [String]] = [:]

    /// Why a harness this build CAN run is not offered: its CLI is missing ("not installed") or
    /// signed out (its profile's hint, e.g. "Grok: run `grok login`"). The editor shows these,
    /// so a harness is never silently missing from a picker (spec §3.2).
    public var unavailable: [AgentID: String] = [:]

    /// Each agent's models as the editor's menus list them, for the project's default account
    /// (`ModelListStore`, or detection's list command). Empty for an agent no source has read yet;
    /// `menuOptions` then falls back to the profile's aliases.
    public var options: [AgentID: [ModelOption]] = [:]
    /// The same lists for a role's own account or pool, keyed by `AccountChoice.key` — a pool's is
    /// the union of its members'. Different accounts can see different models.
    public var optionsByAccount: [String: [ModelOption]] = [:]

    /// What the model menu for `agent` offers a role billing `account` (nil: the project's
    /// assignment): that account's list when one was read, else the project default's, else — on
    /// a machine nothing has listed yet — the detected ids, else the profile's aliases and
    /// default, named by `ModelNaming`. Never empty for an agent with a catalog.
    public func menuOptions(for agent: AgentID, account: AccountChoice? = nil) -> [ModelOption] {
        if let listed = account.flatMap({ optionsByAccount[$0.key] }), !listed.isEmpty { return listed }
        if let listed = options[agent], !listed.isEmpty { return listed }
        let catalog = AgentProfiles.profile(for: agent).modelCatalog
        let ids = models[agent] ?? (catalog.aliases + [catalog.defaultPlanningModel])
        var seen = Set<String>()
        return ids.filter { !$0.isEmpty && seen.insert($0).inserted }.map { id in
            ModelOption(id: id, name: agent == .claude && catalog.aliases.contains(id)
                        ? ModelNaming.aliasName(id) : ModelNaming.derive(id, agent: agent))
        }
    }

    public func option(agent: AgentID, model: String, account: AccountChoice? = nil) -> ModelOption? {
        menuOptions(for: agent, account: account).first { $0.id == model }
    }

    /// The name a person reads for `model`: the source's own, else derived. Empty is the CLI's own
    /// default (opencode's).
    public func displayName(agent: AgentID, model: String, account: AccountChoice? = nil) -> String {
        if model.isEmpty { return "Default" }
        return option(agent: agent, model: model, account: account)?.name ?? ModelNaming.derive(model, agent: agent)
    }

    /// "Claude > Opus 5.5": the agent, then the model. A model the list does not hold reads as custom.
    public func modelLabel(agent: AgentID, model: String, account: AccountChoice? = nil) -> String {
        let custom = !model.isEmpty && option(agent: agent, model: model, account: account) == nil
        return ModelNaming.label(agent: agent, name: displayName(agent: agent, model: model, account: account)) + (custom ? " (custom)" : "")
    }

    /// The effort levels `model` takes: its own when the source says (an empty list: none), else
    /// the agent profile's. Empty for an agent with no effort setting at all (gemini's ids carry
    /// theirs; opencode has none).
    public func effortValues(agent: AgentID, model: String, account: AccountChoice? = nil) -> [String] {
        let profile = AgentProfiles.profile(for: agent).modelCatalog.effortValues
        guard !profile.isEmpty else { return [] }
        return option(agent: agent, model: model, account: account)?.efforts ?? profile
    }

    /// `choice` moved to `model` (and `agent`): the effort follows the new model — empty when it
    /// takes none, kept when it still fits, else the profile's planning effort (or the nearest the
    /// model has).
    public func selecting(agent: AgentID, model: String, from choice: ModelChoice?) -> ModelChoice {
        let account = agent == choice?.agent ? choice?.account : nil
        let levels = effortValues(agent: agent, model: model, account: account)
        let planning = AgentProfiles.profile(for: agent).modelCatalog.defaultPlanningEffort
        let effort: String
        if levels.isEmpty {
            effort = ""
        } else if let current = choice?.effort, agent == choice?.agent, levels.contains(current) {
            effort = current
        } else {
            effort = levels.contains(planning) ? planning : (levels.contains("high") ? "high" : levels[levels.count / 2])
        }
        return ModelChoice(agent: agent, model: model, effort: effort, account: account)
    }

    public func choice(for agent: AgentID) -> ModelChoice? { choices[agent] }

    /// Every available agent, in `AgentID.planningOrder` order — the order pickers list them in.
    public var agents: [AgentID] { AgentID.planningOrder.filter { choices[$0] != nil } }

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
    ///
    /// Gemini and Grok, when detected, take the seats where another family pays off without
    /// slowing every round (`docs/FOLLOWUPS.md`, "Four-family planning rounds"): Gemini is the
    /// cross-reviewer, Grok only when there is no Gemini, and a Full plan gives its coverage
    /// drafter to Gemini and its stress-test drafter to Grok. Grok never reviews by default —
    /// the reviewer runs every refinement round, and Grok's took 745 s in the four-family live
    /// round against 42-73 s for the drafters. Each of their seats falls back to A or B.
    /// OpenCode is never seated here: the Rounds editor offers it, but no live planning round
    /// has measured it.
    ///
    /// When A and B are different families the three roles that repeat round after round rotate
    /// (`RoundConfig.reviewers`), so no one family runs a whole long stage: the reviewer
    /// alternates A, B (each falling back to the other) and the integrator B, A, so every Refine
    /// round pairs two families and neither runs both agents of one round. The polisher goes B,
    /// then Gemini when detected, then A — so a Full plan's eight polish-stage rounds run
    /// claude, gemini, codex, claude, gemini, codex, claude (fresh eyes), gemini (dedup), and
    /// fresh eyes is never the family that ran the round before it. Grok is slow and OpenCode
    /// unmeasured, so neither is in a rotation. One family on the machine: no rotations.
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
        let gemini = available.choice(for: .gemini)
        let grok = available.choice(for: .grok)
        // Another family to check the reviewer's work: Gemini, else Grok, else B when B is a
        // second family. Never a fallback — a same-family fallback is not a cross-check.
        let crossReviewer = (gemini ?? grok).map { Slot($0) } ?? (hasFallback ? Slot(b) : nil)
        let rotates = a.agent != b.agent
        let reviewers: [Slot]? = rotates ? [Slot(a, fallback: b), Slot(b, fallback: a)] : nil
        let integrators: [ModelChoice]? = rotates ? [b, a] : nil
        let polishers: [ModelChoice]? = rotates ? [b] + (gemini.map { [$0] } ?? []) + [a] : nil

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
                crossReviewer: crossReviewer, crossCheck: crossReviewer == nil ? nil : .off,
                reviewers: reviewers, integrators: integrators)
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
                crossReviewer: crossReviewer, crossCheck: crossReviewer == nil ? nil : .firstAndLast,
                reviewers: reviewers, integrators: integrators, polishers: polishers)
        case .fullPlan:
            return RoundConfig(
                drafters: [
                    Slot(a, persona: .arbiter, fallback: hasFallback ? b : nil),
                    Slot(b, persona: .realist, fallback: hasFallback ? a : nil),
                    gemini.map { Slot($0, persona: .coverage, fallback: a) }
                        ?? Slot(a, persona: .coverage, fallback: hasFallback ? b : nil),
                    grok.map { Slot($0, persona: .stressTest, fallback: b) }
                        ?? Slot(b, persona: .stressTest, fallback: hasFallback ? a : nil),
                ],
                synthesizer: Slot(a, persona: .arbiter, fallback: hasFallback ? b : nil),
                reviewer: Slot(a, fallback: hasFallback ? b : nil),
                integrator: integrator, encoder: encoder, polisher: available.claude ?? a,
                refinementCap: 5, polishCap: 6, freshEyesAndDedup: true,
                defaultPlay: .nextMajor, customized: false,
                crossReviewer: crossReviewer, crossCheck: crossReviewer == nil ? nil : .firstAndLast,
                reviewers: reviewers, integrators: integrators, polishers: polishers)
        }
    }
}
