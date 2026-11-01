import XCTest
@testable import FlightDeck

/// The app's own quoting helpers, through REAL shells. fish reads `\\` and `\'` inside single
/// quotes as escapes and a POSIX shell does not, so each helper has to produce text both read
/// the same way. `ShellQuoteTests` in HostKit covers the primitive; this covers the call sites
/// that build a typed command line (`ClaudeSession`, `ClaudeFlagQuoting`, `ToolTemplate`).
final class ShellQuotingTests: XCTestCase {
    private static let words = [
        #"a\\b"#, #"a\'b"#, #"a\b"#, "it's", "x y", "$HOME", "$(no)", "a\nb", "", #"'\"#, "plain",
    ]

    private func shells() -> [String] {
        ["/bin/sh", "/bin/bash", "/bin/zsh", "/opt/homebrew/bin/fish", "/usr/local/bin/fish"]
            .filter(FileManager.default.isExecutableFile)
    }

    private func roundTrip(_ quote: (String) -> String, through shell: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = ["-c", #"printf '%s\0' "# + Self.words.map(quote).joined(separator: " ")]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var fields = String(decoding: data, as: UTF8.self).components(separatedBy: "\0")
        fields.removeLast()
        return fields
    }

    func testEveryQuotingHelperRoundTripsThroughPOSIXShellsAndFish() throws {
        let helpers: [(String, (String) -> String)] = [
            ("ClaudeSession.shellQuoted", ClaudeSession.shellQuoted),
            ("ClaudeFlagQuoting.quoteIfNeeded", ClaudeFlagQuoting.quoteIfNeeded),
            ("ToolTemplate.quote", ToolTemplate.quote),
        ]
        let available = shells()
        XCTAssertTrue(available.contains("/bin/sh"))
        for shell in available {
            for (name, quote) in helpers {
                XCTAssertEqual(try roundTrip(quote, through: shell), Self.words, "\(name) under \(shell)")
            }
        }
        if !available.contains(where: { $0.hasSuffix("/fish") }) { print("fish is not installed: fish half skipped") }
    }

    func testTheFlagTokenizerReadsBackWhatTheQuoterWrote() throws {
        for word in Self.words {
            let tokens = try ClaudeFlagQuoting.tokenize(ClaudeFlagQuoting.quoteIfNeeded(word))
            XCTAssertEqual(tokens.map(\.text), [word])
        }
    }
}
