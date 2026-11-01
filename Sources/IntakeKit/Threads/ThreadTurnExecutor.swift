import Foundation

/// One headless run of a thread's agent, as ThreadRunner asks for it.
public struct ThreadTurnRequest: Equatable, Sendable {
    public var thread: ThreadID
    public var agent: AgentID
    public var model: String
    public var effort: String
    /// The project repo: the run's working directory, which the agent interrogates (D5).
    public var project: URL
    /// The thread's workspace, readable beside the repo.
    public var readable: [URL]
    public var prompt: String
    /// The session the turn resumes; nil on the thread's first turn.
    public var resumeSessionID: String?
    /// Where this run keeps its stdout, stderr and schema (`ThreadStore.runDirectory`).
    public var runDirectory: URL
    /// Where its live activity goes (`ThreadStore.activityURL`, R2).
    public var activityURL: URL
    /// The account the run bills; nil is the CLI's built-in home.
    public var account: AgentAccountRef?
    public var accountID: UUID?

    public init(thread: ThreadID, agent: AgentID, model: String, effort: String, project: URL, readable: [URL],
                prompt: String, resumeSessionID: String?, runDirectory: URL, activityURL: URL,
                account: AgentAccountRef? = nil, accountID: UUID? = nil) {
        self.thread = thread; self.agent = agent; self.model = model; self.effort = effort
        self.project = project; self.readable = readable; self.prompt = prompt
        self.resumeSessionID = resumeSessionID; self.runDirectory = runDirectory; self.activityURL = activityURL
        self.account = account; self.accountID = accountID
    }
}

/// How a run ended. `malformed` is an answer that isn't a `ThreadAnswer`; ThreadRunner treats it
/// like a refused action and retries with the reason. `failed` is the harness failing — no
/// answer to fix, so no retry.
public enum ThreadTurnOutcome: Equatable, Sendable {
    case answered(ThreadAnswer, sessionID: String)
    case malformed(String, sessionID: String?)
    case failed(Diagnosis, sessionID: String?)
}

/// What ThreadRunner runs a turn through: the real CLI (`ThreadTurnExecutor`), or a scripted
/// agent in tests, which never spend real tokens. Throws only `CancellationError`.
public protocol ThreadTurnExecuting: Sendable {
    func run(_ request: ThreadTurnRequest) async throws -> ThreadTurnOutcome
}

/// A turn through the agent's own CLI: `HeadlessCommand.build` with `.threadRead` access and
/// the `ThreadActions` schema, stdout streamed to the run's directory and through
/// `ActivityPublisher` into the thread's live activity, then parsed and decoded. The same shape
/// as a round seat's `RoundExecutor.attempt`, without the round's bookkeeping.
public struct ThreadTurnExecutor: ThreadTurnExecuting {
    /// What an agent CLI a turn starts presents to Flight Deck's control socket, in
    /// `FLIGHT_DECK_CALLER` (I4). With no token the socket reads a caller as the human, who is
    /// unscoped, so an agent whose shell can reach the socket (codex's) would act as the user.
    /// This value is neither a tab token nor a runner token, so `ControlScope.caller` reads it as
    /// invalid and the agent fails closed. The runner's own token never reaches an agent: the
    /// runner keeps it for its own calls.
    public static let agentCaller = "thread-agent:none"
    static let callerVariable = "FLIGHT_DECK_CALLER"

    private let runner: CommandRunner
    private let environment: [String: String]
    private let userHome: URL
    private let now: @Sendable () -> Date

    /// `environment` is the runner's resolved base environment (PATH repaired by whoever spawned
    /// it), as a round seat gets.
    public init(runner: CommandRunner, environment: [String: String],
                userHome: URL = FileManager.default.homeDirectoryForCurrentUser,
                now: @escaping @Sendable () -> Date = Date.init) {
        self.runner = runner
        self.environment = environment
        self.userHome = userHome
        self.now = now
    }

    public func run(_ r: ThreadTurnRequest) async throws -> ThreadTurnOutcome {
        try Task.checkCancellation()
        let fm = FileManager.default
        if fm.fileExists(atPath: r.runDirectory.path) { try? fm.removeItem(at: r.runDirectory) }
        // Inside the thread's own folder only: a trashed intake's folders are not made again (A-I1).
        let threadFolder = r.runDirectory.deletingLastPathComponent().deletingLastPathComponent()
        try IntakeDirectory.create(r.runDirectory, in: threadFolder)
        let schemaFile = r.runDirectory.appendingPathComponent("schema.json")
        try Data(ThreadActions.schemaJSON.utf8).write(to: schemaFile, options: .atomic)

        let request = HeadlessRequest(agent: r.agent, model: r.model, effort: r.effort, cwd: r.project,
                                      readableDirs: r.readable, prompt: r.prompt, schemaFile: schemaFile,
                                      schemaJSON: ThreadActions.schemaJSON, resumeSessionID: r.resumeSessionID,
                                      access: .threadRead, account: r.account)
        let command: (executable: String, arguments: [String], unsetEnvironment: [String])
        do { command = try HeadlessCommand.build(request, home: userHome) }
        catch {
            return .failed(Diagnosis(category: .harnessError, detail: "\(r.agent.displayName) can't run a thread turn: \(error)",
                                     action: "Switch this thread to another agent."), sessionID: nil)
        }
        var base = environment
        base[Self.callerVariable] = Self.agentCaller
        let env = HeadlessCommand.environment(for: command, base: base, home: userHome, account: r.account,
                                              readable: r.readable)

        let stdoutFile = r.runDirectory.appendingPathComponent("stdout")
        guard fm.createFile(atPath: stdoutFile.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: stdoutFile.path])
        }
        let stream = try FileHandle(forWritingTo: stdoutFile)
        defer { try? stream.close() }
        let activity = ActivityPublisher(agent: r.agent, project: r.project, cwd: r.project, accountID: r.accountID,
                                         destination: r.activityURL, now: now)
        activity.start()

        let result: CommandResult
        do {
            // Its own process group, so cancelling the turn (the runner shutting down) reaches
            // every child the CLI forked, as a round seat's does.
            result = try await runner.run(executable: command.executable, arguments: command.arguments, cwd: r.project,
                                          environment: env, processGroup: true, onSpawn: nil,
                                          onStdout: { chunk in
                                              try? stream.write(contentsOf: chunk)
                                              activity.feed(chunk)
                                          })
        } catch is CancellationError {
            activity.finish(exitCode: nil)
            throw CancellationError()
        } catch {
            activity.finish(exitCode: nil, error: "Could not run \(command.executable)")
            return .failed(Diagnosis(category: .harnessError, detail: "Could not run \(command.executable): \(error)",
                                     action: "Check that \(command.executable) is installed, then try again."), sessionID: nil)
        }
        activity.finish(exitCode: result.exitCode)
        try? Data(result.stderr.utf8).write(to: r.runDirectory.appendingPathComponent("stderr"), options: .atomic)
        return Self.outcome(agent: r.agent, result: result)
    }

    /// The pure half: a finished run's output as an outcome.
    public static func outcome(agent: AgentID, result: CommandResult) -> ThreadTurnOutcome {
        guard result.exitCode == 0 else {
            return .failed(FailureDiagnosis.classify(exitCode: result.exitCode, stdout: result.stdout, stderr: result.stderr,
                                                     parseError: nil, agent: agent), sessionID: nil)
        }
        let parsed: (sessionID: String, structured: Data)
        do { parsed = try HeadlessOutput.parse(agent, stdout: result.stdout) }
        catch HeadlessOutput.ParseError.notJSON(let text) {
            // An answer that isn't JSON is the agent's to fix, on the session it reported.
            return .malformed("your answer was not JSON: \(text.prefix(200))",
                              sessionID: HeadlessOutput.reportedSession(agent, stdout: result.stdout))
        } catch {
            return .failed(FailureDiagnosis.classify(exitCode: 0, stdout: result.stdout, stderr: result.stderr,
                                                     parseError: error, agent: agent),
                           sessionID: HeadlessOutput.reportedSession(agent, stdout: result.stdout))
        }
        do { return .answered(try ThreadActions.decode(parsed.structured), sessionID: parsed.sessionID) }
        catch let malformed as ThreadActions.Malformed { return .malformed(malformed.why, sessionID: parsed.sessionID) }
        catch { return .malformed("\(error)", sessionID: parsed.sessionID) }
    }
}
