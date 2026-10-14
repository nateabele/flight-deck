import Foundation

// The models an agent offers, with the names people read and the effort levels each takes.
//
// Nothing here is a hand-kept list of model ids. Each agent's list comes from the CLI itself:
//   - claude: the model catalog the CLI keeps in `<config dir>/cache/model-catalog/*-cc.json`
//     (fetched from Anthropic by the CLI, per account, with `display_name`s and each model's
//     effort options);
//   - codex: `<CODEX_HOME>/models_cache.json`, codex's own copy of its `model/list`;
//   - grok, gemini, opencode: the list command in their profile (`grok models`, `agy models`,
//     `opencode models --verbose`), which `IntakeService` already runs for detection.
// What those give is cached by `ModelListStore` so a failed refresh never empties a menu, and the
// derivation below names an id no source has a name for.

/// One model a role can run: the id a command line takes, the name a person reads, and the effort
/// levels it accepts.
public struct ModelOption: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// nil: the source does not say (grok's list), so the agent profile's levels stand. An empty
    /// list is an answer: the model takes no effort setting at all (claude's Haiku 4.5).
    public var efforts: [String]?
    public init(id: String, name: String, efforts: [String]? = nil) {
        self.id = id; self.name = name; self.efforts = efforts
    }
}

/// A fetched list and when it was read, as `ModelListStore` keeps it.
public struct ModelList: Codable, Equatable, Sendable {
    public var fetchedAt: Date
    public var options: [ModelOption]
    public init(fetchedAt: Date, options: [ModelOption]) { self.fetchedAt = fetchedAt; self.options = options }
}

/// A per-role account override: an account, or a pool leased through the `CapacityLedger`. nil on
/// a `ModelChoice` means the project's assignment (unify brief R9). Stored as one string,
/// `account:<uuid>` or `pool:<id>`, so a config stays readable and an unknown future kind is
/// dropped rather than failing the whole config.
public enum AccountChoice: Hashable, Codable, Sendable {
    case account(UUID)
    case pool(PoolID)

    /// The stored form, also the key `RunnerAccounts.overrides` and the model lists use.
    public var key: String {
        switch self {
        case .account(let id): "account:\(id.uuidString)"
        case .pool(let id): "pool:\(id.rawValue)"
        }
    }

    public init?(key: String) {
        if key.hasPrefix("account:"), let id = UUID(uuidString: String(key.dropFirst(8))) {
            self = .account(id)
        } else if key.hasPrefix("pool:"), key.count > 5 {
            self = .pool(PoolID(String(key.dropFirst(5))))
        } else {
            return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let choice = AccountChoice(key: raw) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unknown account choice \(raw)"))
        }
        self = choice
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(key)
    }
}

// MARK: - Names

public enum ModelNaming {
    /// Words an id spells in lowercase that are written in capitals.
    private static let acronyms: Set<String> = ["gpt", "oss", "glm", "llm", "ai"]
    /// A trailing word that is an effort level, shown in parentheses as agy does.
    private static let efforts: Set<String> = ["minimal", "low", "medium", "high", "xhigh", "max"]

    /// A readable name for an id no source named: `gpt-6-sol` is "GPT 6 Sol",
    /// `claude-opus-5-5` "Opus 5.5" (the agent's own name leads the menu, so claude's prefix is
    /// dropped), `gemini-3.8-flash-high` "Gemini 3.8 Flash (High)". A provider prefix
    /// (`ollama/qwen3`) and a date suffix are dropped. Never empty for a non-empty id.
    public static func derive(_ id: String, agent: AgentID? = nil) -> String {
        var s = id.trimmingCharacters(in: .whitespaces)
        var suffix = ""
        if s.hasSuffix("[1m]") { s.removeLast(4); suffix = " (1M context)" }
        if let slash = s.lastIndex(of: "/"), s.index(after: slash) != s.endIndex { s = String(s[s.index(after: slash)...]) }
        if agent == .claude, s.hasPrefix("claude-"), s.count > 7 { s.removeFirst(7) }
        var tokens = s.split(separator: "-").map(String.init)
        if tokens.count > 1, let last = tokens.last, last.count == 8, Int(last) != nil { tokens.removeLast() }
        var effort: String?
        if tokens.count > 2, let last = tokens.last, efforts.contains(last.lowercased()) { effort = tokens.removeLast() }
        var words: [String] = []
        for token in tokens {
            if let previous = words.last, isSmallNumber(previous), isSmallNumber(token) {
                words[words.count - 1] = "\(previous).\(token)"
            } else {
                words.append(word(token))
            }
        }
        var name = words.joined(separator: " ")
        if let effort { name += " (\(word(effort)))" }
        return (name.isEmpty ? id : name) + suffix
    }

    /// "Opus (latest)": what claude's family aliases (`opus`, `sonnet`, `haiku`, `fable`) are shown as.
    public static func aliasName(_ alias: String) -> String {
        "\(word(alias)) (latest)"
    }

    // The names the app has read from the CLIs, for the places that print a choice without an
    // `AvailableModels` to hand (a live card, a round chip). Filled by `register` whenever the
    // lists load; until then — and for an id no list holds — the derivation answers.
    private static let registry = NSLock()
    nonisolated(unsafe) private static var known: [String: String] = [:]

    public static func register(_ options: [ModelOption], agent: AgentID) {
        registry.lock(); defer { registry.unlock() }
        for option in options { known["\(agent.rawValue)|\(option.id)"] = option.name }
    }

    public static func resetRegistry() {
        registry.lock(); defer { registry.unlock() }
        known = [:]
    }

    /// The name for `model` on `agent`: the CLI's own when a list has been read, else derived.
    public static func name(agent: AgentID, model: String) -> String {
        registry.lock(); defer { registry.unlock() }
        return known["\(agent.rawValue)|\(model)"] ?? derive(model, agent: agent)
    }

    private static func isSmallNumber(_ s: String) -> Bool { !s.isEmpty && s.count <= 2 && s.allSatisfy(\.isNumber) }

    private static func word(_ token: String) -> String {
        if acronyms.contains(token.lowercased()) { return token.uppercased() }
        // `120b` -> `120B`
        if token.count > 1, token.dropLast().allSatisfy(\.isNumber), token.last?.isLetter == true { return token.uppercased() }
        guard let first = token.first else { return token }
        return first.uppercased() + token.dropFirst()
    }
}

// MARK: - Reading the CLIs' own lists

public enum ModelListSources {
    /// `ultra` enables delegation and is not a Pro tier (`ClaudeProfile.catalog`): never offered.
    private static func plan(_ efforts: [String]) -> [String] { efforts.filter { $0 != "ultra" } }

    /// The newest `*-cc.json` in claude's `<configDir>/cache/model-catalog`, parsed. The CLI writes
    /// one per account that used the directory, and refreshes it hourly while it runs; the `cc`
    /// surface is the models Claude Code itself can run, which is what filters out everything a
    /// planning run could not use. nil when the CLI has not written one yet.
    public static func claudeCache(configDirectory: URL) -> [ModelOption]? {
        let directory = configDirectory.appendingPathComponent("cache/model-catalog", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        let parsed = files.filter { $0.lastPathComponent.hasSuffix("-cc.json") }
            .compactMap { url -> (Date, [ModelOption])? in
                guard let data = try? Data(contentsOf: url), let list = claudeCatalog(data) else { return nil }
                return list
            }
        return parsed.max { $0.0 < $1.0 }?.1
    }

    /// One catalog file: `catalog.config.models[]` with `id`, `name` and `thinking.effort_options`.
    /// A model whose `thinking` has no effort type (Haiku 4.5, `mode`) takes no effort.
    public static func claudeCatalog(_ data: Data) -> (Date, [ModelOption])? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let catalog = root["catalog"] as? [String: Any], catalog["surface"] as? String == "cc",
              let config = catalog["config"] as? [String: Any], let models = config["models"] as? [[String: Any]]
        else { return nil }
        let fetched = (root["fetchedAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) } ?? .distantPast
        let options = models.compactMap { m -> ModelOption? in
            guard let id = m["id"] as? String, !id.isEmpty else { return nil }
            let name = (m["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? ModelNaming.derive(id, agent: .claude)
            let thinking = m["thinking"] as? [String: Any]
            let efforts: [String]?
            if let thinking {
                let type = thinking["type"] as? String ?? ""
                let ids = (thinking["effort_options"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
                efforts = type.contains("effort") ? plan(ids) : []
            } else {
                efforts = nil
            }
            return ModelOption(id: id, name: name, efforts: efforts)
        }
        return options.isEmpty ? nil : (fetched, options)
    }

    /// `<CODEX_HOME>/models_cache.json`, codex's own copy of `model/list`: `models[]` with `slug`,
    /// `display_name`, `visibility` (`list` is what codex shows; `hide` is internal) and
    /// `supported_reasoning_levels[].effort`. The default model leads when the file names none.
    public static func codexCache(home: URL) -> [ModelOption]? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent("models_cache.json")) else { return nil }
        return codexCache(data)
    }

    public static func codexCache(_ data: Data) -> [ModelOption]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = root["models"] as? [[String: Any]] else { return nil }
        let options = models.compactMap { m -> ModelOption? in
            guard let id = m["slug"] as? String, !id.isEmpty, m["visibility"] as? String == "list" else { return nil }
            // codex spells its names with hyphens ("GPT-6-Sol"); they are read as "GPT 6 Sol".
            let name = (m["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0.replacingOccurrences(of: "-", with: " ") }
                ?? ModelNaming.derive(id)
            let levels = (m["supported_reasoning_levels"] as? [[String: Any]])?.compactMap { $0["effort"] as? String }
            return ModelOption(id: id, name: name, efforts: levels.map(plan))
        }
        return options.isEmpty ? nil : options
    }

    /// `agy models`: `<id>\t<display name>` per line, Gemini ids only (`GeminiProfile.isGeminiModel`),
    /// the planning default first.
    public static func agyList(_ stdout: String) -> [ModelOption] {
        var options = stdout.split(whereSeparator: \.isNewline).compactMap { line -> ModelOption? in
            let parts = line.split(separator: "\t", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard let id = parts.first, GeminiProfile.isGeminiModel(id), !id.contains(" ") else { return nil }
            return ModelOption(id: id, name: parts.count > 1 && !parts[1].isEmpty ? parts[1] : ModelNaming.derive(id))
        }
        if let i = options.firstIndex(where: { $0.id == GeminiProfile.defaultPlanningModel }) { options.insert(options.remove(at: i), at: 0) }
        return options
    }

    /// `opencode models --verbose`: each `provider/model` line is followed by that model's JSON
    /// object, whose `name` is its display name. A plain `opencode models` listing (no objects)
    /// yields derived names.
    public static func opencodeList(_ stdout: String) -> [ModelOption] {
        var options: [ModelOption] = []
        var pending: String?
        var json = ""
        var depth = 0
        func finish() {
            guard let id = pending else { return }
            let name = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
                .flatMap { $0["name"] as? String }.flatMap { $0.isEmpty ? nil : $0 }
            options.append(ModelOption(id: id, name: name ?? ModelNaming.derive(id)))
            pending = nil; json = ""; depth = 0
        }
        for raw in stdout.split(whereSeparator: \.isNewline) {
            let line = String(raw)
            if depth == 0 {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("{") {
                    json = line; depth = line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
                    if depth == 0 { finish() }
                } else if OpenCodeProfile().parseModelList(trimmed) == [trimmed] {
                    finish()
                    pending = trimmed
                }
            } else {
                json += "\n" + line
                depth += line.filter { $0 == "{" }.count - line.filter { $0 == "}" }.count
                if depth == 0 { finish() }
            }
        }
        finish()
        return options
    }

    /// Any other list command: ids from the profile's own parser, each named by derivation.
    public static func derived(_ ids: [String], agent: AgentID) -> [ModelOption] {
        ids.map { ModelOption(id: $0, name: ModelNaming.derive($0, agent: agent)) }
    }

    /// The options for `agent` from the stdout of its list command.
    public static func options(agent: AgentID, listStdout: String, profile: any AgentProfile) -> [ModelOption] {
        switch agent {
        case .gemini: agyList(listStdout)
        case .opencode: opencodeList(listStdout)
        default: derived(profile.parseModelList(listStdout), agent: agent)
        }
    }

    /// Reads the CLI-maintained list for claude or codex from the account's home. nil for the
    /// other agents (their list is a command) and when the CLI has not written one.
    public static func cliCache(agent: AgentID, home: URL) -> [ModelOption]? {
        switch agent {
        case .claude: claudeCache(configDirectory: home)
        case .codex: codexCache(home: home)
        default: nil
        }
    }
}

// MARK: - claude's local `/model` command

/// `claude -p "/model" --output-format json` is answered by the CLI itself, with no API call: the
/// result names the current model and lists the aliases it takes, and `--model <x>` makes it name
/// what `<x>` is. ONLY exactly `/model` is local — `/models` goes to the model as a prompt and
/// bills — so `parse` refuses any output that is not marked `"local_command":"model"` with a
/// cost of 0, and a refused output is discarded.
public enum ClaudeModelCommand {
    public struct Output: Equatable, Sendable {
        /// The friendly name the CLI gave the model (backticked in its text), without "(default)".
        public var name: String?
        /// The aliases from "Available:".
        public var aliases: [String]
    }

    /// The prompt to send, always exactly this.
    public static let prompt = "/model"

    /// Aliases that name a model family, which is all the menu offers (not `best`, `default`,
    /// `opusplan`, or a `[1m]` context variant).
    static let hidden: Set<String> = ["best", "default", "opusplan"]

    public static func parse(_ data: Data) -> Output? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["local_command"] as? String == "model", (json["total_cost_usd"] as? Double) == 0,
              json["is_error"] as? Bool != true, let text = json["result"] as? String else { return nil }
        var name: String?
        if let open = text.firstIndex(of: "`"), let close = text[text.index(after: open)...].firstIndex(of: "`") {
            name = String(text[text.index(after: open)..<close]).replacingOccurrences(of: " (default)", with: "")
        }
        var aliases: [String] = []
        if let range = text.range(of: "Available:") {
            aliases = text[range.upperBound...].split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && !$0.contains(" ") && !$0.contains("[") && !hidden.contains($0) }
        }
        return Output(name: name, aliases: aliases)
    }

    /// Recent pinned versions the CLI cannot enumerate, tried one by one through `--model` when no
    /// catalog file exists: a candidate is kept only if the CLI renames it (an unknown id echoes
    /// back). Small on purpose — families at the versions that have shipped.
    static let candidateFamilies = ["opus", "sonnet", "haiku", "fable"]
    static let candidateVersions = ["5-5", "5-1", "5", "4-8", "4-7", "4-6", "4-5"]

    /// The claude menu: `catalog` (the CLI's per-account model catalog, with efforts) or, without
    /// one, candidates the CLI recognizes; then the family aliases, each named for what it
    /// resolves to ("Opus 5.5 (latest)") and taking that model's efforts. `run` executes the
    /// command with `--model` set to its argument (nil: none) in the account's config dir.
    public static func build(catalog: [ModelOption]?, run: (_ model: String?) -> Data?) -> [ModelOption] {
        var pinned = catalog ?? []
        guard let base = run(nil).flatMap(parse) else { return pinned }
        if pinned.isEmpty {
            for family in candidateFamilies {
                for version in candidateVersions {
                    let id = "claude-\(family)-\(version)"
                    if let name = run(id).flatMap(parse)?.name, name != id, !pinned.contains(where: { $0.id == id }) {
                        pinned.append(ModelOption(id: id, name: name))
                    }
                }
            }
        }
        let aliases = base.aliases.compactMap { alias -> ModelOption? in
            guard let resolved = run(alias).flatMap(parse)?.name, resolved != alias else { return nil }
            return ModelOption(id: alias, name: "\(resolved) (latest)", efforts: pinned.first { $0.name == resolved }?.efforts)
        }
        return pinned + aliases
    }
}

// MARK: - The cache

/// Flight Deck's own copy of every list it has read, one JSON file per agent and account under
/// `directory` (Application Support in the app): `claude-<account uuid>.json`, or
/// `claude-default.json` for an agent with no account record. A refresh that finds nothing
/// leaves the file alone, so the last good list outlives an offline or half-written source.
public struct ModelListStore: Sendable {
    public var directory: URL
    public init(directory: URL) { self.directory = directory }

    public static let defaultKey = "default"

    public func url(agent: AgentID, key: String) -> URL {
        let safe = key.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }
        return directory.appendingPathComponent("\(agent.rawValue)-\(String(safe)).json")
    }

    public func load(agent: AgentID, key: String) -> ModelList? {
        guard let data = try? Data(contentsOf: url(agent: agent, key: key)) else { return nil }
        return try? IntakeJSON.decoder.decode(ModelList.self, from: data)
    }

    /// Stores `options` as the list for the key, and returns what is now cached: `options`, or —
    /// when they are empty — the last good list, untouched.
    @discardableResult
    public func save(_ options: [ModelOption], agent: AgentID, key: String, now: Date = Date()) -> ModelList? {
        guard !options.isEmpty else { return load(agent: agent, key: key) }
        let list = ModelList(fetchedAt: now, options: options)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if let data = try? IntakeJSON.encoder.encode(list) { try? data.write(to: url(agent: agent, key: key), options: .atomic) }
        return list
    }
}

public extension ModelChoice {
    /// "Claude > Opus 5.5": the agent, then the model, as a person reads them. Raw ids stay in
    /// storage, on the wire and on command lines.
    var displayLabel: String {
        model.isEmpty ? agent.displayName : "\(agent.displayName) > \(ModelNaming.name(agent: agent, model: model))"
    }
}
