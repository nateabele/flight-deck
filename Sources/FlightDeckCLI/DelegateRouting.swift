import Darwin
import FleetKit
import Foundation

/// `flightdeck route-exec <argv0> -- <args…>` (spec §8): what a routing shim runs. It either
/// delegates the command through a matching `[[route]]`, or runs the real binary as if no shim
/// were there. Every fall-through path must reach the real binary: a shim that fails closed
/// turns "Flight Deck is not running" into "`xcodebuild` is broken" in every tab.
enum DelegateRouting {
    /// The name the shim was invoked as. A shim is reached through `PATH`, so argv0 is usually
    /// bare already; a path is cut to its last component so the routes and the `PATH` search
    /// both see `xcodebuild`, never `/…/shims/xcodebuild`.
    static func commandName(_ argv0: String) -> String {
        (argv0 as NSString).lastPathComponent
    }

    /// The recipe of the first route whose glob matches the joined argv (§8), by HostKit's
    /// `RouteMatcher` rule: argv0 cut to its basename, then `glob` below over the line.
    ///
    /// The app routes with `RouteMatcher` itself; this CLI does not link HostKit, so the glob
    /// is a copy, held to the same answers by `DelegationRouteParityTests`. Were the two to
    /// disagree, a command the app would route could run locally, or the other way about.
    static func recipe(for argv: [String], in routes: [WireRoute]) -> String? {
        guard let first = argv.first else { return nil }
        let line = ([commandName(first)] + argv.dropFirst()).joined(separator: " ")
        return routes.first { glob($0.match, matches: line) }?.recipe
    }

    // MARK: Glob — a copy of HostKit's `RouteMatcher.glob`; see `recipe(for:in:)`.

    static func glob(_ pattern: String, matches text: String) -> Bool {
        let tokens = tokenize(pattern)
        let chars = Array(text)
        var t = 0, c = 0
        var star: (token: Int, char: Int)?
        while c < chars.count {
            if t < tokens.count, tokens[t] != .star, tokens[t].accepts(chars[c]) {
                t += 1
                c += 1
            } else if t < tokens.count, tokens[t] == .star {
                star = (t, c)
                t += 1
            } else if let last = star {
                t = last.token + 1
                c = last.char + 1
                star = (last.token, last.char + 1)
            } else {
                return false
            }
        }
        while t < tokens.count, tokens[t] == .star { t += 1 }
        return t == tokens.count
    }

    private enum Token: Equatable {
        case literal(Character)
        case any
        case star
        case set(members: [ClosedRange<Character>], negated: Bool)

        func accepts(_ char: Character) -> Bool {
            switch self {
            case .literal(let literal): literal == char
            case .any: true
            case .star: false
            case .set(let members, let negated): members.contains { $0.contains(char) } != negated
            }
        }
    }

    private static func tokenize(_ pattern: String) -> [Token] {
        let chars = Array(pattern)
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            switch chars[i] {
            case "*":
                // Consecutive stars are one star; collapsing them keeps the backtracking
                // above from revisiting the same split points once per redundant star.
                if tokens.last != .star { tokens.append(.star) }
                i += 1
            case "?":
                tokens.append(.any)
                i += 1
            case "\\" where i + 1 < chars.count:
                tokens.append(.literal(chars[i + 1]))
                i += 2
            case "[":
                if let (set, next) = parseSet(chars, from: i) {
                    tokens.append(set)
                    i = next
                } else {
                    // An unclosed `[` is a literal, as in fnmatch: a typo in a route must not
                    // make the whole file unusable.
                    tokens.append(.literal("["))
                    i += 1
                }
            default:
                tokens.append(.literal(chars[i]))
                i += 1
            }
        }
        return tokens
    }

    /// `[…]` starting at `start`, and the index after its `]`; nil when it never closes.
    private static func parseSet(_ chars: [Character], from start: Int) -> (Token, Int)? {
        var i = start + 1
        var negated = false
        if i < chars.count, chars[i] == "!" || chars[i] == "^" {
            negated = true
            i += 1
        }
        var members: [ClosedRange<Character>] = []
        var first = true
        while i < chars.count {
            // A `]` straight after the opening (or its `!`) is a member, not the close: the
            // only way to put `]` in a class, in fnmatch as here.
            if chars[i] == "]" && !first { return (.set(members: members, negated: negated), i + 1) }
            first = false
            let low = chars[i]
            if i + 2 < chars.count, chars[i + 1] == "-", chars[i + 2] != "]", low <= chars[i + 2] {
                members.append(low...chars[i + 2])
                i += 3
            } else {
                members.append(low...low)
                i += 1
            }
        }
        return nil
    }



    /// The real binary for `name`: the first executable on `path` outside the shim directory.
    /// Without excluding it the shim would find itself and exec itself forever.
    static func resolve(_ name: String, path: String, shimDir: String?) -> String? {
        let shim = shimDir.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        for entry in path.split(separator: ":").map(String.init) where !entry.isEmpty {
            if let shim, URL(fileURLWithPath: entry).standardizedFileURL.path == shim { continue }
            let candidate = (entry as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Puts back the default action for the signals this CLI catches or ignores. An ignored
    /// signal stays ignored across `exec`, so without this the real `xcodebuild` would shrug
    /// off Ctrl-C and `kill`, and SIGPIPE would turn into EPIPE errors it never expects.
    static func resetSignals() {
        for sig in [SIGINT, SIGQUIT, SIGTERM, SIGPIPE] { signal(sig, SIG_DFL) }
    }

    /// Replaces this process with the real binary. Returns only when it could not: 127 when
    /// nothing on `PATH` has the name, as a shell would, or 126 when the exec itself failed.
    static func execReal(_ argv0: String, _ args: [String], environment: [String: String]) -> Int32 {
        let name = commandName(argv0)
        guard let real = resolve(name, path: environment["PATH"] ?? "", shimDir: environment["FLIGHTDECK_SHIM_DIR"]) else {
            FileHandle.standardError.write(Data("flightdeck: \(name): command not found\n".utf8))
            return 127
        }
        let argv = ([name] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        resetSignals()
        execv(real, argv)
        FileHandle.standardError.write(Data("flightdeck: \(real): \(String(cString: strerror(errno)))\n".utf8))
        return 126
    }
}
