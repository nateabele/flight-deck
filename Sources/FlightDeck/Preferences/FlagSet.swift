import Foundation

/// The value carried by one `claude` flag. `.on` is a flag with no argument
/// (`--verbose`); `.value` is a single argument (`--model opus`); `.list` is a
/// repeatable or variadic argument (`--add-dir a b`).
enum FlagValue: Equatable, Codable {
    case on
    case value(String)
    case list([String])
}

/// A resolved set of `claude` flags. `values` is keyed by *canonical* flag name
/// (`"--model"`), which is why alias resolution happens in the parser and never
/// downstream.
///
/// `passthrough` holds tokens the catalog does not model, verbatim and in order.
/// It is deliberately unkeyed: preserving unknown text exactly is worth more than
/// being able to merge it per-flag (see the design spec §2).
struct FlagSet: Equatable, Codable {
    var values: [String: FlagValue]
    var passthrough: [String]

    init(values: [String: FlagValue] = [:], passthrough: [String] = []) {
        self.values = values
        self.passthrough = passthrough
    }

    var isEmpty: Bool { values.isEmpty && passthrough.isEmpty }
}

/// A non-fatal note about the text the user typed. Warnings never block saving or
/// launching — the catalog is a snapshot and the user may legitimately be ahead of it.
struct Diagnostic: Equatable {
    enum Severity: Equatable { case warning, error }
    let severity: Severity
    let message: String

    static func warning(_ message: String) -> Diagnostic { .init(severity: .warning, message: message) }
    static func error(_ message: String) -> Diagnostic { .init(severity: .error, message: message) }
}
