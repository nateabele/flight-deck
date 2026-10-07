import Foundation

// `.flightdeck/delegate.toml` (spec §8), as parsed. The parser, validation and route matching
// are track C4's; these are the values every other track reads.

public struct DelegateConfig: Sendable, Equatable {
    public var defaultHost: String?
    /// Declared ignored files sent with every run.
    public var include: [String]
    public var recipes: [String: Recipe]
    /// In file order: the first match wins.
    public var routes: [Route]
    /// `[infra.<name>]`: cloud machines this project can bring up.
    public var infra: [String: InfraConfig]

    public init(defaultHost: String? = nil, include: [String] = [], recipes: [String: Recipe] = [:],
                routes: [Route] = [], infra: [String: InfraConfig] = [:]) {
        self.defaultHost = defaultHost
        self.include = include
        self.recipes = recipes
        self.routes = routes
        self.infra = infra
    }
}

/// `[recipe.<name>]`. Every field but `run` may be left out, and takes the default here.
public struct Recipe: Codable, Sendable, Equatable {
    public var host: String?
    public var run: String
    public var down: String?
    public var screen = false
    /// Print the run id and return at once; the agent then `wait`s (§6.1).
    public var long = false
    public var service = false
    public var restartOnSync = false
    public var fetch: [String] = []
    /// `L:R` notation, as `PortMapping.parse` reads it. Strings, because the TOML allows
    /// `5432` and `"8080:80"` side by side.
    public var ports: [String] = []
    public var env: [String: String] = [:]
    public var apply: ApplyMode = .review
    /// Checkout slots for this recipe's worktree; nil means the default of 2.
    public var pool: Int?
    /// `orphan_timeout`: seconds a service outlives a lost controller before the host stops it
    /// (`RunSpec.orphanTimeout`); nil means the host's default. A database that takes minutes
    /// to warm up is worth keeping through a laptop's longer sleep, and a throwaway one is not.
    public var orphanTimeout: Int?

    public init(host: String? = nil, run: String, down: String? = nil, screen: Bool = false,
                long: Bool = false, service: Bool = false, restartOnSync: Bool = false,
                fetch: [String] = [], ports: [String] = [], env: [String: String] = [:],
                apply: ApplyMode = .review, pool: Int? = nil, orphanTimeout: Int? = nil) {
        self.host = host
        self.run = run
        self.down = down
        self.screen = screen
        self.long = long
        self.service = service
        self.restartOnSync = restartOnSync
        self.fetch = fetch
        self.ports = ports
        self.env = env
        self.apply = apply
        self.pool = pool
        self.orphanTimeout = orphanTimeout
    }

    enum CodingKeys: String, CodingKey {
        case host = "host"
        case run = "run"
        case down = "down"
        case screen = "screen"
        case long = "long"
        case service = "service"
        case restartOnSync = "restartOnSync"
        case fetch = "fetch"
        case ports = "ports"
        case env = "env"
        case apply = "apply"
        case pool = "pool"
        case orphanTimeout = "orphanTimeout"
    }

    /// Lenient, like the file it mirrors: an absent field is its default. A strict decode
    /// would make every field added later a break for the peer that predates it.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            host: try c.decodeIfPresent(String.self, forKey: .host),
            run: try c.decode(String.self, forKey: .run),
            down: try c.decodeIfPresent(String.self, forKey: .down),
            screen: try c.decodeIfPresent(Bool.self, forKey: .screen) ?? false,
            long: try c.decodeIfPresent(Bool.self, forKey: .long) ?? false,
            service: try c.decodeIfPresent(Bool.self, forKey: .service) ?? false,
            restartOnSync: try c.decodeIfPresent(Bool.self, forKey: .restartOnSync) ?? false,
            fetch: try c.decodeIfPresent([String].self, forKey: .fetch) ?? [],
            ports: try c.decodeIfPresent([String].self, forKey: .ports) ?? [],
            env: try c.decodeIfPresent([String: String].self, forKey: .env) ?? [:],
            apply: try c.decodeIfPresent(ApplyMode.self, forKey: .apply) ?? .review,
            pool: try c.decodeIfPresent(Int.self, forKey: .pool),
            orphanTimeout: try c.decodeIfPresent(Int.self, forKey: .orphanTimeout))
    }
}

/// How a run's changed-file patch comes back (§4.5).
public enum ApplyMode: String, Codable, Sendable {
    /// Held for `flightdeck diff` / `apply`.
    case review = "review"
    /// Applied on completion, falling back to review on a conflict.
    case auto = "auto"
}

/// `[[route]]`: `match` is a glob over the joined argv; `recipe` names a `[recipe.<name>]`.
public struct Route: Sendable, Equatable {
    public let match: String
    public let recipe: String

    public init(match: String, recipe: String) {
        self.match = match
        self.recipe = recipe
    }
}
