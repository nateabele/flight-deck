import Foundation

/// What the compiler handed back, before validation.
public enum RuleProposal: Equatable, Sendable {
    case wire(RuleCompilerWire)
    /// The compiler could not run (no CLI, not logged in, no network). The rule stays a draft.
    case unavailable(String)
    /// It ran, but the answer was not the schema's shape. The rule fails with this reason.
    case malformed(String)
}

public enum RuleCompileOutcome: Equatable, Sendable {
    case compiled(CompiledRule)
    case failed(String)
    case unavailable(String)
}

/// The seam the app compiles through, so Settings and the UI-test fixture can swap the model
/// call while keeping the real validation.
public protocol RuleCompiling: Sendable {
    var ref: CompilerRef { get }
    func propose(_ input: RuleCompilerInput) async -> RuleProposal
}

public enum RuleCompilation {
    /// No automatic retry (spec §3): a failed rule shows its first error and waits for you.
    public static func finish(_ proposal: RuleProposal, input: RuleCompilerInput) -> RuleCompileOutcome {
        switch proposal {
        case .unavailable(let why):
            return .unavailable(why)
        case .malformed(let why):
            return .failed("the compiler gave no usable answer: \(why)")
        case .wire(let wire):
            switch RuleValidator.validate(wire, input: input) {
            case .success(let compiled): return .compiled(compiled)
            case .failure(let error): return .failed(error.message)
            }
        }
    }
}

extension RoutingRule {
    /// An unavailable compiler changes nothing: confirmed rules keep routing and drafts stay
    /// drafts (spec §8).
    public mutating func record(_ outcome: RuleCompileOutcome, by compiler: CompilerRef, at date: Date) {
        switch outcome {
        case .compiled(let c):
            compiled = c; state = .compiled; failure = nil; compiledAt = date; self.compiler = compiler; adjusted = false
        case .failed(let why):
            compiled = nil; state = .failed; failure = why; compiledAt = date; self.compiler = compiler; adjusted = false
        case .unavailable:
            break
        }
    }
}

/// One headless model call per sentence (spec §3) — `claude -p` haiku by default — through the
/// same `HarnessCommand` every planning round uses, read-only, in a scratch directory.
public struct RuleCompiler: RuleCompiling {
    public let runner: any CommandRunner
    public let settings: RuleCompilerSettings
    public let workDirectory: URL
    /// Where `HarnessCommand` reads the user's codex/claude settings from. A test passes a
    /// scratch directory so it never reads the operator's own.
    public let home: URL
    public let baseEnvironment: @Sendable () -> [String: String]

    public init(runner: any CommandRunner, settings: RuleCompilerSettings, workDirectory: URL,
                home: URL = FileManager.default.homeDirectoryForCurrentUser,
                baseEnvironment: @escaping @Sendable () -> [String: String]) {
        self.runner = runner; self.settings = settings; self.workDirectory = workDirectory
        self.home = home; self.baseEnvironment = baseEnvironment
    }

    public var ref: CompilerRef { settings.ref }

    public func propose(_ input: RuleCompilerInput) async -> RuleProposal {
        let schemaFile = workDirectory.appendingPathComponent("rule-schema.json")
        do {
            try FileManager.default.createDirectory(at: workDirectory, withIntermediateDirectories: true)
            try Data(RuleCompilerPrompt.schemaJSON.utf8).write(to: schemaFile, options: .atomic)
        } catch {
            return .unavailable("could not prepare \(workDirectory.path): \(error)")
        }
        let request = HarnessRequest(harness: settings.harness, model: settings.model, effort: settings.effort,
                                     cwd: workDirectory, readableDirs: [], prompt: RuleCompilerPrompt.text(input),
                                     schemaFile: schemaFile, schemaJSON: RuleCompilerPrompt.schemaJSON, resumeSessionID: nil)
        // A compiler set to a planning-only harness (grok/gemini, not an agent harness — spec
        // §3.1) with no builder yet reads as unavailable, the same as a missing binary.
        let command: (executable: String, arguments: [String], unsetEnvironment: [String])
        do { command = try HarnessCommand.build(request, home: home) }
        catch { return .unavailable("\(settings.harness.rawValue) cannot compile rules: \(error)") }
        let environment = HarnessCommand.environment(for: command, base: baseEnvironment(), home: home)
        let result: CommandResult
        do {
            result = try await runner.run(executable: command.executable, arguments: command.arguments, cwd: workDirectory,
                                          environment: environment, processGroup: false, onSpawn: nil)
        } catch {
            return .unavailable("could not start \(command.executable): \(error)")
        }
        guard result.exitCode == 0 else {
            let line = result.stderr.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? ""
            return .unavailable("\(command.executable) exited \(result.exitCode)" + (line.isEmpty ? "" : ": \(line)"))
        }
        let structured: Data
        do { structured = try HarnessOutput.parse(settings.harness, stdout: result.stdout).structured }
        catch { return .malformed("\(error)") }
        do { return .wire(try JSONDecoder().decode(RuleCompilerWire.self, from: structured)) }
        catch { return .malformed("not the rule shape: \(error)") }
    }
}
