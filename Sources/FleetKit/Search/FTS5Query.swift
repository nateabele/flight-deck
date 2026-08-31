import Foundation

/// Builds the `MATCH` expression for a typed query.
///
/// **Why this is not string interpolation.** FTS5's MATCH argument is a query language, not
/// a literal. `NEAR`, `AND`, `OR`, `NOT`, a leading `-`, a trailing `*` and `:` are all
/// operators in it, and an unbalanced `"` is a syntax error that fails the whole statement.
/// A search field wired straight to MATCH therefore has two failure modes reachable by
/// typing ordinary text: it errors on a quote, and it quietly runs a different query than
/// the one on screen for anything containing a reserved word.
///
/// Quoting every token removes both. Inside an FTS5 string literal the only special
/// character is `"`, escaped by doubling it — exactly like SQL.
///
/// The single `*` this type adds itself, on the final token, is what makes results narrow
/// while you are still typing a word.
public enum FTS5Query {
    public static func match(for input: String) -> String? {
        let tokens = input.split(whereSeparator: \.isWhitespace)
        guard !tokens.isEmpty else { return nil }

        let quoted = tokens.map { token in
            "\"" + token.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        // Only the last token is a prefix. Starring the earlier ones would match far more
        // than the user typed — "fi" would hit "file", "finish", "fix" — and the earlier
        // words in a multi-word query are the ones already finished.
        return quoted.dropLast().joined(separator: " ")
            + (quoted.count > 1 ? " " : "")
            + quoted[quoted.count - 1] + "*"
    }
}
