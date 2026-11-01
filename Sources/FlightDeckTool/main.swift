import Dispatch
import FleetKit
import Foundation
import IntakeKit

// `flightdeck tail | head` must end quietly, not crash the process on the write that finds
// the reader gone.
signal(SIGPIPE, SIG_IGN)

func writeStderr(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

let env = ProcessInfo.processInfo.environment

// Claude's hook plugin (`scripts/record.sh`) pipes every lifecycle payload here. Hidden from
// help: no person runs it. It pares the payload to what Flight Deck reads (`HookEventLine`)
// and appends that one line, touching no socket. Exits 0 on every path, because a hook that
// fails blocks the agent, and reads stdin to its end so claude never meets a closed pipe.
if CommandLine.arguments.dropFirst().first == "hook-record" {
    let payload = FileHandle.standardInput.readDataToEndOfFile()
    if let dir = env["FLIGHT_DECK_EVENT_DIR"], !dir.isEmpty, let line = HookEventLine.pare(payload) {
        HookEventLine.append(line, toDirectory: URL(fileURLWithPath: dir, isDirectory: true))
    }
    exit(0)
}

if CommandLine.arguments.dropFirst().first == "peer" {
    PeerToolEntry.run(Array(CommandLine.arguments.dropFirst(2)), environment: env)
}

let invocation: CLIInvocation
do {
    invocation = try CLIArguments.parse(Array(CommandLine.arguments.dropFirst()))
} catch let error as CLIUsageError {
    // The failing verb's usage, not every verb's: the full help is one --help away.
    writeStderr("flightdeck: \(error.message)")
    CLIHelp.hint(for: Array(CommandLine.arguments.dropFirst())).forEach(writeStderr)
    exit(2)
}

if case .help(let topic) = invocation.command {
    print(CLIHelp.text(for: topic))
    exit(0)
}

// The detached round runner Flight Deck launches under fd-abduco (Task 10). It has no fleet
// to reach and needs no socket, so it is intercepted here, before any of the transport setup
// below runs — that setup would be dead weight, and worse, a socket connect attempt this
// process has no reason to make. Environment is inherited as-is: the app builds it before
// launching this process (Task 10's job, not this one's).
if case .intakeRun(let id, let root) = invocation.command {
    let environment = ProcessInfo.processInfo.environment
    let runner = IntakeRunner(
        root: URL(fileURLWithPath: root),
        intakeID: id,
        executor: RoundExecutor(
            runner: SystemCommandRunner(),
            graphReader: GraphReader(runner: SystemCommandRunner(), environment: environment)
        ),
        environment: environment
    )
    // A semaphore `wait()` here would block the main thread the `Task` needs scheduled onto —
    // this binary has no main actor of its own, only Foundation's runloop-backed executor, so
    // blocking that thread deadlocks forever rather than letting the Task ever run. `exit(_:)`
    // never returns, so nothing after `dispatchMain()` executes and there is no fall-through
    // into the socket/transport code below.
    //
    // `runTask` is boxed in a class rather than a plain local `var` so `RunnerSignals.install`'s
    // closure can be handed a stable reference before the Task it cancels exists yet — the
    // closure only runs later, once a real signal arrives, by which point `box.task` is set.
    final class TaskBox { var task: Task<Void, Never>? }
    let box = TaskBox()
    // Logout, reboot or a daemon reap ends this process with one of these. Ignored and rewired
    // to cancellation rather than left at their default action, so `RoundExecutor`'s children
    // — each its own process-group leader — get `killpg`'d by the same cancellation path ⏹
    // uses, instead of being orphaned to keep spending tokens with nothing left alive to reap
    // them. Unlike ⏹ (a command in `commands.jsonl`), a signal writes nothing terminal: the
    // tape stays mid-round with its heartbeat cleared, so the app respawns a runner and the
    // round reruns (`IntakeRunner.run`).
    let signalSources = RunnerSignals.install { box.task?.cancel() }
    box.task = Task {
        let status = await runner.run()
        exit(status == .failed ? 1 : 0)
    }
    // `withExtendedLifetime` rather than a bare unused `let`: `signalSources` is never read
    // again, only held — a `DispatchSourceSignal` with nothing retaining it is released, and
    // its handler stops firing, before it ever gets the chance to.
    withExtendedLifetime(signalSources) {
        dispatchMain()
    }
}

// `--socket` → `$FLIGHT_DECK_CONTROL_SOCKET` → `$FLIGHT_DECK_STATE_DIR/control.sock` → the
// default state dir, mirroring scripts/answer-trigger.sh's own fallback.
let stateDir = env["FLIGHT_DECK_STATE_DIR"] ?? (NSHomeDirectory() + "/Library/Application Support/Flight Deck")
let socketPath = invocation.socket
    ?? env["FLIGHT_DECK_CONTROL_SOCKET"]
    ?? (stateDir + "/control.sock")

// The terminal's size, for `run --pty` (§6.1): the host's pty is sized once from it.
var window = winsize()
let hasTerminal = ioctl(1, TIOCGWINSZ, &window) == 0 && window.ws_col > 0

let context = CLIContext(
    selfID: UUID(uuidString: env["FLIGHT_DECK_SESSION_ID"] ?? ""),
    cwd: FileManager.default.currentDirectoryPath,
    json: invocation.json,
    isTTY: isatty(1) == 1,
    columns: hasTerminal ? Int(window.ws_col) : nil,
    rows: hasTerminal ? Int(window.ws_row) : nil,
    environment: env,
    socketPath: socketPath
)

let transport = LocalFleetTransport(path: socketPath, caller: ControlCallerHello.compose(environment: env))

let runner = CLIRunner(
    invocation: invocation,
    transport: transport,
    context: context,
    out: { line in
        print(line)
        fflush(stdout)
    },
    err: { line in writeStderr(line) },
    finish: { code in
        // CLIRunner itself never prints for 69 or 77 — the comment on `disconnected(_:)` says
        // the path is main's to supply, so this is the only place either message is printed.
        if code == 69 {
            writeStderr("flightdeck: cannot reach Flight Deck at \(socketPath)")
        } else if code == 77 {
            writeStderr("flightdeck: the agent's sandbox blocked the control socket at \(socketPath)")
            writeStderr("flightdeck: codex tabs opened by Flight Deck are granted it; reopen a tab that predates this, or one run with an explicit sandbox mode")
        }
        exit(code)
    },
    schedule: { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
    },
    // A delegated run's bytes, as they came: no newline added, stderr kept apart from stdout,
    // so `flightdeck run -- make` reads exactly like `make`.
    // `write(contentsOf:)`, which throws, never the legacy `write(_:)`, which raises an
    // Objective-C exception on EPIPE and crashes `flightdeck run … | head`.
    write: { stream, data in
        try (stream == "stderr" ? FileHandle.standardError : FileHandle.standardOutput).write(contentsOf: data)
    },
    execReal: { argv0, args in exit(DelegateRouting.execReal(argv0, args, environment: env)) }
)

// A delegated run forwards Ctrl-C to the host (§6.1) rather than dying and leaving the run
// going there unwatched. Only for the verbs attached to a run, and `infra up`; every other
// verb keeps the default disposition.
var interruptSources: [DispatchSourceSignal] = []
switch invocation.command {
// `infra up` keeps going in the app on Ctrl-C (a half-created machine must not be abandoned);
// the CLI says so, and how to cancel it, rather than dying silently mid-create.
case .delegate(.run), .delegate(.exec), .delegate(.wait), .delegate(.logs), .delegate(.routeExec), .infra(.up):
    interruptSources = RunnerSignals.install(signals: [SIGINT]) {
        DispatchQueue.main.async { runner.interrupt() }
    }
default:
    break
}

runner.run()
withExtendedLifetime(interruptSources) {
    dispatchMain()
}
