import FleetKit
import Foundation
import HostKit

// `flightdeck infra up|down|ls|doctor|extend` (cloud infra hosts, spec §8.4 and §10): parsing,
// the request each verb sends, and everything it prints. The app owns every credential, the
// OpenTofu state and the budget (InfraControlWire.swift), so the CLI only names what it wants.

/// A parsed `flightdeck infra` subcommand.
public enum InfraCommand: Equatable {
    case up(name: String)
    /// `down NAME`, or `down --orphan KIND:ID` for one resource `ls --orphans` found.
    case down(name: String?, orphan: String?)
    case ls(orphans: Bool)
    case doctor
    /// `by` as written (`1h`); already checked to parse, and sent as seconds.
    case extend(name: String, by: String)

    func request(cwd: String) -> InfraRequest {
        switch self {
        case .up(let name): return .up(name: name, cwd: cwd)
        // The wire's `name` is ignored, and sent empty, when `orphanID` is set.
        case .down(let name, let orphan): return .down(name: orphan == nil ? name ?? "" : "", orphanID: orphan)
        case .ls(let orphans): return .list(orphans: orphans)
        case .doctor: return .doctor
        case .extend(let name, let by): return .extend(name: name, seconds: HostKit.Duration.parse(by)?.seconds ?? 0)
        }
    }
}

enum InfraArguments {
    static func parse(_ c: inout CLIArguments.Cursor) throws -> CLICommand {
        let sub = try c.requirePositional("infra: missing subcommand (up, down, ls, doctor or extend)")
        switch sub {
        case "up":
            return .infra(.up(name: try c.requirePositional("infra up: missing machine name")))
        case "down":
            let name = c.optionalPositional()
            var orphan: String?
            while let flag = c.nextFlag() {
                switch flag {
                case "--orphan": orphan = try c.require(after: flag)
                default: throw CLIArguments.Cursor.unknownFlag(flag, in: "infra down")
                }
            }
            // Exactly one: a name and an orphan together would leave which to destroy a guess.
            guard (name == nil) != (orphan == nil) else {
                throw CLIUsageError("infra down: give a machine name or --orphan KIND:ID, not both or neither")
            }
            return .infra(.down(name: name, orphan: orphan))
        case "ls":
            var orphans = false
            while let flag = c.nextFlag() {
                switch flag {
                case "--orphans": orphans = true
                default: throw CLIArguments.Cursor.unknownFlag(flag, in: "infra ls")
                }
            }
            return .infra(.ls(orphans: orphans))
        case "doctor":
            return .infra(.doctor)
        case "extend":
            let name = try c.requirePositional("infra extend: missing machine name")
            let by = try c.requirePositional("infra extend: missing duration (e.g. 1h, 30m)")
            // The same grammar `ttl` is written in, so a typo is refused here rather than
            // extending by zero.
            guard HostKit.Duration.parse(by) != nil else {
                throw CLIUsageError("infra extend: duration must be like 30m, 1h or 1h30m, got \"\(by)\"")
            }
            return .infra(.extend(name: name, by: by))
        default:
            throw CLIUsageError("infra: unknown subcommand \"\(sub)\"")
        }
    }
}

/// What an infra verb needs from the `CLIRunner` around it, as closures so it is driven frame
/// by frame in a test with nothing else running (`DelegateRunnerHooks`' reason).
struct InfraRunnerHooks {
    var send: (FleetRequest) -> Int
    /// Registers the handler for every frame on `cid` (`up` and `down` draw several).
    var expect: (_ cid: Int, _ handler: @escaping (ServerFrame) -> Void) -> Void
    var out: (String) -> Void
    var err: (String) -> Void
    var finish: (Int32) -> Void
}

/// One `infra` verb from request to exit.
///
/// Exit statuses: 0 done; **125** for any `infra_*` refusal, after its `flightdeck:` lines, as
/// a delegation failure is; 1 for anything else (a failing `doctor` check, a stray reply);
/// 130 for Ctrl-C during `up`, which leaves the app creating the machine.
final class InfraCommandRunner {
    private let command: InfraCommand
    private let cwd: String
    private let wantsJSON: Bool
    private let hooks: InfraRunnerHooks
    private var finished = false
    /// The cost line `up` already printed from its `cost:` progress, so the machine that ends
    /// the stream does not print it twice.
    private var printedCost: String?

    init(command: InfraCommand, cwd: String, wantsJSON: Bool, hooks: InfraRunnerHooks) {
        self.command = command
        self.cwd = cwd
        self.wantsJSON = wantsJSON
        self.hooks = hooks
    }

    func start() {
        let cid = hooks.send(.infra(command.request(cwd: cwd)))
        hooks.expect(cid) { frame in
            guard !self.finished else { return }
            switch frame {
            case .infraProgress(_, let line):
                if line.hasPrefix("cost: ") {
                    let cost = String(line.dropFirst("cost: ".count))
                    self.printedCost = cost
                    self.hooks.err("flightdeck: \(cost)")
                } else {
                    self.hooks.err("flightdeck: \(line)")
                }
            case .infraMachine(_, let machine):
                if self.printedCost != machine.costLine { self.hooks.err("flightdeck: \(machine.costLine)") }
                self.hooks.out(self.wantsJSON ? CLIOutput.json(machine) : InfraOutput.table([machine]))
                self.finish(0)
            case .infraDone:
                if self.wantsJSON { self.hooks.out("{}") }
                self.finish(0)
            case .infraList(_, let machines, let orphans, let unreadable):
                if self.wantsJSON {
                    self.hooks.out(CLIOutput.json(InfraOutput.Listing(machines: machines, orphans: orphans, unreadable: unreadable)))
                } else {
                    self.hooks.out(InfraOutput.table(machines))
                    if case .ls(true) = self.command {
                        self.hooks.out(InfraOutput.orphans(orphans, unreadable: unreadable))
                    }
                }
                self.finish(0)
            case .infraDoctor(_, let checks):
                self.hooks.out(self.wantsJSON ? CLIOutput.json(checks) : InfraOutput.doctor(checks))
                self.finish(checks.allSatisfy(\.ok) ? 0 : 1)
            case .err(_, let code, let message):
                self.refused(code, message)
            default:
                self.refused("unexpected_reply", nil)
            }
        }
    }

    /// Ctrl-C. During `up` the app carries on creating the machine — a half-created machine
    /// must never be abandoned because its reader went away — so this says how to cancel it.
    func interrupt() {
        guard !finished else { return }
        if case .up(let name) = command {
            hooks.err("flightdeck: still creating \(name) in Flight Deck; `flightdeck infra down \(name)` to cancel")
        }
        finish(130)
    }

    /// Every line of the message, each as `flightdeck: …`: a preflight refusal is one failing
    /// check per line, each with its fix.
    private func refused(_ code: String, _ message: String?) {
        let text = message.flatMap { $0.isEmpty ? nil : $0 } ?? DelegateCommandRunner.line(code: code, message: nil)
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) { hooks.err("flightdeck: \(line)") }
        finish(code.hasPrefix("infra_") ? 125 : 1)
    }

    private func finish(_ status: Int32) {
        guard !finished else { return }
        finished = true
        hooks.finish(status)
    }
}

/// Everything the infra verbs print for a human, as strings.
enum InfraOutput {
    /// `ls --json`: the frame's three parts, by name.
    struct Listing: Encodable {
        let machines: [WireInfraMachine]
        let orphans: [String]
        let unreadable: [String: String]
    }

    /// `NAME CLOUD TYPE STATE NET $/H SPENT TTL`, and a `TOTAL` row once there is more than
    /// nothing to add up. Every dollar figure is an estimate, so spend reads `~$…`.
    static func table(_ machines: [WireInfraMachine]) -> String {
        guard !machines.isEmpty else { return "no cloud machines" }
        var rows = [["NAME", "CLOUD", "TYPE", "STATE", "NET", "$/H", "SPENT", "TTL"]]
        for m in machines {
            rows.append([m.name, m.cloud, m.instanceType.isEmpty ? "module" : m.instanceType, m.state, m.network,
                         m.hourlyUsd.map(usd) ?? "?", "~" + usd(m.spentUsd), span(m.ttlRemaining)])
        }
        let hourly = machines.compactMap(\.hourlyUsd).reduce(0, +)
        rows.append(["TOTAL", "", "", "", "", usd(hourly), "~" + usd(machines.map(\.spentUsd).reduce(0, +)), ""])
        return CLIOutput.columns(rows)
    }

    /// `ls --orphans`' section. "none" only when every account was read: an account that could
    /// not be scanned is said so, by name and why, never folded into an empty list.
    static func orphans(_ orphans: [String], unreadable: [String: String]) -> String {
        var lines: [String] = []
        if !orphans.isEmpty {
            lines.append("orphans (flightdeck infra down --orphan KIND:ID deletes one):")
            lines += orphans.map { "  \($0)" }
        } else if unreadable.isEmpty {
            lines.append("orphans: none")
        }
        for (cloud, why) in unreadable.sorted(by: { $0.key < $1.key }) {
            lines.append("could not scan \(cloud): \(why)")
        }
        return lines.joined(separator: "\n")
    }

    static func doctor(_ checks: [WireInfraCheck]) -> String {
        checks.flatMap { check in
            ["\(check.ok ? "✓" : "✗") \(check.name) — \(check.detail)"] + (check.fix.map { ["  fix: \($0)"] } ?? [])
        }.joined(separator: "\n")
    }

    static func usd(_ value: Double) -> String { String(format: "$%.2f", value) }

    /// Whole minutes, as `InfraService.span` writes them in the cost line: `2h48m`, `0m`.
    static func span(_ seconds: Int) -> String {
        let whole = max(0, seconds) / 60 * 60
        return whole == 0 ? "0m" : HostKit.Duration(seconds: whole).formatted
    }
}
