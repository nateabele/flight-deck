import Foundation

/// Turns the editable tail of the command field into a `FlagSet`.
///
/// The passthrough rule is deliberately simple and therefore predictable: an unrecognized
/// token that looks like a flag, plus every following non-flag token, is copied verbatim
/// into `passthrough`. We cannot know whether an unknown flag takes a value, so we keep
/// the whole run rather than guessing and corrupting it.
enum ClaudeFlagParser {
    struct ParseResult: Equatable {
        var flags: FlagSet
        var diagnostics: [Diagnostic]
    }

    static func parse(_ input: String) -> ParseResult {
        let tokens: [String]
        do {
            tokens = try ClaudeFlagQuoting.tokenize(input)
        } catch {
            return ParseResult(
                flags: FlagSet(),
                diagnostics: [.error("Unterminated quote — fix the quoting to apply these options.")]
            )
        }

        var flags = FlagSet()
        var diagnostics: [Diagnostic] = []
        var seen: Set<String> = []
        var index = 0

        func isFlag(_ token: String) -> Bool { token.hasPrefix("-") && token != "-" }

        /// Consumes following tokens until the next flag.
        func takeValues() -> [String] {
            var values: [String] = []
            while index < tokens.count, !isFlag(tokens[index]) {
                values.append(tokens[index])
                index += 1
            }
            return values
        }

        func record(_ canonical: String, _ value: FlagValue) {
            if seen.contains(canonical) {
                diagnostics.append(.warning("\(canonical) is specified more than once; the last value wins."))
            }
            seen.insert(canonical)
            flags.values[canonical] = value
        }

        while index < tokens.count {
            var token = tokens[index]
            index += 1

            guard isFlag(token) else {
                flags.passthrough.append(token)
                continue
            }

            // Split `--flag=value` before lookup.
            var inlineValue: String?
            if let equals = token.firstIndex(of: "="), token.hasPrefix("-") {
                inlineValue = String(token[token.index(after: equals)...])
                token = String(token[..<equals])
            }

            if ClaudeFlagCatalog.appManaged.contains(token) {
                diagnostics.append(.warning("\(token) is managed by Flight Deck and cannot be set here."))
                flags.passthrough.append(inlineValue.map { "\(token)=\($0)" } ?? token)
                flags.passthrough.append(contentsOf: takeValues())
                continue
            }

            guard let spec = ClaudeFlagCatalog.spec(for: token) else {
                diagnostics.append(.warning("\(token) is not a known claude option. It will still be passed through."))
                flags.passthrough.append(inlineValue.map { "\(token)=\($0)" } ?? token)
                flags.passthrough.append(contentsOf: takeValues())
                continue
            }

            switch spec.kind {
            case .toggle:
                record(spec.canonical, .on)

            case .negatable(let off):
                record(spec.canonical, .value(token == off ? "off" : "on"))

            case .list:
                var values = inlineValue.map { [$0] } ?? []
                values.append(contentsOf: takeValues())
                // Repetition accumulates rather than replacing, matching `claude`.
                if case .list(let existing)? = flags.values[spec.canonical] {
                    flags.values[spec.canonical] = .list(existing + values)
                } else {
                    record(spec.canonical, .list(values))
                }

            case .optionalValue:
                if let inlineValue {
                    record(spec.canonical, .value(inlineValue))
                } else if index < tokens.count, !isFlag(tokens[index]) {
                    record(spec.canonical, .value(tokens[index]))
                    index += 1
                } else {
                    record(spec.canonical, .on)
                }

            case .choice, .string, .multiline, .path:
                if let inlineValue {
                    record(spec.canonical, .value(inlineValue))
                } else if index < tokens.count, !isFlag(tokens[index]) {
                    record(spec.canonical, .value(tokens[index]))
                    index += 1
                } else {
                    diagnostics.append(.warning("\(spec.canonical) needs a value; it was ignored."))
                }
            }
        }

        return ParseResult(flags: flags, diagnostics: diagnostics)
    }
}
