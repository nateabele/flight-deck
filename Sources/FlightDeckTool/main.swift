import Dispatch
import FleetKit
import Foundation

// `flightdeck tail | head` must end quietly, not crash the process on the write that finds
// the reader gone.
signal(SIGPIPE, SIG_IGN)

// Every verb from the spec's command table (docs/superpowers/specs/2026-09-24-flightdeck-cli-
// design.md), one line each — `--help`'s only output, and also what a usage error prints below
// its own message.
let usageLines = [
    "flightdeck ls [--project P]",
    "flightdeck tail [--session S] [--since SEQ] [--no-snapshot]",
    "flightdeck wait S --for idle|waiting|gone [--timeout D]",
    "flightdeck send S \"text\"",
    "flightdeck new P [--agent A] [--account N]",
    "flightdeck close S",
    "flightdeck reopen S",
    "flightdeck rename S \"t\"",
    "flightdeck read S",
    "flightdeck unread S",
    "flightdeck collapse P [--off]",
    "flightdeck answer S '[[0,1],[2]]' [--call C]",
    "flightdeck abort S",
    "flightdeck plan approve S [--feedback F]",
    "flightdeck plan reject S [--feedback F]",
    "flightdeck plan annotate S \"text\" [--block N]",
    "flightdeck timeline S [--before N|--after N|--around N] [--limit N]",
    "flightdeck search \"q\" [--limit N]",
    "flightdeck open CONVO --project PATH",
    "flightdeck closed",
    "flightdeck options P",
    "flightdeck raw '<ClientFrame JSON>'",
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
