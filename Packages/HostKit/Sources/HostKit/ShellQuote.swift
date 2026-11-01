import Foundation

/// Quoting for text that a shell will parse, and that must mean the same thing to every shell
/// we meet: sh, bash and zsh, and fish.
///
/// POSIX single quotes are not enough. Inside `'…'` a POSIX shell interprets nothing, but fish
/// still treats `\\` and `\'` as escapes, so `'a\\b'` reaches a fish host as `a\b` and `'a\'b'`
/// is a parse error. The two grammars agree everywhere else, and they agree on a backslash
/// *outside* quotes: `\\` is one backslash and `\'` one quote in both. So a word is single-quoted
/// except for `'` and `\`, which are written unquoted and escaped:
/// `it's` -> `'it'\''s'`, `a\b` -> `'a'\\'b'`.
public enum ShellQuote {
    /// Characters a word can contain and stay bare.
    private static let bareSafe = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "@%_+=:,./-"))

    /// `value` as exactly one shell word, always quoted (the empty string is `''`).
    public static func quoted(_ value: String) -> String {
        var out = "'"
        for character in value {
            switch character {
            case "'": out += #"'\''"#
            case "\\": out += #"'\\'"#
            default: out.append(character)
            }
        }
        return out + "'"
    }

    /// `word` as one shell word, left bare when nothing in it needs quoting so a command stays
    /// readable (`xcodebuild -scheme 'My App'`).
    public static func word(_ word: String) -> String {
        if !word.isEmpty, word.unicodeScalars.allSatisfy(bareSafe.contains) { return word }
        return quoted(word)
    }
}
