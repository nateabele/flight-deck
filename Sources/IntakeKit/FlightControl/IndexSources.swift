import Foundation

/// The unit a benchmark reports in. A source reads exactly one.
///
/// Direction lives on the unit, not on the source entry, so a price can never be ranked as if
/// more were better: a hand-added source that reads dollars inherits "lower wins" from its unit
/// instead of from a flag someone has to remember to set.
public enum IndexUnit: String, Codable, Sendable, CaseIterable {
    case percent
    case score
    case elo
    case tokensPerSecond = "tokens-per-second"
    case seconds
    case usdPerMillionTokens = "usd-per-million-tokens"
    case contextTokens = "context-tokens"

    /// False where a smaller figure is the better model (latency, price).
    public var higherIsBetter: Bool {
        switch self {
        case .seconds, .usdPerMillionTokens: false
        case .percent, .score, .elo, .tokensPerSecond, .contextTokens: true
        }
    }
}

/// One public benchmark the capability index reads, as the user edits it in Settings.
///
/// One entry reads ONE metric in ONE unit. A page that publishes two metrics (a speed and price
/// tracker) is two entries with the same `url`: percentiles only mean something among rows that
/// measure the same thing, and ranking tokens-per-second against dollars in one table would make
/// the fastest model look the most expensive.
///
/// `unit` is stored as a string, not an `IndexUnit`, so a config edited by hand with an unknown
/// unit still loads and is reported by `IndexSourceRegistry.problems` rather than failing to
/// decode and taking every other source down with it.
public struct IndexSource: Codable, Equatable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var url: String
    /// Dimension id → how strongly this source speaks to it, in 0...1.
    public var dimensions: [String: Double]
    /// Which table or metric the extractor reads, handed to it verbatim.
    public var howToRead: String
    /// An `IndexUnit` raw value. Every row from this source must carry it.
    public var unit: String
    /// Whether `url` serves data (JSON, YAML) rather than a rendered page, as last probed.
    public var machineReadable: Bool
    public var enabled: Bool

    public init(id: String, name: String, url: String, dimensions: [String: Double], howToRead: String,
                unit: IndexUnit, machineReadable: Bool, enabled: Bool = true) {
        self.id = id; self.name = name; self.url = url; self.dimensions = dimensions
        self.howToRead = howToRead; self.unit = unit.rawValue
        self.machineReadable = machineReadable; self.enabled = enabled
    }

    public var indexUnit: IndexUnit? { IndexUnit(rawValue: unit) }
}

public enum IndexSourceRegistry {
    /// The initial set. URLs and `machineReadable` were probed live on 2026-10-04 (plan Task 1).
    /// SWT-bench is beyond the spec's list: without it nothing feeds `test-authoring`, and the
    /// seed kind `tests` weighs that dimension 0.9.
    public static let initial: [IndexSource] = [
        IndexSource(id: "swe-bench-verified", name: "SWE-bench Verified",
                    url: "https://raw.githubusercontent.com/SWE-bench/swe-bench.github.io/master/data/leaderboards.json",
                    dimensions: ["agentic-coding": 1.0, "debugging": 0.6],
                    howToRead: "A JSON file. Use the leaderboard whose \"name\" is \"Verified\". Each result is one submission: report the model it ran (from its name, tags or folder) and its resolved percentage. Report every submission; Flight Deck keeps each model's best.",
                    unit: .percent, machineReadable: true),
        IndexSource(id: "swe-bench-pro", name: "SWE-bench Pro",
                    url: "https://scale.com/leaderboard/swe_bench_pro_public",
                    dimensions: ["agentic-coding": 1.0, "large-context-refactor": 0.6],
                    howToRead: "The public leaderboard table: each model's resolve rate in percent.",
                    unit: .percent, machineReadable: false),
        IndexSource(id: "terminal-bench", name: "Terminal-Bench",
                    url: "https://www.tbench.ai/leaderboard",
                    dimensions: ["tool-use-reliability": 1.0, "agentic-coding": 0.5],
                    howToRead: "The leaderboard table: each entry's accuracy in percent. Name the model the entry ran, with its setting in brackets when the table gives one.",
                    unit: .percent, machineReadable: false),
        IndexSource(id: "aider-polyglot", name: "Aider Polyglot",
                    url: "https://raw.githubusercontent.com/Aider-AI/aider/main/aider/website/_data/polyglot_leaderboard.yml",
                    dimensions: ["agentic-coding": 0.5, "algorithmic-reasoning": 0.5],
                    howToRead: "A YAML list. Each entry's `model` is the model name and `pass_rate_2` its score in percent.",
                    unit: .percent, machineReadable: true),
        IndexSource(id: "livecodebench", name: "LiveCodeBench",
                    url: "https://livecodebench.github.io/leaderboard.html",
                    dimensions: ["algorithmic-reasoning": 1.0],
                    howToRead: "The main leaderboard's overall Pass@1 column for the most recent time window.",
                    unit: .percent, machineReadable: false),
        IndexSource(id: "swt-bench", name: "SWT-bench",
                    url: "https://swtbench.com/",
                    dimensions: ["test-authoring": 1.0],
                    howToRead: "The leaderboard's success rate for generating tests that reproduce an issue, in percent.",
                    unit: .percent, machineReadable: false),
        IndexSource(id: "webdev-arena", name: "WebDev Arena",
                    url: "https://lmarena.ai/leaderboard/webdev",
                    dimensions: ["frontend-ui": 1.0],
                    howToRead: "The arena score (an Elo rating) column.",
                    unit: .elo, machineReadable: false),
        IndexSource(id: "aa-speed", name: "Artificial Analysis: speed",
                    url: "https://artificialanalysis.ai/leaderboards/models",
                    dimensions: ["speed": 1.0],
                    howToRead: "Each model's median output speed in tokens per second.",
                    unit: .tokensPerSecond, machineReadable: false),
        IndexSource(id: "aa-price", name: "Artificial Analysis: price",
                    url: "https://artificialanalysis.ai/leaderboards/models",
                    dimensions: ["cost-efficiency": 1.0],
                    howToRead: "Each model's blended price in US dollars per million tokens.",
                    unit: .usdPerMillionTokens, machineReadable: false),
        IndexSource(id: "anthropic-models", name: "Anthropic model overview",
                    url: "https://docs.anthropic.com/en/docs/about-claude/models/overview",
                    dimensions: ["large-context-refactor": 0.4],
                    howToRead: "Each model's context window, in tokens.",
                    unit: .contextTokens, machineReadable: false),
        IndexSource(id: "openai-models", name: "OpenAI model list",
                    url: "https://platform.openai.com/docs/models",
                    dimensions: ["large-context-refactor": 0.4],
                    howToRead: "Each model's context window, in tokens.",
                    unit: .contextTokens, machineReadable: false),
    ]

    /// Everything that would make a source silently contribute nothing, one line each, in source
    /// order. Shown in Settings; never auto-repaired, since the user owns this list.
    public static func problems(_ sources: [IndexSource]) -> [String] {
        var out: [String] = []
        var seen: Set<String> = []
        for s in sources {
            if !seen.insert(s.id).inserted { out.append("\(s.id): duplicate id") }
            if s.indexUnit == nil { out.append("\(s.id): unknown unit \(s.unit)") }
            if !(s.url.hasPrefix("https://") || s.url.hasPrefix("http://")) { out.append("\(s.id): url is not a web address") }
            if s.howToRead.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append("\(s.id): no reading instructions") }
            for (d, w) in s.dimensions.sorted(by: { $0.key < $1.key }) {
                if !Dimensions.isKnown(d) { out.append("\(s.id): unknown dimension \(d)") }
                else if !(0...1).contains(w) { out.append("\(s.id): weight \(w) for \(d) is outside 0...1") }
            }
            if !s.dimensions.contains(where: { Dimensions.isKnown($0.key) && $0.value > 0 && $0.value <= 1 }) {
                out.append("\(s.id): feeds no dimension")
            }
        }
        return out
    }
}
