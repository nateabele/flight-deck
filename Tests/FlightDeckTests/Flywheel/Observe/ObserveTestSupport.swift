@testable import FlightDeck

/// One fake `FlywheelProcessRunner` shared by every Observe test. Answers different
/// stdout per executable+subcommand so a single fake serves all lanes; records argv.
/// Non-`private` because Tasks 2, 6, 7, and 12 all drive their reads through this same
/// fake from separate test files, and a `private` type is invisible across files in the
/// test target.
final class MultiRunner: FlywheelProcessRunner, @unchecked Sendable {
    /// keyed by the joined argv prefix that identifies the call, e.g. "am agents list"
    var responses: [String: (String, Int32)] = [:]
    private(set) var argv: [[String]] = []
    func run(_ exe: String, _ args: [String], cwd: String?) async throws -> (stdout: String, exitCode: Int32) {
        argv.append([exe] + args)
        let key = ([exe] + args.prefix(2)).joined(separator: " ")
        return responses[key] ?? ("", 127)   // 127 = command not found by default
    }
}
