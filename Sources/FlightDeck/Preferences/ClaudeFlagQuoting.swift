import Foundation

/// The shell-syntax boundary: turning a command-line string into tokens, and a value
/// back into a token that survives the shell.
///
/// This is a security boundary, not a formatting detail. Flag values reach a live pty
/// as part of a command line, so `quoteIfNeeded` must make any value a single literal
/// argument. Quoting — not stripping — is the tool: stripping `$` and backticks out of
/// a `--system-prompt` would corrupt legitimate content.
enum ClaudeFlagQuoting {
    enum TokenizeError: Error, Equatable { case unterminatedQuote }

    /// A word produced by `tokenize`.
    struct Token: Equatable {
        let text: String
        /// True when any part of this token came from inside single or double quotes,
        /// including an empty `''`. The parser uses this to refuse to treat a quoted
        /// token as a flag — which is what makes a value like `--verbose` survive a
        /// round trip instead of reparsing as a different flag.
        let wasQuoted: Bool
    }

    /// Characters safe to emit unquoted. Anything else forces single quotes.
    private static let safe = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_./:=@%+,"
    )

    /// POSIX-ish word splitting. Adjacent quoted and unquoted runs concatenate into one
    /// token (`'a'b` → `ab`), matching `sh`.
    static func tokenize(_ input: String) throws -> [Token] {
        var tokens: [Token] = []
        var current = ""
        var started = false          // distinguishes `''` (a real empty token) from no token
        var quoted = false           // true once any quoted run has contributed to `current`
        var iterator = input.startIndex

        func flush() {
            if started { tokens.append(Token(text: current, wasQuoted: quoted)) }
            current = ""
            started = false
            quoted = false
        }

        while iterator < input.endIndex {
            let character = input[iterator]
            switch character {
            case " ", "\t", "\n", "\r":
                flush()
            case "'":
                started = true
                quoted = true
                iterator = input.index(after: iterator)
                var closed = false
                while iterator < input.endIndex {
                    if input[iterator] == "'" { closed = true; break }
                    current.append(input[iterator])
                    iterator = input.index(after: iterator)
                }
                guard closed else { throw TokenizeError.unterminatedQuote }
            case "\"":
                started = true
                quoted = true
                iterator = input.index(after: iterator)
                var closed = false
                while iterator < input.endIndex {
                    let inner = input[iterator]
                    if inner == "\"" { closed = true; break }
                    if inner == "\\" {
                        let next = input.index(after: iterator)
                        // Only these four are special inside double quotes; a backslash
                        // before anything else is literal, as in sh.
                        if next < input.endIndex, "\"\\$`".contains(input[next]) {
                            current.append(input[next])
                            iterator = input.index(after: next)
                            continue
                        }
                    }
                    current.append(inner)
                    iterator = input.index(after: iterator)
                }
                guard closed else { throw TokenizeError.unterminatedQuote }
            case "\\":
                started = true
                let next = input.index(after: iterator)
                if next < input.endIndex {
                    current.append(input[next])
                    iterator = next
                } else {
                    current.append(character)
                }
            default:
                started = true
                current.append(character)
            }
            if iterator < input.endIndex { iterator = input.index(after: iterator) }
        }
        flush()
        return tokens
    }

    /// Single-quotes `value` when it contains anything outside `safe`, rewriting embedded
    /// `'` as `'\''`. Leaves ordinary values (`opus`, `../dir`) unquoted so the command
    /// field stays readable.
    static func quoteIfNeeded(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let needsQuoting = value.unicodeScalars.contains { !safe.contains($0) }
        guard needsQuoting else { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
