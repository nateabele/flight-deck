import FleetKit
import Foundation

/// A parsed delegation verb (spec §5). Run-shaped verbs carry a `WireDelegateRun` whose `cwd`
/// and terminal size are left empty here and filled in by the runner, which knows the process
/// it runs in; everything else is exactly what goes on the wire.
public enum DelegateCommand: Equatable {
    case run(WireDelegateRun)
    case exec(WireDelegateRun)
    case up(WireDelegateRun)
    case down(String)
    case restart(String)
    case sync(String)
    case ps
    /// `from`: resume the output at that byte offset (`--from`); nil replays it all.
    case wait(run: String, timeout: Int?, from: Int64?)
    case logs(run: String, follow: Bool, from: Int64?)
    case stop(String)
    case diff(String)
    case apply(String)
    case recipeList
    case recipeAdd(WireRecipe)
    case recipeCheck
    /// `host ls --disk`; nil asks every paired host.
    case hostDisk(host: String?)
    /// `host prune <host> [--repo R]`.
    case hostPrune(host: String, repo: String?)
    /// The routing shim's entry point (§8): `route-exec <argv0> -- <args…>`.
    case routeExec(argv0: String, args: [String])

    /// The request for this command, run from `cwd`. Nil for `route-exec`, which first has to
    /// decide whether it delegates at all, and for `host ls --disk` across every host.
    func request(cwd: String, columns: Int?, rows: Int?) -> DelegateRequest? {
        func located(_ run: WireDelegateRun) -> WireDelegateRun {
            var run = run
            run.cwd = cwd
            // Sized only for `--pty`: a pipe-run command has no terminal to match.
            if run.pty { run.columns = columns; run.rows = rows }
            return run
        }
        switch self {
        case .run(let run): return .run(located(run))
        case .exec(let run): return .exec(located(run))
        case .up(let run): return .up(located(run))
        case .down(let service): return .down(service: service, cwd: cwd)
        case .restart(let service): return .restart(service: service, cwd: cwd)
        case .sync(let service): return .sync(service: service, cwd: cwd)
        case .ps: return .ps
        case .wait(let run, let timeout, let from): return .wait(run: run, timeout: timeout, from: from)
        case .logs(let run, let follow, let from): return .logs(run: run, follow: follow, from: from)
        case .stop(let run): return .stop(run: run)
        case .diff(let run): return .diff(run: run)
        case .apply(let run): return .apply(run: run)
        case .recipeList: return .recipeList(cwd: cwd)
        case .recipeAdd(let recipe): return .recipeAdd(cwd: cwd, name: recipe.name, recipe: recipe)
        case .recipeCheck: return .recipeCheck(cwd: cwd)
        case .hostDisk(let host?): return .hostDisk(host: host)
        case .hostPrune(let host, let repo): return .hostPrune(host: host, repo: repo)
        case .routeExec, .hostDisk(nil): return nil
        }
    }
}

enum DelegateArguments {
    /// A delegated run's id as the app mints it (`RunRegistry.mintID`): `r` and digits.
    static func isRunID(_ token: String) -> Bool {
        token.count > 1 && token.first == "r" && token.dropFirst().allSatisfy { $0.isASCII && $0.isNumber }
    }

    static func parse(_ verb: String, _ c: inout CLIArguments.Cursor) throws -> DelegateCommand {
        switch verb {
        case "run", "exec", "up":
            // `run RECIPE [-- extra]` or `run [flags] -- cmd…`: the recipe is the one operand
            // allowed before `--`, and everything after it is argv, never flags.
            let recipe = c.positionalBeforeLiteral()
            if verb == "exec", let recipe {
                throw CLIUsageError("exec: takes no recipe (got \"\(recipe)\"); exec --on H -- cmd…")
            }
            var run = WireDelegateRun(cwd: "", recipe: recipe)
            while let flag = c.nextFlag() {
                switch flag {
                case "--on": run.host = try c.require(after: flag)
                case "--include": run.include.append(try c.require(after: flag))
                case "--fetch": run.fetch.append(try c.require(after: flag))
                case "--port": run.ports.append(try c.require(after: flag))
                case "--env":
                    let (key, value) = try env(try c.require(after: flag), verb: verb)
                    run.env[key] = value
                case "--pty": run.pty = true
                case "--screen": run.screen = true
                case "--detach" where verb != "up": run.detach = true
                default: throw CLIArguments.Cursor.unknownFlag(flag, in: verb)
                }
            }
            run.command = try c.literalTail(verb: verb)
            if run.recipe == nil, run.command.isEmpty {
                throw CLIUsageError("\(verb): nothing to run — give a recipe, or the command after --")
            }
            switch verb {
            case "run": return .run(run)
            case "exec": return .exec(run)
            default: return .up(run)
            }

        case "down", "restart", "sync":
            let service = try c.requirePositional("\(verb): missing service (a run id or recipe name)")
            switch verb {
            case "down": return .down(service)
            case "restart": return .restart(service)
            default: return .sync(service)
            }

        case "ps":
            return .ps

        case "logs":
            let run = try c.requirePositional("logs: missing run")
            var follow = false
            var from: Int64?
            while let flag = c.nextFlag() {
                switch flag {
                case "--follow", "-f": follow = true
                case "--from": from = Int64(try c.int(after: flag))
                default: throw CLIArguments.Cursor.unknownFlag(flag, in: "logs")
                }
            }
            return .logs(run: run, follow: follow, from: from)

        case "stop":
            return .stop(try c.requirePositional("stop: missing run"))
        case "diff":
            return .diff(try c.requirePositional("diff: missing run"))
        case "apply":
            return .apply(try c.requirePositional("apply: missing run"))

        case "recipe":
            return try parseRecipe(&c)

        case "route-exec":
            let argv0 = try c.requirePositional("route-exec: missing argv0")
            return .routeExec(argv0: argv0, args: try c.literalTail(verb: "route-exec"))

        default:
            throw CLIUsageError("unknown command \"\(verb)\"")
        }
    }

    private static func parseRecipe(_ c: inout CLIArguments.Cursor) throws -> DelegateCommand {
        let sub = try c.requirePositional("recipe: missing subcommand (ls, add or check)")
        switch sub {
        case "ls": return .recipeList
        case "check": return .recipeCheck
        case "add":
            let name = try c.requirePositional("recipe add: missing name")
            var recipe = WireRecipe(name: name, run: "")
            var run: String?
            while let flag = c.nextFlag() {
                switch flag {
                case "--run": run = try c.require(after: flag)
                case "--host": recipe.host = try c.require(after: flag)
                case "--down": recipe.down = try c.require(after: flag)
                case "--screen": recipe.screen = true
                case "--long": recipe.long = true
                case "--service": recipe.service = true
                case "--restart-on-sync": recipe.restartOnSync = true
                case "--fetch": recipe.fetch.append(try c.require(after: flag))
                case "--port": recipe.ports.append(try c.require(after: flag))
                case "--env":
                    let (key, value) = try env(try c.require(after: flag), verb: "recipe add")
                    recipe.env[key] = value
                case "--apply":
                    let apply = try c.require(after: flag)
                    guard apply == "review" || apply == "auto" else {
                        throw CLIUsageError("recipe add: --apply must be review or auto, got \"\(apply)\"")
                    }
                    recipe.apply = apply
                case "--pool": recipe.pool = try c.int(after: flag)
                default: throw CLIArguments.Cursor.unknownFlag(flag, in: "recipe add")
                }
            }
            guard let run else { throw CLIUsageError("recipe add: --run CMD is required") }
            recipe.run = run
            return .recipeAdd(recipe)
        default:
            throw CLIUsageError("recipe: unknown subcommand \"\(sub)\"")
        }
    }

    private static func env(_ pair: String, verb: String) throws -> (String, String) {
        guard let eq = pair.firstIndex(of: "="), eq != pair.startIndex else {
            throw CLIUsageError("\(verb): --env expects KEY=VALUE, got \"\(pair)\"")
        }
        return (String(pair[..<eq]), String(pair[pair.index(after: eq)...]))
    }
}
