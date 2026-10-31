import Foundation

/// One problem in a `provider.toml`. Its own type rather than `DelegateConfigIssue`, whose
/// description names `delegate.toml`; the shape is the same so a CLI can print both alike.
public struct ProviderManifestIssue: Error, Sendable, Equatable, CustomStringConvertible {
    public let severity: DelegateConfigIssue.Severity
    /// 1-based; nil when the problem is about the folder or the file as a whole.
    public let line: Int?
    public let message: String
    /// True for a `contract` above what this build reads. Settings shows that as "needs a newer
    /// Flight Deck" instead of as a broken provider, which it is not.
    public let needsNewerFlightDeck: Bool

    public init(_ severity: DelegateConfigIssue.Severity, line: Int? = nil, needsNewerFlightDeck: Bool = false,
                _ message: String) {
        self.severity = severity
        self.line = line
        self.message = message
        self.needsNewerFlightDeck = needsNewerFlightDeck
    }

    public var description: String {
        "provider.toml\(line.map { ":\($0)" } ?? ""): \(severity.rawValue): \(message)"
    }
}

/// A provider's manifest (spec §9), contract 1. Paths are relative to the provider folder and
/// already checked to stay inside it.
public struct ProviderManifest: Sendable, Equatable {
    public var id: String
    public var name: String
    public var version: String
    public var contract: Int
    public var kinds: [ProviderKind]
    /// Nil for a data-only provider, which the repo trust gate lets through unasked.
    public var generator: ProviderGenerator?

    public init(id: String, name: String, version: String, contract: Int,
                kinds: [ProviderKind], generator: ProviderGenerator? = nil) {
        self.id = id
        self.name = name
        self.version = version
        self.contract = contract
        self.kinds = kinds
        self.generator = generator
    }
}

public struct ProviderKind: Sendable, Equatable {
    public enum Output: String, Sendable, CaseIterable { case html, svg, png, mermaid, canvas }
    public enum Pins: String, Sendable, CaseIterable { case nodes, canvas, dom, xy }

    public struct Cost: Sendable, Equatable {
        public var seconds: Int?
        public var tokens: Int?
        public init(seconds: Int? = nil, tokens: Int? = nil) {
            self.seconds = seconds
            self.tokens = tokens
        }
    }

    public var id: String
    public var summary: String
    public var output: Output
    public var entry: String
    public var pins: Pins?
    public var states: [String]
    public var sizes: [String]
    public var cost: Cost?
    public var instructions: String
    public var assets: [String]

    public init(id: String, summary: String, output: Output, entry: String, pins: Pins? = nil,
                states: [String] = [], sizes: [String] = ["default"], cost: Cost? = nil,
                instructions: String, assets: [String] = []) {
        self.id = id
        self.summary = summary
        self.output = output
        self.entry = entry
        self.pins = pins
        self.states = states
        self.sizes = sizes
        self.cost = cost
        self.instructions = instructions
        self.assets = assets
    }
}

public struct ProviderGenerator: Sendable, Equatable {
    /// `command[0]` is a path inside the provider folder when it is relative and has a slash,
    /// and otherwise a program looked up on PATH (`python3`).
    public var command: [String]
    public var timeout: Duration
    public var network: Bool
    /// True when `command[0]` was written as a path inside the provider folder (`./bin/render`).
    /// The parser normalizes that to `bin/render`, which alone reads like a PATH lookup, so the
    /// runner needs this to refuse a missing provider file instead of finding a host program.
    public var providerRelative: Bool

    /// The longest timeout a manifest may ask for. A generator is a step inside one turn, and a
    /// bound here also keeps a runner's nanosecond arithmetic far from overflow.
    public static let maxTimeout = Duration(seconds: 600)

    public init(command: [String], timeout: Duration, network: Bool = false, providerRelative: Bool = false) {
        self.command = command
        self.timeout = timeout
        self.network = network
        self.providerRelative = providerRelative
    }
}

public struct ProviderManifestParseResult: Sendable, Equatable {
    public let manifest: ProviderManifest
    /// Unknown keys, in line order. Warnings so a manifest written for a later revision of
    /// contract 1 still loads, minus the field this build cannot see.
    public let issues: [ProviderManifestIssue]
}
