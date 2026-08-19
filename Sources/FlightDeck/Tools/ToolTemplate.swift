import Foundation

/// Expands a tool's command template against one session's context.
///
/// Pure — no `Process`, no SwiftUI, no adapter — so the quoting rules below are assertable
/// without a window, which matters because they are the likeliest place for this feature to be
/// quietly wrong.
enum ToolTemplate {
    static let knownNames: Set<String> = [
        "cwd", "project", "root", "projectName",
        "session", "agent", "conversationID", "transcript", "home",
    ]

    /// Wraps a value so the shell sees exactly one argument.
    ///
    /// Single quotes rather than backslash escaping because inside single quotes the shell
    /// interprets nothing at all — no `$`, no backtick, no glob. The one character that cannot
    /// appear is `'` itself, which is closed, escaped, and reopened.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Substitutes `${name}` for every name in `knownNames`; leaves everything else alone.
    ///
    /// Three behaviours, and they are deliberately different from one another:
    ///
    /// - **A known name with a value** becomes that value, shell-quoted. `$EDITOR ${cwd}` over
    ///   a path containing a space must open one file, not two.
    /// - **A known name with no value** becomes `''`. Emitting nothing would let the command
    ///   silently absorb its *next* argument into the empty position — `code ${transcript}
    ///   ${cwd}` would open the cwd as the transcript. An empty quoted string keeps the
    ///   argument count intact and fails visibly instead.
    /// - **An unknown name** is left literal, braces and all, and reaches the login shell
    ///   unchanged. That is not an oversight: it is what makes `$EDITOR`, `${HOME}` and command
    ///   substitution behave exactly as they would if typed. The cost is that `${cwd}` shadows
    ///   a shell variable of that name, which the preferences pane states.
    static func expand(_ template: String, in context: ToolContext) -> String {
        var out = ""
        var rest = Substring(template)

        while let open = rest.range(of: "${") {
            out += rest[rest.startIndex..<open.lowerBound]

            // An unterminated `${` is a typo, not a variable. Emit it verbatim rather than
            // swallowing the remainder of the command.
            guard let close = rest[open.upperBound...].firstIndex(of: "}") else {
                out += rest[open.lowerBound...]
                return out
            }

            let name = String(rest[open.upperBound..<close])
            if let value = value(for: name, in: context) {
                out += quote(value)
            } else if knownNames.contains(name) {
                out += "''"
            } else {
                out += rest[open.lowerBound...close]
            }
            rest = rest[rest.index(after: close)...]
        }

        return out + rest
    }

    /// nil means either "not a known name" or "known but absent"; `expand` tells them apart
    /// with `knownNames`, because they must produce different output.
    private static func value(for name: String, in context: ToolContext) -> String? {
        switch name {
        case "cwd": return context.workingDirectory
        case "project", "root": return context.projectPath
        case "projectName": return context.projectName
        case "session": return context.sessionTitle
        case "agent": return context.agent.rawValue
        case "conversationID": return context.conversationID.uuidString
        case "transcript": return context.transcriptPath
        case "home": return context.home
        default: return nil
        }
    }
}
