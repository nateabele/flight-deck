import Foundation
import IntakeKit

/// Where a routing rule lives (spec L3-R §2): the global list in preferences, or one project's
/// `.flightdeck/routing.json`, which is checked first.
enum RuleScope: Hashable {
    case global
    case project(String)
}

/// L3-R's moving parts for the app: both rule lists and the draft → compiled → confirmed path,
/// the kind registry, and a router built from what is confirmed right now.
///
/// `@MainActor` because global rules live in `PreferencesStore`. The router it hands out is a
/// value snapshot, so routing itself never waits on the main actor.
@MainActor
final class RoutingService: ObservableObject {
    /// Bumped on every write. Rules live in two stores (preferences and a repo file), and a view
    /// observing only this service must still redraw when either changes.
    @Published private(set) var revision = 0
    @Published private(set) var compiling: Set<String> = []
    /// Rule id → why the compiler could not run. Spec §8: the rule stays a draft, and says why.
    @Published private(set) var notes: [String: String] = [:]
    /// The last kind change's re-route summary, shown under the Task kinds list.
    @Published var kindNote: String?

    let preferences: PreferencesStore
    let kindStore: KindRegistryStore
    let projectStore: ProjectRoutingStore
    /// A closure, not a compiler: the compiler settings can change between compiles.
    let makeCompiler: @MainActor () -> any RuleCompiling
    let loadCatalogs: @MainActor () async -> AdapterCatalogs
    let pools: any PoolDirectory
    let index: any CapabilityIndex
    let hints: any RuleHintSource
    let tasks: any OpenTaskReading
    let writer: any BlockWriting
    /// Projects the panes offer with no session open: the UI-test fixture's. nil in a real launch.
    let fixtureProjects: [String]?
    private let makeRuleID: () -> String
    let now: () -> Date
    /// What the last catalog load saw — hints are drawn from it, because a view cannot await.
    private(set) var lastCatalogs = AdapterCatalogs([])

    init(preferences: PreferencesStore, kindStore: KindRegistryStore,
         projectStore: ProjectRoutingStore = ProjectRoutingStore(),
         makeCompiler: @escaping @MainActor () -> any RuleCompiling,
         loadCatalogs: @escaping @MainActor () async -> AdapterCatalogs,
         pools: any PoolDirectory, index: any CapabilityIndex = NullCapabilityIndex(),
         hints: any RuleHintSource = NoRuleHints(), tasks: any OpenTaskReading, writer: any BlockWriting,
         fixtureProjects: [String]? = nil, makeRuleID: @escaping () -> String = RoutingService.randomRuleID,
         now: @escaping () -> Date = Date.init) {
        self.preferences = preferences; self.kindStore = kindStore; self.projectStore = projectStore
        self.makeCompiler = makeCompiler; self.loadCatalogs = loadCatalogs; self.pools = pools
        self.index = index; self.hints = hints; self.tasks = tasks; self.writer = writer
        self.fixtureProjects = fixtureProjects; self.makeRuleID = makeRuleID; self.now = now
    }

    nonisolated static func randomRuleID() -> String { "r-" + UUID().uuidString.prefix(8).lowercased() }

    func url(_ path: String) -> URL { URL(fileURLWithPath: path, isDirectory: true) }

    func bump() { revision += 1 }

    // MARK: - Rules

    func rules(_ scope: RuleScope) -> [RoutingRule] {
        switch scope {
        case .global: return preferences.globalRoutingRules
        case .project(let path): return projectStore.load(project: url(path)).rules
        }
    }

    /// Why the project's `routing.json` cannot be read, or nil. Shown above its list (spec §8).
    func projectRulesError(_ path: String) -> String? {
        if case .invalid(let why) = projectStore.load(project: url(path)) { return why }
        return nil
    }

    @discardableResult
    func addRule(_ sentence: String, to scope: RuleScope) -> String? {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let rule = RoutingRule(id: makeRuleID(), sentence: trimmed)
        return mutate(scope) { $0.append(rule) } ? rule.id : nil
    }

    func editSentence(_ id: String, _ sentence: String, in scope: RuleScope) {
        let trimmed = sentence.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        mutate(scope) { rules in
            if let i = rules.firstIndex(where: { $0.id == id }) { rules[i].edit(sentence: trimmed) }
        }
        notes[id] = nil
    }

    func deleteRule(_ id: String, in scope: RuleScope) {
        mutate(scope) { $0.removeAll { $0.id == id } }
        notes[id] = nil
    }

    /// First match wins (spec §2), so order is routing behavior, not presentation.
    func moveRule(_ id: String, by offset: Int, in scope: RuleScope) {
        mutate(scope) { rules in
            guard let i = rules.firstIndex(where: { $0.id == id }), rules.indices.contains(i + offset) else { return }
            rules.swapAt(i, i + offset)
        }
    }

    func confirm(_ id: String, in scope: RuleScope) {
        mutate(scope) { rules in
            if let i = rules.firstIndex(where: { $0.id == id }) { rules[i].confirm() }
        }
    }

    func compile(_ id: String, in scope: RuleScope) async {
        guard !compiling.contains(id), let rule = rules(scope).first(where: { $0.id == id }) else { return }
        compiling.insert(id)
        defer { compiling.remove(id) }
        let input = await compilerInput(sentence: rule.sentence, scope: scope)
        let compiler = makeCompiler()
        let proposal = await compiler.propose(input)
        let outcome = RuleCompilation.finish(proposal, input: input)
        mutate(scope) { rules in
            // An edit made while the compiler ran wins: its words are not the ones compiled.
            guard let i = rules.firstIndex(where: { $0.id == id }), rules[i].sentence == rule.sentence else { return }
            rules[i].record(outcome, by: compiler.ref, at: now())
        }
        if case .unavailable(let why) = outcome { notes[id] = "Compiler unavailable: \(why)" } else { notes[id] = nil }
    }

    func compilerInput(sentence: String, scope: RuleScope) async -> RuleCompilerInput {
        let catalogs = await self.catalogs()
        return RuleCompilerInput(sentence: sentence, kinds: kinds(for: scope), catalogs: catalogs,
                                 pools: pools.pools(), defaultPools: defaultPools(catalogs))
    }

    /// Global rules compile against the seed kinds (deviation 6): the registry is per project.
    func kinds(for scope: RuleScope) -> [TaskKind] {
        switch scope {
        case .global: return SeedKinds.all(createdAt: now())
        case .project(let path): return (try? kindStore.kinds(project: url(path))) ?? SeedKinds.all(createdAt: now())
        }
    }

    func catalogs() async -> AdapterCatalogs {
        let loaded = await loadCatalogs()
        lastCatalogs = loaded
        return loaded
    }

    func defaultPools(_ catalogs: AdapterCatalogs) -> [HarnessID: PoolID] {
        pools.defaultPools(for: catalogs.order)
    }

    /// The one write path for both lists. A project whose `routing.json` is invalid is refused:
    /// that file is the user's to fix, and saving Settings' view over it would destroy it.
    @discardableResult
    private func mutate(_ scope: RuleScope, _ body: (inout [RoutingRule]) -> Void) -> Bool {
        switch scope {
        case .global:
            var rules = preferences.globalRoutingRules
            body(&rules)
            preferences.globalRoutingRules = rules
        case .project(let path):
            let load = projectStore.load(project: url(path))
            if case .invalid = load { return false }
            var rules = load.rules
            body(&rules)
            do { try projectStore.save(rules, project: url(path)) } catch { return false }
        }
        bump()
        return true
    }

    // MARK: - Routing

    /// A snapshot of what routes right now, through the contract's `Router`: what release,
    /// re-route and (at integration) the swarm's launch and spill call. Project rules are read
    /// from the repo file at routing time; the global list and default agents are copied here.
    func makeRouter() -> RuleRouter {
        let fallback = preferences.preferences.agents.first?.id.harnessID
        var byProject: [String: HarnessID] = [:]
        for (path, settings) in preferences.preferences.projectSettings {
            if let agent = settings.defaultAgent { byProject[path] = agent.harnessID }
        }
        let defaults = byProject
        return RuleRouter(rules: ProjectFileRuleSource(global: preferences.globalRoutingRules, store: projectStore),
                          kinds: kindStore, index: index, pools: pools,
                          defaultHarness: { project in defaults[project.standardizedFileURL.path] ?? fallback })
    }

    // MARK: - Hints (spec §7)

    /// Only confirmed rules carry a hint. A dismissed hint stays dismissed until the index
    /// snapshot it came from changes. Hints never change routing.
    func hint(for rule: RoutingRule, scope: RuleScope) -> RuleHint? {
        guard rule.state == .confirmed,
              let hint = hints.hint(for: rule, kinds: kinds(for: scope), catalogs: lastCatalogs) else { return nil }
        return preferences.isHintDismissed(ruleID: rule.id, snapshot: hint.snapshotDate) ? nil : hint
    }

    func dismissHint(_ hint: RuleHint) {
        preferences.dismissHint(ruleID: hint.ruleID, snapshot: hint.snapshotDate)
        bump()
    }
}
