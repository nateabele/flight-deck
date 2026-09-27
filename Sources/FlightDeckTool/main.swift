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
    Task {
        let status = await runner.run()
        exit(status == .failed ? 1 : 0)
    }
    dispatchMain()
}

// `--socket` → `$FLIGHT_DECK_CONTROL_SOCKET` → `$FLIGHT_DECK_STATE_DIR/control.sock` → the
// default state dir, mirroring scripts/answer-trigger.sh's own fallback.
let stateDir = env["FLIGHT_DECK_STATE_DIR"] ?? (NSHomeDirectory() + "/Library/Application Support/Flight Deck")
let socketPath = invocation.socket
    ?? env["FLIGHT_DECK_CONTROL_SOCKET"]
    ?? (stateDir + "/control.sock")

let context = CLIContext(
    selfID: UUID(uuidString: env["FLIGHT_DECK_SESSION_ID"] ?? ""),
    cwd: FileManager.default.currentDirectoryPath,
    json: invocation.json,
    isTTY: isatty(1) == 1
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
        // CLIRunner itself never prints for 69 — the comment on `disconnected(_:)` says the
        // path is main's to supply, so this is the only place this message is ever printed.
        if code == 69 {
            writeStderr("flightdeck: cannot reach Flight Deck at \(socketPath)")
        }
        exit(code)
    },
    schedule: { delay, action in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
    }
)

runner.run()
dispatchMain()
