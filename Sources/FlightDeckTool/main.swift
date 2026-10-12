import Dispatch
import FleetKit
import Foundation
import IntakeKit

// `flightdeck tail | head` must end quietly, not crash the process on the write that finds
// the reader gone.
signal(SIGPIPE, SIG_IGN)

// Every verb from the spec's command table (docs/superpowers/specs/2026-09-24-flightdeck-cli-
// design.md), one line each, then how `--` works, since a dash-led text is the one argument
// shape the lines above cannot show. `--help`'s only output, and also what a usage error prints
// below its own message.
let usageLines = [
    "flightdeck ls [--project P]",
    "flightdeck tail [--session S] [--since SEQ] [--no-snapshot]",
    "flightdeck wait S --for idle|busy|waiting|gone [--timeout D]",
    "flightdeck send S \"text\" [--wait [--timeout D]]",
    "flightdeck new P [--agent A [--account N]]",
    "flightdeck close S",
    "flightdeck reopen S",
    "flightdeck rename S \"t\"",
    "flightdeck read S",
    "flightdeck unread S",
    "flightdeck collapse P [--off]",
    "flightdeck prompt S",
    "flightdeck answer S '[[0,1],[2]]' [--call C]",
    "flightdeck abort S",
    "flightdeck plan approve S [--feedback F]",
    "flightdeck plan reject S [--feedback F]",
    "flightdeck plan annotate S \"text\" [--block N]",
    "flightdeck timeline S [--before N|--after N|--around N] [--limit N]",
    "flightdeck search \"q\" [--limit N]",
    "flightdeck open CONVO --project PATH",
    "flightdeck closed",
    "flightdeck intake run ID --root DIR   run an intake's planning rounds (started by Flight Deck)",
    "flightdeck options P",
    "flightdeck host ls [--disk [HOST]]",
    "flightdeck host info <host>",
    "flightdeck host prune <host> [--repo R]",
    "flightdeck run [--on H] [--include P]... [--fetch G]... [--env K=V]... [--pty] [--screen] [--detach] -- cmd...",
    "flightdeck run RECIPE [same flags] [-- extra args]",
    "flightdeck exec --on H -- cmd...      run in the host's checkout without syncing",
    "flightdeck up RECIPE | up --on H --port L:R... -- cmd...",
    "flightdeck down|restart|sync SERVICE",
    "flightdeck ps",
    "flightdeck wait RUN [--timeout S]     exits with the run's status; 124 on timeout",
    "flightdeck logs RUN [--follow]",
    "flightdeck stop RUN",
    "flightdeck diff|apply RUN",
    "flightdeck recipe ls|check",
    "flightdeck recipe add NAME --run CMD [--host H] [--service] [--long] [--screen] [--port P]... [--apply auto]",
    "  (delegation failures exit 125 with one flightdeck: line naming the host and the next step)",
    "flightdeck infra up <name>            create [infra.<name>] from this repo's delegate.toml",
    "flightdeck infra down <name> | --orphan <id>",
    "flightdeck infra ls [--orphans]",
    "flightdeck infra doctor",
    "flightdeck infra extend <name> <duration>",
    "  (infra failures exit 125, one flightdeck: line per problem, each with its fix)",
    "flightdeck raw '<ClientFrame JSON>'",
    "",
    "Flags go before or after operands. Put -- before text that starts with -:",
    "  flightdeck send S --wait -- \"- text\"",
]

func writeStderr(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}

let env = ProcessInfo.processInfo.environment

let invocation: CLIInvocation
do {
    invocation = try CLIArguments.parse(Array(CommandLine.arguments.dropFirst()))
} catch let error as CLIUsageError {
    writeStderr("flightdeck: \(error.message)")
    usageLines.forEach(writeStderr)
    exit(2)
}

if invocation.command == .help {
    usageLines.forEach { print($0) }
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

let transport = LocalFleetTransport(path: socketPath, caller: env["FLIGHT_DECK_CALLER"])

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
