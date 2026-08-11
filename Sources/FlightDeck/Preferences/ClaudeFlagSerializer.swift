import Foundation

/// Renders a `FlagSet` back to the editable tail of the command field.
///
/// Order is catalog order, which makes output stable and therefore diffable: the field
/// does not reshuffle itself when an unrelated control changes. `passthrough` is appended
/// last, verbatim.
///
/// `ClaudeFlagParser.parse(serialize(x)) == x` is the invariant this type exists to hold up.
enum ClaudeFlagSerializer {
    static func serialize(_ flags: FlagSet) -> String {
        var parts: [String] = []

        for spec in ClaudeFlagCatalog.all {
            guard let value = flags.values[spec.canonical] else { continue }
            switch (spec.kind, value) {
            case (.negatable(let off), .value(let state)):
                parts.append(state == "off" ? off : spec.canonical)
            case (_, .on):
                parts.append(spec.canonical)
            case (_, .value(let raw)):
                parts.append(spec.canonical)
                parts.append(ClaudeFlagQuoting.quoteIfNeeded(raw))
            case (_, .list(let items)):
                guard !items.isEmpty else { continue }
                parts.append(spec.canonical)
                parts.append(contentsOf: items.map(ClaudeFlagQuoting.quoteIfNeeded))
            }
        }

        parts.append(contentsOf: flags.passthrough.map(ClaudeFlagQuoting.quoteIfNeeded))
        return parts.joined(separator: " ")
    }
}
