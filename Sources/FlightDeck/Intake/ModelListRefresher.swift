import Foundation
import IntakeKit
import OSLog

/// The accounts whose model lists are read, per agent: every live account of claude and codex
/// (different accounts can see different models), each pool as the union of its members, and one
/// "default" per agent for the built-in home when no account record names it.
struct ModelListTargets: Sendable {
    struct Account: Sendable {
        var agent: AgentID
        /// nil: the agent's built-in home with no account record.
        var choice: AccountChoice?
        /// The CLI's config home for this account: where its own cache lives.
        var home: URL
        /// False for the built-in home, which the CLI is run in without binding its home variable
        /// (claude reads its login from a Keychain entry that binding `~/.claude` explicitly changes).
        var bound: Bool
    }
    struct Pool: Sendable {
        var choice: AccountChoice
        var agent: AgentID
        var members: [AccountChoice]
    }
    var accounts: [Account] = []
    var pools: [Pool] = []

    /// The key a list is held under in `AvailableModels.optionsByAccount`.
    static func key(_ agent: AgentID, _ choice: AccountChoice?) -> String { choice?.key ?? "default:\(agent.rawValue)" }
}

extension ModelListTargets {
    /// Every live claude and codex account, each pool of theirs, and the built-in home of each.
    @MainActor
    init(_ preferences: PreferencesStore) {
        for agent in [AgentID.claude, .codex] {
            let live = preferences.preferences.accounts(for: agent)
            accounts += live.map { Account(agent: agent, choice: .account($0.id), home: $0.home, bound: !$0.isBuiltIn) }
            accounts.append(Account(agent: agent, choice: nil, home: agent.builtInHome, bound: false))
        }
        pools = preferences.effectivePools.filter { ($0.agent == .claude || $0.agent == .codex) && $0.kind == .hosted }
            .map { Pool(choice: .pool($0.id), agent: $0.agent, members: $0.accounts.map { .account($0) }) }
    }
}

/// Reads each agent's model list from its CLI and keeps the last good copy in `ModelListStore`.
///
/// - claude: the account's own model catalog (`<config dir>/cache/model-catalog`, written by the
///   CLI) and `claude -p "/model"`, which the CLI answers locally for free — it names the aliases
///   and what each resolves to. A run whose JSON is not marked `"local_command":"model"` with a
///   cost of 0 is discarded (`ClaudeModelCommand.parse`).
/// - codex: the account's `models_cache.json`, which codex refreshes itself.
/// - grok, gemini, opencode: their list commands, run by detection (`IntakeService.available`);
///   `record` stores what it listed and falls back to the stored list when it listed nothing.
///
/// A source that yields nothing (offline, not signed in, no cache yet) leaves the stored list
/// alone and logs why; the menu is never emptied by a failed refresh.
struct ModelListRefresher: Sendable {
    var store: ModelListStore
    /// Runs `claude -p "/model" [--model x]` for an account; nil on any failure.
    var runClaude: @Sendable (_ account: ModelListTargets.Account, _ model: String?) -> Data? = ClaudeModelProcess.run
    var readCache: @Sendable (AgentID, URL) -> [ModelOption]? = ModelListSources.cliCache
    var log: @Sendable (String) -> Void = { Logger(subsystem: "co.summerfriday.flightdeck", category: "model-lists").info("\($0, privacy: .public)") }
    var now: @Sendable () -> Date = Date.init

    /// What is stored, without touching a CLI — the editor's first paint.
    func cached(_ targets: ModelListTargets) -> [String: [ModelOption]] {
        var lists: [String: [ModelOption]] = [:]
        for account in targets.accounts {
            if let list = store.load(agent: account.agent, key: Self.storeKey(account.choice)) {
                lists[ModelListTargets.key(account.agent, account.choice)] = list.options
                ModelNaming.register(list.options, agent: account.agent)
            }
        }
        return withPools(lists, targets)
    }

    /// Reads every account's list now (blocking: call it off the main actor) and returns all lists.
    func refresh(_ targets: ModelListTargets) -> [String: [ModelOption]] {
        var lists = cached(targets)
        for account in targets.accounts where account.agent == .claude || account.agent == .codex {
            let key = ModelListTargets.key(account.agent, account.choice)
            let catalog = readCache(account.agent, account.home)
            let options: [ModelOption]
            if account.agent == .claude {
                options = ClaudeModelCommand.build(catalog: catalog) { runClaude(account, $0) }
            } else {
                options = catalog ?? []
            }
            if options.isEmpty {
                log("model list for \(account.agent.rawValue) \(key): nothing readable, keeping \(lists[key]?.count ?? 0) cached")
                continue
            }
            lists[key] = store.save(options, agent: account.agent, key: Self.storeKey(account.choice), now: now())?.options ?? options
            ModelNaming.register(options, agent: account.agent)
        }
        return withPools(lists, targets)
    }

    /// Stores what detection listed for grok, gemini and opencode, and where it listed nothing puts
    /// the stored list in its place — so one failed `agy models` does not empty the menu.
    func record(_ detected: inout AvailableModels) {
        for agent in [AgentID.grok, .gemini, .opencode] {
            let key = ModelListTargets.key(agent, nil)
            if let listed = detected.options[agent], !listed.isEmpty {
                ModelNaming.register(listed, agent: agent)
                store.save(listed, agent: agent, key: Self.storeKey(nil), now: now())
            } else if let kept = store.load(agent: agent, key: Self.storeKey(nil)) {
                detected.options[agent] = kept.options
                ModelNaming.register(kept.options, agent: agent)
                log("model list for \(agent.rawValue) \(key): detection listed nothing, using the list cached \(kept.fetchedAt)")
            }
        }
    }

    /// A pool lists the union of its members' models, first member's order first.
    private func withPools(_ lists: [String: [ModelOption]], _ targets: ModelListTargets) -> [String: [ModelOption]] {
        var out = lists
        for pool in targets.pools {
            var seen = Set<String>()
            let union = pool.members.flatMap { lists[$0.key] ?? [] }.filter { seen.insert($0.id).inserted }
            if !union.isEmpty { out[pool.choice.key] = union }
        }
        return out
    }

    static func storeKey(_ choice: AccountChoice?) -> String {
        choice.map { $0.key } ?? ModelListStore.defaultKey
    }
}

/// `claude -p "/model"`, run the way a planning seat's claude is (account home bound, child-session
/// variables scrubbed) from a temporary directory, with no session written.
enum ClaudeModelProcess {
    static func run(_ account: ModelListTargets.Account, _ model: String?) -> Data? {
        let base = LoginShellPath.repairing()
        return run(account, model, path: base["PATH"], base: base)
    }

    /// `path` finds the executable and `base` is the environment the child starts from — seams for a test with a stand-in `claude`.
    static func run(_ account: ModelListTargets.Account, _ model: String?, path: String?, base: [String: String]) -> Data? {
        guard let executable = TriageSettings.executable("claude", path: path) else { return nil }
        let fm = FileManager.default
        let cwd = fm.temporaryDirectory.appendingPathComponent("fd-model-\(UUID().uuidString)", isDirectory: true)
        guard (try? fm.createDirectory(at: cwd, withIntermediateDirectories: true)) != nil else { return nil }
        defer {
            try? fm.removeItem(at: cwd)
            removeProjectDirectory(for: cwd, in: account)
        }
        let outURL = cwd.appendingPathComponent("stdout")
        guard fm.createFile(atPath: outURL.path, contents: nil), let out = try? FileHandle(forWritingTo: outURL) else { return nil }
        defer { try? out.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-p", ClaudeModelCommand.prompt, "--output-format", "json", "--no-session-persistence"]
            + (model.map { ["--model", $0] } ?? [])
        process.currentDirectoryURL = cwd
        process.environment = ClaudeProfile().environment(
            base: base,
            account: account.bound ? AgentAccountRef(id: account.choice?.key ?? account.home.path, home: account.home) : nil)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        guard exited.wait(timeout: .now() + 20) == .success else {
            process.terminate()
            return nil
        }
        return try? Data(contentsOf: outURL)
    }

    /// claude files even a sessionless run's cwd under `<config>/projects/<cwd, non-alphanumerics as
    /// "-">` (an empty `memory` folder); a temporary directory is never a project, so it goes.
    private static func removeProjectDirectory(for cwd: URL, in account: ModelListTargets.Account) {
        let name = String(cwd.resolvingSymlinksInPath().path.map { $0.isLetter || $0.isNumber ? $0 : "-" })
        let directory = account.home.appendingPathComponent("projects/\(name)", isDirectory: true)
        let contents = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        if contents.allSatisfy({ $0 == "memory" }) { try? FileManager.default.removeItem(at: directory) }
    }
}
