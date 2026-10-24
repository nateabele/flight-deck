import FleetKit
import Foundation

/// A separate entry point keeps a long-lived MCP stdio client out of CLIRunner's
/// one-command state machine. Both surfaces use the same authenticated local request.
enum PeerCLI {
    static let help = """
    flightdeck peer list
    flightdeck peer send TARGET "message" [--notify-when-idle] [--from TAB_UUID]
    flightdeck peer receive [--after CURSOR] [--from TAB_UUID]
    flightdeck peer mcp

    Targets are an exact tab name, tab UUID, native conversation UUID, or uds: address.
    A send acknowledges the socket write, not model receipt or completed work.
    Inside a tab the sender is authenticated automatically. --from is for a human shell.
    """

    static func parse(_ arguments: [String]) throws -> WirePeerRequest? {
        var args = arguments
        guard let op = args.first else { return nil }
        args.removeFirst()
        if ["--help", "-h", "help"].contains(op) { return nil }
        guard ["list", "send", "receive"].contains(op) else { throw CLIUsageError("peer: unknown command \(op)") }
        var operands: [String] = [], notify = false, after = 0, source: UUID?
        var literal = false
        while !args.isEmpty {
            let next = args.removeFirst()
            if literal { operands.append(next); continue }
            switch next {
            case "--": literal = true
            case "--notify-when-idle": notify = true
            case "--after":
                guard !args.isEmpty, let value = Int(args.removeFirst()), value >= 0 else { throw CLIUsageError("peer: invalid cursor") }
                after = value
            case "--from":
                guard !args.isEmpty, let value = UUID(uuidString: args.removeFirst()) else { throw CLIUsageError("peer: --from needs a tab UUID") }
                source = value
            default:
                guard !next.hasPrefix("--") else { throw CLIUsageError("peer: unknown flag \(next)") }
                operands.append(next)
            }
        }
        guard op == "send" ? operands.count == 2 : operands.isEmpty,
              op == "send" || !notify, op == "receive" || after == 0 else { throw CLIUsageError(help) }
        return WirePeerRequest(operation: op, target: operands.first,
            message: operands.count == 2 ? operands[1] : nil, notifyWhenIdle: notify, after: after, source: source)
    }
}
