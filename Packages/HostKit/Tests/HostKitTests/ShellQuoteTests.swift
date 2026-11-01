import XCTest
@testable import HostKit

/// Every word here goes through a REAL shell and must come back byte for byte. The words are the
/// ones that differ between POSIX shells and fish: fish reads `\\` and `\'` inside single quotes
/// as escapes, a POSIX shell does not (measured, fish 4.8.0: `'a\\b'` arrives as `a\b`, and
/// `'a\'b'` is a parse error).
final class ShellQuoteTests: XCTestCase {
    private static let words = [
        #"a\\b"#, #"a\'b"#, #"a\b"#, #"\"#, #"\\"#, #"\'"#, "'", "''", "it's", "x y", "  ", "",
        "$HOME", "$(no)", "`no`", "(echo hi)", "a\nb", "tab\there", #"a\nb"#, "~", "*", "?", "#x",
        "\"q\"", "a;b", "a&&b", "ünï", "-n", #"'\"#, #"\'\"#,
    ]

    /// A shell that is installed, or the test is skipped.
    private func shell(_ name: String) throws -> String {
        guard let path = installed(name) else { throw XCTSkip("\(name) is not installed") }
        return path
    }

    private func installed(_ name: String) -> String? {
        ["/bin", "/usr/bin", "/usr/local/bin", "/opt/homebrew/bin"]
            .map { "\($0)/\(name)" }
            .first(where: FileManager.default.isExecutableFile)
    }

    /// Runs `executable`, whose output is NUL-terminated fields.
    private func run(_ executable: String, _ arguments: [String]) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "\(executable) \(arguments)")
        var fields = String(decoding: data, as: UTF8.self).components(separatedBy: "\0")
        XCTAssertEqual(fields.last, "", "output ends with a NUL")
        fields.removeLast()
        return fields
    }

    /// The quoted words as the arguments of `printf '%s\0'`, parsed by `shell`.
    private func roundTrip(_ quote: (String) -> String, through shell: String) throws -> [String] {
        let text = #"printf '%s\0' "# + Self.words.map(quote).joined(separator: " ")
        return try run(shell, ["-c", text])
    }

    func testQuotedWordsRoundTripThroughPOSIXShells() throws {
        _ = try shell("sh")
        for name in ["sh", "bash", "zsh", "dash"] {
            guard let path = installed(name) else { continue }
            XCTAssertEqual(try roundTrip(ShellQuote.quoted, through: path), Self.words, name)
            XCTAssertEqual(try roundTrip(ShellQuote.word, through: path), Self.words, "\(name) (bare words)")
        }
    }

    func testQuotedWordsRoundTripThroughFish() throws {
        let fish = try shell("fish")
        XCTAssertEqual(try roundTrip(ShellQuote.quoted, through: fish), Self.words)
        XCTAssertEqual(try roundTrip(ShellQuote.word, through: fish), Self.words, "bare words")
    }

    func testQuotingOnlyTheApostropheIsWhatBrokeFish() throws {
        // The regression this type exists for, pinned: POSIX-only quoting (just `'` as `'\''`)
        // loses a backslash under fish. If fish ever stops reading `\\` as an escape inside
        // quotes, this fails and the backslash case in `quoted` can go.
        let fish = try shell("fish")
        XCTAssertEqual(try run(fish, ["-c", #"printf '%s\0' 'a\\b'"#]), [#"a\b"#])
    }

    func testTheQuotedFormsAreExact() {
        XCTAssertEqual(ShellQuote.quoted("it's"), #"'it'\''s'"#)
        XCTAssertEqual(ShellQuote.quoted(#"a\b"#), #"'a'\\'b'"#)
        XCTAssertEqual(ShellQuote.quoted(""), "''")
        XCTAssertEqual(ShellQuote.word("make"), "make")
        XCTAssertEqual(ShellQuote.word("My App"), "'My App'")
        XCTAssertEqual(ShellQuote.word(""), "''")
        XCTAssertEqual(ShellQuote.word("-scheme"), "-scheme")
    }

    // MARK: - argv through the login shell

    /// Runs `/usr/bin/printf '%s\0' <words>` the way `Spawner` hands a run to `shell`, with
    /// `-lc` as `-c` so a login profile cannot print into the output.
    private func runArgv(through shell: String, prefix: String? = nil) throws -> [String] {
        let program = prefix == nil ? ["/usr/bin/printf", #"%s\0"#] : []
        let argv = LoginShellArgv.make(shell: shell, command: "unused", words: program + Self.words, prefix: prefix)
        XCTAssertEqual(argv[1], "-lc")
        return try run(argv[0], ["-c"] + argv.dropFirst(2))
    }

    func testPositionalWordsReachTheProcessUnparsedThroughEachShell() throws {
        _ = try shell("sh")
        for name in ["sh", "bash", "zsh", "dash", "fish"] {
            guard let path = installed(name) else { continue }
            XCTAssertEqual(try runArgv(through: path), Self.words, name)
        }
    }

    func testAPrefixIsShellTextAndTheWordsFollowItUnparsed() throws {
        _ = try shell("sh")
        for name in ["sh", "zsh", "fish"] {
            guard let path = installed(name) else { continue }
            XCTAssertEqual(try runArgv(through: path, prefix: #"/usr/bin/printf '%s\0'"#), Self.words, name)
        }
    }

    func testAnUnknownLoginShellKeepsTheShellText() {
        XCTAssertEqual(LoginShellArgv.make(shell: "/bin/tcsh", command: "a 'b c'", words: ["a", "b c"], prefix: nil),
                       ["/bin/tcsh", "-lc", "a 'b c'"])
        XCTAssertEqual(LoginShellArgv.make(shell: "/bin/zsh", command: "x", words: nil, prefix: nil),
                       ["/bin/zsh", "-lc", "x"])
        XCTAssertEqual(LoginShellArgv.make(shell: "/usr/bin/fish", command: "x", words: ["a"], prefix: nil),
                       ["/usr/bin/fish", "-lc", "exec $argv", "a"])
        XCTAssertEqual(LoginShellArgv.make(shell: "/bin/bash", command: "x", words: ["a"], prefix: "make"),
                       ["/bin/bash", "-lc", #"make "$@""#, "flightdeck-run", "a"])
    }
}
