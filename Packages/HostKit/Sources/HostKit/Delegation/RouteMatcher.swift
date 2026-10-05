import Foundation

/// `[[route]]` matching (spec §8): a route's `match` is a glob over the command's argv joined
/// with single spaces, and the first route in file order that matches wins.
///
/// The glob is fnmatch's, without its path special-casing: `*` is any run of characters,
/// spaces and `/` included, because the text is one joined command line, not a path; `?` is
/// one character; `[abc]`, `[a-z]` and `[!x]` (or `[^x]`) are classes; `\` escapes the next
/// character. Nothing is anchored loosely — the whole line must match, so `xcodebuild test *`
/// does not match a bare `xcodebuild test`. That is fnmatch's answer, and a user who knows
/// shell globs predicts it; a "helpful" exception is exactly the kind of rule that routes a
/// command to a remote host when its author did not expect it.
public struct RouteMatcher: Sendable {
    public let routes: [Route]

    public init(routes: [Route]) {
        self.routes = routes
    }

    public init(config: DelegateConfig) {
        self.init(routes: config.routes)
    }

    /// The first route matching `argv`, or nil. `argv[0]` is reduced to its basename first: the
    /// CLI can be handed `/usr/bin/xcodebuild`, and a route is written against the command name
    /// the user types, so a full path must not make a routed command quietly run locally.
    public func match(_ argv: [String]) -> Route? {
        guard let first = argv.first else { return nil }
        let name = first.split(separator: "/").last.map(String.init) ?? first
        let line = ([name] + argv.dropFirst()).joined(separator: " ")
        return routes.first { Self.glob($0.match, matches: line) }
    }

    /// The command names a shim must exist for, sorted and unique: one per route whose first
    /// word is a plain name. A first word that is itself a glob (`*build test`) or a path
    /// (`./run.sh`) names no file a `PATH` lookup would find, so no shim can intercept it;
    /// `DelegateConfig.validate` warns about those rather than this silently dropping them.
    public var commandNames: [String] {
        Array(Set(routes.compactMap { Self.commandName(of: $0.match) })).sorted()
    }

    /// The first space-delimited word of a route's pattern, when it is a plain command name.
    public static func commandName(of pattern: String) -> String? {
        guard let word = pattern.split(separator: " ", omittingEmptySubsequences: true).first
        else { return nil }
        guard !word.contains(where: { "*?[]\\/".contains($0) }) else { return nil }
        // `.` and `..` would be a symlink named for a directory entry, and a control character
        // a file name nobody can see or type — neither is a command a shim can stand in for.
        guard word != ".", word != "..",
              !word.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F })
        else { return nil }
        return String(word)
    }

    /// Whether the whole of `text` matches `pattern`.
    ///
    /// The classic two-pointer matcher with one backtrack point per `*`: on a mismatch it
    /// resumes from the most recent star, consuming one more character. That keeps the worst
    /// case at O(pattern × text); the naive recursive form is exponential in the number of
    /// stars, which a pattern like `*a*a*a…b` turns into a hang inside every shimmed command.
    public static func glob(_ pattern: String, matches text: String) -> Bool {
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
}
