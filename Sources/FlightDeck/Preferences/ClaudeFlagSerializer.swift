import Foundation

/// Renders a `FlagSet` back to the editable tail of the command field.
///
/// `passthrough` leads, and catalog flags follow in catalog order. This ordering is
/// load-bearing for the round trip, not cosmetic: a list flag (`--add-dir a b`)
/// greedily consumes every following non-flag token, so a passthrough token placed
/// after it would be swallowed into the list instead of surviving as passthrough.
/// Putting passthrough first means its own run always terminates at the first
/// (unquoted) catalog flag, and no list flag ever has passthrough trailing it to
/// absorb. Do not reorder this back to "passthrough last" — that undoes the fix.
///
/// Order among the catalog flags themselves is catalog order, which makes that part of
/// the output stable and therefore diffable: the field does not reshuffle itself when
/// an unrelated control changes.
///
/// `ClaudeFlagParser.parse(serialize(x)) == x` is the invariant this type exists to hold up.
enum ClaudeFlagSerializer {
    static func serialize(_ flags: FlagSet) -> String {
        // Passthrough must go through `quotedValue`, not bare `quoteIfNeeded`: a
        // passthrough element can be the literal text of a catalog flag name (e.g. the
        // user typed `'--verbose'`), and `isFlag` now refuses to read a quoted token as
        // a flag on reparse. Bare `quoteIfNeeded` leaves `-` unquoted, so `--verbose`
        // would come back out unquoted and reparse as the toggle instead of passthrough.
        var parts: [String] = flags.passthrough.map(quotedValue)

        for spec in ClaudeFlagCatalog.all {
            guard let value = flags.values[spec.canonical] else { continue }
            switch (spec.kind, value) {
            case (.negatable(let off), .value(let state)):
                parts.append(state == "off" ? off : spec.canonical)
            case (_, .on):
                parts.append(spec.canonical)
            case (_, .value(let raw)):
                parts.append(spec.canonical)
                parts.append(quotedValue(raw))
            case (_, .list(let items)):
                // An empty list is parse-producible (`--add-dir` alone yields
                // `.list([])`) and is the state the Preferences UI produces when a
                // list flag is turned on with no values yet, so it must round-trip:
                // emit the bare flag rather than omitting it.
                parts.append(spec.canonical)
                parts.append(contentsOf: items.map(quotedValue))
            }
        }

        return parts.joined(separator: " ")
    }

    /// `quoteIfNeeded` leaves `-` and `=` unquoted because both are safe *inside* a word,
    /// but at the start of one they change meaning: a leading `-` reparses as a flag, and
    /// a leading `=` triggers zsh's equals-expansion, which aborts the whole command line
    /// when it fails to resolve. Force quotes for exactly those two cases, delegating to
    /// `ClaudeSession.shellQuoted` for the actual POSIX single-quoting so there is one
    /// implementation of that logic rather than two byte-identical copies.
    private static func quotedValue(_ raw: String) -> String {
        guard raw.hasPrefix("-") || raw.hasPrefix("=") else {
            return ClaudeFlagQuoting.quoteIfNeeded(raw)
        }
        return ClaudeSession.shellQuoted(raw)
    }
}
