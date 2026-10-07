import Foundation

// The shared per-CLI agent profile (grok/gemini planning spec §3.0). Today four kinds of
// knowledge about each CLI — its model catalog, its error spellings, the child-session scrub
// and its account binding — are copied between the tab side (`AgentAdapter`) and the headless
// side (`Harness`), and two copies have already drifted. A profile is the one place each of
// those answers lives, so a new CLI (grok, gemini) is a profile plus a harness, not a fifth copy.
//
// This file is the CONTRACT that three parallel tracks build against: P (claude + codex),
// G (grok) and M (gemini). Its shape is meant to stay fixed while they run; each track fills
// in its own conformer and deletes that conformer's `unimplemented` marker.

// MARK: - Value types

/// What a classified CLI error means for the caller. Deliberately coarser than
/// `Diagnosis.Category`: timeouts and invalid output are judged from the run itself (exit code,
/// parse result), never from the CLI's error text, so a profile has no business returning them.
public enum AgentFailureKind: String, Codable, Sendable, Equatable, CaseIterable {
    case rateLimited, authExpired, overloaded, other
}

/// One piece of error evidence, tagged with where it came from. A classifier sees the source
/// because the same words mean different things in different places — "401" in stderr is an
/// auth failure, "401" in the model's own prose is content (see `FailureDiagnosis`'s doc).
/// Only the CLI's own channels are ever wrapped here, never the agent's text.
public enum AgentErrorSignal: Sendable, Equatable {
    /// The child's stderr, whole.
    case stderr(String)
    /// One structured error event from the CLI's JSON/JSONL stdout, as the raw JSON text of that
    /// one event (e.g. codex `--json`'s `turn.failed` line, or a claude `result` with `is_error`).
    case streamErrorEvent(json: String)
    /// The API-error kind a CLI wrote into its session transcript (claude's `isApiErrorMessage`
    /// records; the fleet's `SessionAPIError` kinds are derived from these).
    case transcriptAPIError(kind: String)
    /// An error a CLI's app-server protocol returned (codex `app-server`), with its numeric code
    /// when the protocol carries one.
    case appServerError(code: Int?, message: String)
}

/// What "is this CLI usable" resolves to, in the order a caller has to check it: a binary that
/// is not on the login shell's PATH is `notInstalled`, whatever its sign-in state would be.
public enum AgentReadiness: Sendable, Equatable {
    case notInstalled
    /// Installed but not signed in. `hint` is the one-line fix the editor shows next to the
    /// unavailable harness (e.g. "Grok: run `grok login`") — a harness is never silently dropped.
    case signedOut(hint: String)
    case ready
}

/// The captured result of running a `SignInCheck`'s command — what its predicate judges.
public struct SignInCheckOutput: Sendable, Equatable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32
    public init(stdout: String, stderr: String, exitCode: Int32) {
        self.stdout = stdout; self.stderr = stderr; self.exitCode = exitCode
    }
}

/// A cheap, READ-ONLY command that tells signed-in from signed-out, plus a pure predicate over
/// its output. Pure so detection is testable from captured output without spawning anything; the
/// caller (IntakeService's detection) runs `arguments` under `binaryName` and feeds the result in.
/// The command must never sign in, sign out, or spend tokens.
public struct SignInCheck: Sendable {
    /// argv AFTER the binary (the binary is the profile's `binaryName`), e.g. `["models"]`.
    /// Empty means "no check": `readiness` then reports `signedOut(hint:)` rather than guessing
    /// `ready`, so an unfinished profile can never be offered.
    public var arguments: [String]
    /// The hint `readiness` attaches when the predicate says signed out.
    public var signedOutHint: String
    public var isSignedIn: @Sendable (SignInCheckOutput) -> Bool

    public init(arguments: [String], signedOutHint: String, isSignedIn: @escaping @Sendable (SignInCheckOutput) -> Bool) {
        self.arguments = arguments; self.signedOutHint = signedOutHint; self.isSignedIn = isSignedIn
    }

    /// Readiness from the check's captured output, for an installed binary.
    public func readiness(_ output: SignInCheckOutput) -> AgentReadiness {
        guard !arguments.isEmpty, isSignedIn(output) else { return .signedOut(hint: signedOutHint) }
        return .ready
    }
}

/// The models a CLI offers for planning, and the knobs a seat may set. `aliases` are the static
/// names a CLI accepts without asking it (claude's `opus`/`fable`); `listArguments` is the
/// read-only command that lists the rest at runtime (`grok models`), parsed by the profile's
/// `parseModelList`. Either may be empty.
public struct ProfileModelCatalog: Sendable, Equatable {
    public var aliases: [String]
    /// argv after `binaryName` that prints the model list, or nil when the CLI has none.
    public var listArguments: [String]?
    /// The model and effort a fresh planning seat on this harness starts at.
    public var defaultPlanningModel: String
    public var defaultPlanningEffort: String
    /// The effort knob's accepted values. Empty means the CLI has no effort knob at all
    /// (gemini, per spec §2), so the editor hides the control instead of offering a no-op.
    public var effortValues: [String]

    public init(aliases: [String], listArguments: [String]?, defaultPlanningModel: String,
                defaultPlanningEffort: String, effortValues: [String]) {
        self.aliases = aliases; self.listArguments = listArguments
        self.defaultPlanningModel = defaultPlanningModel; self.defaultPlanningEffort = defaultPlanningEffort
        self.effortValues = effortValues
    }

    /// What a stub profile returns: no models, no default. Detectable (`isEmpty`), so nothing
    /// can seat a harness off a catalog that was never filled in.
    public static let empty = ProfileModelCatalog(aliases: [], listArguments: nil, defaultPlanningModel: "",
                                                  defaultPlanningEffort: "", effortValues: [])

    public var isEmpty: Bool { aliases.isEmpty && listArguments == nil && defaultPlanningModel.isEmpty }
}

/// Which account a run bills: an opaque id plus the CLI's config home for that account (the
/// directory a profile binds via `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, or grok's/gemini's
/// equivalent). Pure — no Keychain, no file reads — so it rides on `HarnessRequest`.
public struct AgentAccountRef: Codable, Hashable, Sendable {
    public var id: String
    public var home: URL
    public init(id: String, home: URL) { self.id = id; self.home = home }
}

// MARK: - The protocol

/// Everything Flight Deck knows about one agent CLI that is not specific to tabs or to headless
/// planning. Pure and Sendable: no process spawning, no file reads — a caller runs the commands
/// it describes and hands the output back in.
public protocol AgentProfile: Sendable {
    /// The headless harness this profile describes. Its raw value (`claude`, `codex`, `grok`,
    /// `gemini`) is the CLI's id everywhere — including L3's `HarnessID`.
    var id: Harness { get }
    var family: ModelFamily { get }
    /// The executable looked up on the login shell's PATH.
    var binaryName: String { get }
    var signInCheck: SignInCheck { get }
    var modelCatalog: ProfileModelCatalog { get }
    /// Model ids from the stdout of `modelCatalog.listArguments`. Empty when there is no list.
    func parseModelList(_ stdout: String) -> [String]
    /// Whether the CLI constrains its own output to a JSON Schema (claude/grok `--json-schema`,
    /// codex `--output-schema`). A harness without it gets the schema in the prompt and ONE
    /// repair retry (spec §3.4, `SchemaRepair`).
    var hasNativeSchema: Bool { get }
    /// The failure a piece of CLI error evidence means, or nil when it means nothing this
    /// profile recognizes (the caller then falls back to its own generic handling).
    func classify(error: AgentErrorSignal) -> AgentFailureKind?
    /// The child's complete environment from the caller's resolved `base`: binds `account`'s
    /// home (nil = the built-in account, i.e. `base` as is), re-applies whatever an isolation
    /// flag drops, and removes the child-session variables.
    func environment(base: [String: String], account: AgentAccountRef?) -> [String: String]
    /// Non-nil while this conformer is still a Track 0 stub: one of `AgentProfileStub`'s
    /// constants, naming the track that owns it. A track deletes its conformer's override when
    /// the real profile lands; tests assert on this, never on behaviour, to tell stub from real.
    var unimplemented: String? { get }
    /// Whether a headless run must be preceded by `signInCheck`. True for a CLI whose headless
    /// mode, when signed out, STARTS an interactive sign-in (opens a browser, waits for a
    /// code) instead of failing fast — `agy -p` does, so a seat on a signed-out account would
    /// launch a Google sign-in in the human's browser. The executor runs the check first and
    /// pauses the round with `authExpired` rather than spawning the run.
    var headlessSignInPreflight: Bool { get }
}

public extension AgentProfile {
    var unimplemented: String? { nil }
    var headlessSignInPreflight: Bool { false }
}

/// The stub markers. Each names the track that replaces the stub. When no conformer returns
/// one any more, delete this enum — a reference to it left anywhere is then a compile error,
/// which is the point.
public enum AgentProfileStub {
    public static let trackP = "unimplemented in track P"
    public static let trackG = "unimplemented in track G"
    public static let trackM = "unimplemented in track M"
}

// MARK: - Registry

public enum AgentProfiles {
    /// One profile per `Harness` case, in `Harness.allCases` order.
    public static let all: [any AgentProfile] = Harness.allCases.map { AgentProfiles.profile(for: $0) }

    public static func profile(for harness: Harness) -> any AgentProfile {
        switch harness {
        case .claude: ClaudeProfile()
        case .codex: CodexProfile()
        case .grok: GrokProfile()
        case .gemini: GeminiProfile()
        }
    }

    /// The harnesses whose headless command and output parser exist (`HarnessCommand.build`,
    /// `HarnessOutput.parse`). The availability gate: `AvailableModels` never holds a harness
    /// outside this set, so a round can never be configured to run a harness that would only
    /// fail at round time. Track G adds `.grok` and Track M adds `.gemini` when their builders
    /// land — and not before, which is what keeps master shippable meanwhile.
    public static let headlessReady: Set<Harness> = [.claude, .codex]
}

// MARK: - Stub conformers (Track 0)
//
// Each returns explicit "unimplemented" values that tests detect: an empty catalog, a classifier
// that recognizes nothing, and `base` unchanged for the environment. No `fatalError` — a stub is
// reachable from shipping code (`FailureDiagnosis` reads `binaryName`), so it must answer safely.
// `id`, `family`, `binaryName` and `hasNativeSchema` are facts, not implementation, and are real.

private func stubSignInCheck(_ marker: String) -> SignInCheck {
    SignInCheck(arguments: [], signedOutHint: marker, isSignedIn: { _ in false })
}

public struct ClaudeProfile: AgentProfile {
    public init() {}
    public var id: Harness { .claude }
    public var family: ModelFamily { .claude }
    public var binaryName: String { "claude" }
    public var signInCheck: SignInCheck { stubSignInCheck(AgentProfileStub.trackP) }
    public var modelCatalog: ProfileModelCatalog { .empty }
    public func parseModelList(_ stdout: String) -> [String] { [] }
    public var hasNativeSchema: Bool { true }
    public func classify(error: AgentErrorSignal) -> AgentFailureKind? { nil }
    public func environment(base: [String: String], account: AgentAccountRef?) -> [String: String] { base }
    public var unimplemented: String? { AgentProfileStub.trackP }
}

public struct CodexProfile: AgentProfile {
    public init() {}
    public var id: Harness { .codex }
    public var family: ModelFamily { .codex }
    public var binaryName: String { "codex" }
    public var signInCheck: SignInCheck { stubSignInCheck(AgentProfileStub.trackP) }
    public var modelCatalog: ProfileModelCatalog { .empty }
    public func parseModelList(_ stdout: String) -> [String] { [] }
    public var hasNativeSchema: Bool { true }
    public func classify(error: AgentErrorSignal) -> AgentFailureKind? { nil }
    public func environment(base: [String: String], account: AgentAccountRef?) -> [String: String] { base }
    public var unimplemented: String? { AgentProfileStub.trackP }
}

public struct GrokProfile: AgentProfile {
    public init() {}
    public var id: Harness { .grok }
    public var family: ModelFamily { .grok }
    public var binaryName: String { "grok" }
    public var signInCheck: SignInCheck { stubSignInCheck(AgentProfileStub.trackG) }
    public var modelCatalog: ProfileModelCatalog { .empty }
    public func parseModelList(_ stdout: String) -> [String] { [] }
    /// `grok --json-schema` (grok 1.0.30, spec §2). Strict-mode compatibility is Track G's probe.
    public var hasNativeSchema: Bool { true }
    public func classify(error: AgentErrorSignal) -> AgentFailureKind? { nil }
    public func environment(base: [String: String], account: AgentAccountRef?) -> [String: String] { base }
    public var unimplemented: String? { AgentProfileStub.trackG }
}

// `GeminiProfile` lives in GeminiProfile.swift (Track M).
