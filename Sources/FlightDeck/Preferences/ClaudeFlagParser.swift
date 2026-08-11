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

        // Consumes the inline `--flag=value` form, else the next token when it is not
        // itself a flag. Returns nil when neither is available.
        func takeInlineOrNext(_ inlineValue: String?) -> FlagValue? {
            if let inlineValue { return .value(inlineValue) }
            if index < tokens.count, !isFlag(tokens[index]) {
                defer { index += 1 }
                return .value(tokens[index])
            }
            return nil
        }

        func rejectToPassthrough(token: String, inlineValue: String?, message: String) {
            diagnostics.append(.warning(message))
            flags.passthrough.append(inlineValue.map { "\(token)=\($0)" } ?? token)
            flags.passthrough.append(contentsOf: takeValues())
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
                rejectToPassthrough(
                    token: token, inlineValue: inlineValue,
                    message: "\(token) is managed by Flight Deck and cannot be set here."
                )
                continue
            }

            guard let spec = ClaudeFlagCatalog.spec(for: token) else {
                rejectToPassthrough(
                    token: token, inlineValue: inlineValue,
                    message: "\(token) is not a known claude option. It will still be passed through."
                )
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
                record(spec.canonical, takeInlineOrNext(inlineValue) ?? .on)

            case .choice, .string, .multiline, .path:
                if let value = takeInlineOrNext(inlineValue) {
                    record(spec.canonical, value)
                } else {
                    diagnostics.append(.warning("\(spec.canonical) needs a value; it was ignored."))
                }
            }
        }

        return ParseResult(flags: flags, diagnostics: diagnostics)
    }
}
