import FleetKit
import Foundation

/// A role in a round configuration, addressed the way the Mac's editor addresses it
/// (`SlotKeyPath`). `id` is the name the Mac's `WireRoundsLock.locked` uses.
enum RoundRole: Hashable {
    case drafter(Int), synthesizer, reviewer, crossReviewer, integrator, encoder, polisher

    var id: String {
        switch self {
        case .drafter(let i): "drafter\(i)"
        case .synthesizer: "synthesizer"
        case .reviewer: "reviewer"
        case .crossReviewer: "crossReviewer"
        case .integrator: "integrator"
        case .encoder: "encoder"
        case .polisher: "polisher"
        }
    }

    /// The three roles that repeat round after round and can take their agents in turn.
    var rotates: Bool {
        switch self {
        case .reviewer, .integrator, .polisher: true
        default: false
        }
    }

    /// Only a role with a seat of its own carries an availability retry. The cross-check agent
    /// never does: its fallback would be the reviewer's family, and a same-family cross-check is
    /// not independent.
    var supportsFallback: Bool {
        switch self {
        case .drafter, .synthesizer, .reviewer: true
        default: false
        }
    }
}

/// One model choice in a configuration: a role's own agent (at `turn`, for a rotating role), or
/// the one it falls back to.
struct RoundSite: Hashable {
    var role: RoundRole
    var turn = 0
    var fallback = false
}

/// The Rounds editor as decisions, on the phone's side of `WireRoundConfig` (MOBILE-UI: a
/// decision reachable without SwiftUI is one a test can run). Every edit mirrors the Mac's
/// `RoundConfigEditor`, which also decides it again when the command arrives: the menus come
/// from the Mac (`WireRoundsMenu`), and what a shaping tape has run arrives as `lock`, so a
/// stage that already ran is shown locked and the Mac refuses an edit to it anyway.
struct RoundEditor: Equatable {
    var config: WireRoundConfig
    let menu: WireRoundsMenu
    /// nil while a fidelity is being chosen: nothing has run, and nothing is running.
    let lock: WireRoundsLock?

    /// "Pause to change agents." while a round runs.
    var editable: Bool { lock?.editable ?? true }
    func isLocked(_ role: RoundRole) -> Bool { lock?.locked.contains(role.id) == true }

    // MARK: Reading the configuration

    private func agentOption(_ id: String) -> WireAgentOption? { menu.agents.first { $0.agent == id } }

    /// The agents that can be picked now, in the Mac's order.
    private var usable: [WireAgentOption] { menu.agents.filter { $0.reason == nil } }

    func seat(_ role: RoundRole) -> WireSeat? {
        switch role {
        case .drafter(let i): config.drafters.indices.contains(i) ? config.drafters[i] : nil
        case .synthesizer: config.synthesizer
        case .reviewer: config.reviewer
        case .crossReviewer: config.crossReviewer
        case .integrator: config.integrator
        case .encoder: config.encoder
        case .polisher: config.polisher
        }
    }

    /// A rotating role's agents in turn: its list, else the one agent. Empty for a role the
    /// configuration does not seat.
    func rotation(_ role: RoundRole) -> [WireSeat] {
        let list: [WireSeat]? = switch role {
        case .reviewer: config.reviewers
        case .integrator: config.integrators
        case .polisher: config.polishers
        default: nil
        }
        if let list, !list.isEmpty { return list }
        return seat(role).map { [$0] } ?? []
    }

    func choice(at site: RoundSite) -> WireModelChoice? {
        let seat = role(site)
        return site.fallback ? seat?.fallback : seat?.choice
    }

    private func role(_ site: RoundSite) -> WireSeat? {
        site.role.rotates ? rotation(site.role).indices.contains(site.turn) ? rotation(site.role)[site.turn] : nil : seat(site.role)
    }

    // MARK: Editing

    /// Applies `edit` to the seat at `site` (its turn, for a rotating role) and keeps a rotation's
    /// first entry equal to the role's single field, which an older reader sees.
    private mutating func editSeat(_ site: RoundSite, _ edit: (inout WireSeat) -> Void) {
        switch site.role {
        case .drafter(let i):
            guard config.drafters.indices.contains(i) else { return }
            edit(&config.drafters[i])
        case .synthesizer: if config.synthesizer != nil { edit(&config.synthesizer!) }
        case .crossReviewer: if config.crossReviewer != nil { edit(&config.crossReviewer!) }
        case .encoder: edit(&config.encoder)
        case .reviewer, .integrator, .polisher:
            var list = rotation(site.role)
            guard list.indices.contains(site.turn) else { return }
            edit(&list[site.turn])
            writeRotation(site.role, list)
        }
        config.customized = true
    }

    /// A list of one or none is no rotation (nil), and the single field takes entry 0.
    private mutating func writeRotation(_ role: RoundRole, _ list: [WireSeat]) {
        let rotation: [WireSeat]? = list.count > 1 ? list : nil
        switch role {
        case .reviewer: config.reviewers = rotation; if let first = list.first { config.reviewer = first }
        case .integrator: config.integrators = rotation; if let first = list.first { config.integrator = first }
        case .polisher: config.polishers = rotation; if let first = list.first { config.polisher = first }
        default: break
        }
    }

    /// Moves the choice at `site` to `model` on `agent` — `model` any id, a listed one or one
    /// typed in. The effort follows the model, and the role's own account is kept only while the
    /// agent stays the same: an account belongs to one agent.
    mutating func select(_ site: RoundSite, agent: String, model: String) {
        let next = selecting(agent: agent, model: model, from: choice(at: site))
        editSeat(site) { seat in
            if site.fallback { seat.fallback = next } else { seat.choice = next }
        }
    }

    /// Fallback "None".
    mutating func clearFallback(_ site: RoundSite) {
        editSeat(RoundSite(role: site.role, turn: site.turn)) { $0.fallback = nil }
    }

    mutating func setEffort(_ site: RoundSite, _ effort: String) {
        editChoice(site) { $0.effort = effort }
    }

    /// `key` nil is the project's assignment.
    mutating func setAccount(_ site: RoundSite, key: String?) {
        let name = key.flatMap { key in agentOption(choice(at: site)?.agent ?? "")?.accounts?.options.first { $0.key == key }?.title }
        editChoice(site) { $0.accountKey = key; $0.account = name }
    }

    private mutating func editChoice(_ site: RoundSite, _ edit: (inout WireModelChoice) -> Void) {
        editSeat(site) { seat in
            if site.fallback {
                guard var fallback = seat.fallback else { return }
                edit(&fallback)
                seat.fallback = fallback
            } else {
                edit(&seat.choice)
            }
        }
    }

    /// The `choice` moved to `model` on `agent`, as the Mac's `AvailableModels.selecting` makes it.
    func selecting(agent: String, model: String, from choice: WireModelChoice?) -> WireModelChoice {
        let option = agentOption(agent)
        let same = choice?.agent == agent
        let accountKey = same ? choice?.accountKey : nil
        let levels = effortLevels(agent: agent, model: model, accountKey: accountKey)
        let planning = option?.planningEffort ?? ""
        let effort: String
        if levels.isEmpty {
            effort = ""
        } else if same, let current = choice?.effort, levels.contains(current) {
            effort = current
        } else {
            effort = levels.contains(planning) ? planning : (levels.contains("high") ? "high" : levels[levels.count / 2])
        }
        return WireModelChoice(agent: agent, agentName: option?.name, model: model, effort: effort,
                               modelName: models(agent: agent, accountKey: accountKey).first { $0.id == model }?.name ?? model,
                               account: same ? choice?.account : nil, accountKey: accountKey)
    }

    // MARK: Models and effort

    /// The agent's models for a role billing `accountKey` (nil: the project's assignment): that
    /// account's list when it differs, else the project default's.
    func models(agent: String, accountKey: String?) -> [WireModelOption] {
        guard let option = agentOption(agent) else { return [] }
        return accountKey.flatMap { option.accountModels?[$0] } ?? option.models
    }

    /// What the model takes: its own levels, else the agent's for a model typed in. Empty hides
    /// the control.
    func effortLevels(agent: String, model: String, accountKey: String?) -> [String] {
        models(agent: agent, accountKey: accountKey).first { $0.id == model }?.efforts ?? agentOption(agent)?.efforts ?? []
    }

    /// The levels the effort picker shows for `choice`: its model's, with a stored level the
    /// model no longer lists kept in so the picker never reads blank.
    func effortLevels(for choice: WireModelChoice) -> [String] {
        let levels = effortLevels(agent: choice.agent, model: choice.model, accountKey: choice.accountKey)
        guard !levels.isEmpty else { return [] }
        return levels.contains(choice.effort) || choice.effort.isEmpty ? levels : levels + [choice.effort]
    }

    /// "Claude > Opus 5.5", as the Mac's menu reads closed. A model the list does not hold reads
    /// "(custom)"; an empty one is the CLI's own default.
    func modelLabel(_ choice: WireModelChoice) -> String {
        let agent = agentOption(choice.agent)?.name ?? choice.agentName ?? choice.agent.capitalized
        let listed = models(agent: choice.agent, accountKey: choice.accountKey).first { $0.id == choice.model }
        var name = choice.model.isEmpty ? "Default" : (listed?.name ?? choice.modelName ?? choice.model)
        if name.hasPrefix(agent + " ") { name.removeFirst(agent.count + 1) }
        let custom = !choice.model.isEmpty && listed == nil
        return "\(agent) > \(name)" + (custom ? " (custom)" : "")
    }

    // MARK: The model menu

    /// One agent's submenu: its models, the current one checked, and why it cannot be picked when
    /// it cannot.
    struct AgentItem: Equatable, Identifiable {
        var id: String { agent }
        let agent: String
        let name: String
        let reason: String?
        let models: [ModelItem]
        /// The current model when this agent's list does not hold it, so it is not lost.
        let custom: ModelItem?
    }

    struct ModelItem: Equatable, Identifiable {
        var id: String { model }
        let model: String
        let name: String
        let checked: Bool
    }

    /// Every agent the menu lists: those usable, those installed but not (disabled, with their
    /// reason), and the choice's own agent when detection no longer offers it, so a re-check
    /// never blanks a role.
    func modelMenu(for site: RoundSite) -> [AgentItem] {
        let current = choice(at: site)
        var agents = menu.agents.map { option -> AgentItem in
            let mine = current?.agent == option.agent ? current : nil
            let list = models(agent: option.agent, accountKey: mine?.accountKey)
            let items = list.map { ModelItem(model: $0.id, name: $0.name, checked: mine?.model == $0.id) }
            let unlisted = mine.flatMap { m in !m.model.isEmpty && !list.contains { $0.id == m.model } ? m : nil }
            return AgentItem(agent: option.agent, name: option.name, reason: option.reason, models: items,
                             custom: unlisted.map { ModelItem(model: $0.model, name: $0.modelName ?? $0.model, checked: true) })
        }
        if let current, !agents.contains(where: { $0.agent == current.agent }) {
            agents.append(AgentItem(agent: current.agent, name: current.agentName ?? current.agent.capitalized,
                                    reason: "\(current.agentName ?? current.agent.capitalized) (unavailable)", models: [], custom: nil))
        }
        return agents
    }

    // MARK: Accounts

    struct AccountPicker: Equatable {
        struct Item: Equatable, Identifiable {
            var id: String { key ?? "" }
            let key: String?
            let title: String
        }
        /// The project's assignment first, then accounts, then pools.
        let items: [Item]
        let pools: [Item]
        /// The role's own account, when the menu no longer holds it: "Missing account".
        let missing: Item?
        let selection: String?
    }

    /// The Account picker for `site`: shown when the agent has more than one account or pool to
    /// choose from, or when the role already holds its own (so it can be put back). Otherwise
    /// the project's assignment is the only account and there is nothing to pick.
    func accountPicker(for site: RoundSite) -> AccountPicker? {
        guard let choice = choice(at: site), let menu = agentOption(choice.agent)?.accounts,
              menu.offersChoice || choice.accountKey != nil else { return nil }
        let own = choice.accountKey
        let missing = own.flatMap { key in menu.options.contains { $0.key == key } ? nil : key }
            .map { AccountPicker.Item(key: $0, title: $0.hasPrefix("pool:") ? "Missing pool" : "Missing account") }
        return AccountPicker(
            items: [AccountPicker.Item(key: nil, title: menu.defaultTitle)]
                + menu.options.filter { !$0.isPool }.map { AccountPicker.Item(key: $0.key, title: $0.title) },
            pools: menu.options.filter(\.isPool).map { AccountPicker.Item(key: $0.key, title: $0.title) },
            missing: missing, selection: own)
    }

    // MARK: Rotations

    func canAddToRotation(_ role: RoundRole) -> Bool { !rotation(role).isEmpty && usable.count > 1 }

    /// Appends the next usable agent after the last entry's, so a first press makes the pair and
    /// later ones walk the installed families. A role with one agent becomes a rotation of that
    /// agent and the new one.
    mutating func addToRotation(_ role: RoundRole) {
        var list = rotation(role)
        guard let last = list.last, canAddToRotation(role) else { return }
        let agents = usable
        let at = agents.firstIndex { $0.agent == last.choice.agent }
        let next = (at.map { agents[($0 + 1) % agents.count] } ?? agents.first)?.defaultChoice
        guard let next, next.agent != last.choice.agent else { return }
        list.append(WireSeat(choice: next, persona: role == .reviewer ? "general" : nil))
        writeRotation(role, list)
        config.customized = true
    }

    mutating func removeFromRotation(_ role: RoundRole, at index: Int) {
        var list = rotation(role)
        guard list.indices.contains(index), list.count > 1 else { return }
        list.remove(at: index)
        writeRotation(role, list)
        config.customized = true
    }

    mutating func moveInRotation(_ role: RoundRole, from: Int, to: Int) {
        var list = rotation(role)
        guard list.indices.contains(from), list.indices.contains(to), from != to else { return }
        list.insert(list.remove(at: from), at: to)
        writeRotation(role, list)
        config.customized = true
    }

    /// Back to the role's first agent alone.
    mutating func collapseRotation(_ role: RoundRole) {
        let list = rotation(role)
        guard list.count > 1 else { return }
        writeRotation(role, Array(list.prefix(1)))
        config.customized = true
    }

    // MARK: Cross-check

    var crossCheck: String { config.crossCheck ?? "off" }

    /// Sets the policy and, the moment it goes live with nothing seeded yet, seats the cross-check
    /// agent from the first other family: an unseeded row would show a picker it cannot resolve,
    /// and a same-family default would file the round straight into the "same family" note.
    mutating func setCrossCheck(_ policy: String) {
        config.crossCheck = policy
        if policy != "off", config.crossReviewer == nil, let reviewer = config.reviewer,
           let seed = otherAgent(than: reviewer.choice.agent)?.defaultChoice {
            config.crossReviewer = WireSeat(choice: seed, persona: "general")
        }
        config.customized = true
    }

    private func otherAgent(than agent: String) -> WireAgentOption? { usable.first { $0.agent != agent } }

    /// The cross-check agent is the reviewer's own family, so rounds won't cross-check.
    var crossCheckSameFamily: Bool {
        guard config.reviewer != nil, let cross = config.crossReviewer else { return false }
        return rotation(.reviewer).allSatisfy { $0.choice.agent == cross.choice.agent }
    }

    /// The policy is on but no other family could be seated.
    var crossCheckUnavailable: Bool {
        guard crossCheck != "off", config.crossReviewer == nil, let reviewer = config.reviewer else { return false }
        return otherAgent(than: reviewer.choice.agent) == nil
    }

    // MARK: Rounds, fresh eyes, default play

    /// Rounds a stage will run: while shaping, its cap plus the tape's extend/trim counter, so the
    /// number agrees with the board; the cap saved is the one that gives it.
    var refineRounds: Int { config.refinementCap + (lock?.extraRefinement ?? 0) }
    var polishRounds: Int { config.polishCap + (lock?.extraPolish ?? 0) }

    mutating func setRefineRounds(_ total: Int) {
        config.refinementCap = max(total, lock?.refinementFloor ?? 0) - (lock?.extraRefinement ?? 0)
        config.customized = true
    }

    mutating func setPolishRounds(_ total: Int) {
        config.polishCap = max(total, lock?.polishFloor ?? 0) - (lock?.extraPolish ?? 0)
        config.customized = true
    }

    var refineRange: ClosedRange<Int> { (lock?.refinementFloor ?? 0)...max(12, refineRounds) }
    var polishRange: ClosedRange<Int> { (lock?.polishFloor ?? 0)...max(12, polishRounds) }
    var refineLocked: Bool { lock?.refineDone == true }
    var polishLocked: Bool { lock?.polishDone == true }
    var freshEyesLocked: Bool { lock?.freshEyesDone == true }

    /// Off with no polisher, since that is what will run whatever the stored flag says.
    var freshEyes: Bool { config.freshEyesAndDedup && config.polisher != nil }

    mutating func setFreshEyes(_ on: Bool) { config.freshEyesAndDedup = on; config.customized = true }
    mutating func setDefaultPlay(_ mode: String) { config.defaultPlay = mode; config.customized = true }

    // MARK: Layout

    /// One choice as the editor draws it: a menu, an effort where the model has levels, an account
    /// where there is a choice of them.
    struct Entry: Equatable, Identifiable {
        var id: RoundSite { site }
        let site: RoundSite
        /// "Model", "Turn 2" or "Fallback".
        let label: String
        let choice: WireModelChoice?
        /// "Claude > Opus 5.5", or "None" for a fallback with none.
        let modelLabel: String
        let efforts: [String]
        let account: AccountPicker?
    }

    struct RoleRows: Equatable, Identifiable {
        var id: RoundRole { role }
        let role: RoundRole
        let title: String
        /// The drafter's angle; nil for `general`, which says nothing.
        let persona: String?
        /// Every stage the role works in has run: shown disabled, "already ran".
        let ran: Bool
        let turns: [Turn]
        let canAdd: Bool
    }

    /// One turn of a role: its agent, and the one it falls back to.
    struct Turn: Equatable, Identifiable {
        var id: Int { entry.site.turn }
        let entry: Entry
        let fallback: Entry?
        /// Position in the rotation, and its length: the move and remove buttons need two or more.
        let count: Int
    }

    struct StageRows: Equatable, Identifiable {
        let id: String
        let title: String
        let roles: [RoleRows]
    }

    static let alreadyRan = "already ran"
    static let alternates = "alternates each round"
    static let synthesisIntegratorNote = "The integrator, set under Refine, merges the synthesis."

    /// Stages in run order, each with the roles it edits. The integrator sits under Refine, the
    /// stage it runs every round of; the cross-check agent shows only while the policy is on.
    var stages: [StageRows] {
        var stages: [StageRows] = []
        let drafters = config.drafters.indices.map { rows(.drafter($0), title: "Drafter") }
        if !drafters.isEmpty { stages.append(StageRows(id: "draft", title: "Draft", roles: drafters)) }
        if config.synthesizer != nil {
            stages.append(StageRows(id: "synthesis", title: "Synthesis", roles: [rows(.synthesizer, title: "Synthesizer")]))
        }
        var refine: [RoleRows] = []
        if config.reviewer != nil {
            refine.append(rows(.reviewer, title: "Reviewer"))
            if crossCheck != "off", config.crossReviewer != nil { refine.append(rows(.crossReviewer, title: "Cross-check agent")) }
        }
        refine.append(rows(.integrator, title: "Integrator"))
        stages.append(StageRows(id: "refine", title: "Refine", roles: refine))
        stages.append(StageRows(id: "encode", title: "Encode", roles: [rows(.encoder, title: "Encoder")]))
        if config.polisher != nil { stages.append(StageRows(id: "polish", title: "Polish", roles: [rows(.polisher, title: "Polisher")])) }
        return stages
    }

    private func rows(_ role: RoundRole, title: String) -> RoleRows {
        let count = role.rotates ? max(rotation(role).count, 1) : 1
        let turns = (0..<count).map { turn -> Turn in
            let site = RoundSite(role: role, turn: turn)
            let label = count > 1 ? "Turn \(turn + 1)" : "Model"
            let fallbackSite = RoundSite(role: role, turn: turn, fallback: true)
            return Turn(entry: entry(site, label: label),
                        fallback: role.supportsFallback ? entry(fallbackSite, label: "Fallback") : nil, count: count)
        }
        let persona = seat(role)?.persona.flatMap { $0 == "general" ? nil : $0 }
        return RoleRows(role: role, title: title, persona: persona, ran: isLocked(role), turns: turns,
                        canAdd: role.rotates && canAddToRotation(role))
    }

    private func entry(_ site: RoundSite, label: String) -> Entry {
        let choice = choice(at: site)
        return Entry(site: site, label: label, choice: choice, modelLabel: choice.map(modelLabel) ?? "None",
                     efforts: choice.map(effortLevels(for:)) ?? [], account: accountPicker(for: site))
    }
}

/// What the phone edited and what it edited from, held while the editor is open and sent
/// together: the Mac refuses an edit whose `base` is no longer its config
/// (`rounds_changed`), so an edit is never applied over a plan the phone did not see.
struct RoundDraft: Equatable {
    var base: WireRoundConfig
    var config: WireRoundConfig
}
