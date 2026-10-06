import XCTest
@testable import FlightDeck

/// The per-shell snippets that keep a tab's route-shim directory first on `PATH` after a login
/// shell's startup files have pushed it down (`RouteShims.shellIntegration`). Each test runs
/// the real shell as a login shell, with a throwaway `HOME` whose dotfiles prepend to `PATH`
/// the way real ones do, and the environment Flight Deck launches a tab with. A shell that is
/// not installed is skipped.
final class RouteShimShellTests: XCTestCase {
    /// The snippets as checked in: under xctest `Bundle.main` is the test tool, not the app.
    private static let integration = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/RouteShim", isDirectory: true)

    private var temp: URL!
    private var home: URL!
    /// A space in it, as "Application Support/Flight Deck" has.
    private var shim: URL!

    override func setUpWithError() throws {
        temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("route shell \(UUID().uuidString)").resolvingSymlinksInPath()
        home = temp.appendingPathComponent("home")
        shim = temp.appendingPathComponent("route shims/session")
        for dir in [home!, shim!, home.appendingPathComponent(".config/fish")] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temp)
    }

    private func dotfile(_ name: String, _ text: String) throws {
        try text.write(to: home.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// What a tab is launched with: the shim directory first on `PATH`, then the integration.
    private func tabEnvironment(shimDir: Bool = true, extra: [String: String] = [:]) -> [String: String] {
        var env = ["HOME": home.path, "USER": NSUserName(), "TERM": "dumb", "PATH": "\(shim.path):/usr/bin:/bin"]
        for (key, value) in extra { env[key] = value }
        if shimDir { env[DelegationBootstrap.shimDirVariable] = shim.path }
        return RouteShims.shellIntegration(env, integration: Self.integration, inherited: [:])
    }

    /// Runs `shell` with `arguments` and `stdin`, and returns the `PATH=` line it printed.
    private func path(_ shell: String, _ arguments: [String], stdin: String? = nil,
                      environment: [String: String]) throws -> [String] {
        guard FileManager.default.isExecutableFile(atPath: shell) else { throw XCTSkip("\(shell) is not installed") }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = home
        let out = Pipe()
        let input = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = input
        try process.run()
        if let stdin { try input.fileHandleForWriting.write(contentsOf: Data(stdin.utf8)) }
        try input.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard let line = text.split(separator: "\n").last(where: { $0.hasPrefix("PATH=") }) else {
            XCTFail("no PATH= line from \(shell): \(text)")
            return []
        }
        return line.dropFirst("PATH=".count).split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    }

    private static let fish = "/opt/homebrew/bin/fish"

    private func fishPath(_ environment: [String: String]) throws -> [String] {
        let shell = [Self.fish, "/usr/local/bin/fish"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? Self.fish
        return try path(shell, ["-l", "-c", "echo PATH=(string join : $PATH)"], environment: environment)
    }

    private func zshPath(_ environment: [String: String], interactive: Bool = true) throws -> [String] {
        try path("/bin/zsh", ["-l"] + (interactive ? ["-i"] : []) + ["-c", "echo PATH=$PATH"], environment: environment)
    }

    /// Interactive with commands on stdin, so a prompt (and `PROMPT_COMMAND`) comes first.
    private func bashPath(_ environment: [String: String]) throws -> [String] {
        try path("/bin/bash", ["-l", "-i"], stdin: "echo PATH=$PATH\nexit\n", environment: environment)
    }

    // MARK: fish

    func testFishKeepsTheShimDirectoryFirst() throws {
        try dotfile(".config/fish/config.fish", "set -gx PATH /user/a /user/b $PATH\n")
        let path = try fishPath(tabEnvironment())
        XCTAssertEqual(path.first, shim.path, "\(path)")
        XCTAssertEqual(Array(path.dropFirst().prefix(2)), ["/user/a", "/user/b"], "the user's edits keep their order")
    }

    func testFishMovesNothingWithoutAShimDir() throws {
        try dotfile(".config/fish/config.fish", "set -gx PATH /user/a $PATH\n")
        let plain = try fishPath(["HOME": home.path, "TERM": "dumb", "PATH": "\(shim.path):/usr/bin:/bin"])
        XCTAssertEqual(try fishPath(tabEnvironment(shimDir: false)), plain)
        XCTAssertNotEqual(plain.first, shim.path, "the push-down this all exists for")
    }

    /// The other vendor directories fish reads by default are still read.
    func testFishStillReadsTheDefaultVendorDirectories() {
        let env = tabEnvironment()
        XCTAssertEqual(env["XDG_DATA_DIRS"], Self.integration.path + ":/usr/local/share:/usr/share")
    }

    // MARK: zsh

    func testZshKeepsTheShimDirectoryFirst() throws {
        try dotfile(".zshrc", "export PATH=/user/rc:$PATH\n")
        try dotfile(".zlogin", "export PATH=/user/login:$PATH\n")
        let path = try zshPath(tabEnvironment())
        XCTAssertEqual(path.first, shim.path, "\(path)")
        XCTAssertEqual(Array(path.dropFirst().prefix(2)), ["/user/login", "/user/rc"])
        XCTAssertEqual(try zshPath(tabEnvironment(), interactive: false).first, shim.path, "a login shell's -c too")
    }

    func testZshMovesNothingWithoutAShimDir() throws {
        try dotfile(".zshrc", "export PATH=/user/rc:$PATH\n")
        let plain = try zshPath(["HOME": home.path, "TERM": "dumb", "PATH": "\(shim.path):/usr/bin:/bin"])
        XCTAssertEqual(try zshPath(tabEnvironment(shimDir: false)), plain)
    }

    /// The user's own `ZDOTDIR` is where their dotfiles are read from, and what it is once
    /// startup is over: dotfiles that write beside themselves must never write into the app.
    func testZshReadsTheUsersOwnZdotdirAndHandsItBack() throws {
        let theirs = temp.appendingPathComponent("their zdotdir")
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        try "export PATH=/user/theirs:$PATH\n".write(to: theirs.appendingPathComponent(".zshrc"), atomically: true, encoding: .utf8)
        let env = tabEnvironment(extra: ["ZDOTDIR": theirs.path])
        XCTAssertEqual(env[RouteShims.userZDOTDIRVariable], theirs.path)
        let path = try path("/bin/zsh", ["-l", "-i", "-c", "echo PATH=$PATH:$ZDOTDIR"], environment: env)
        XCTAssertEqual(path.first, shim.path)
        XCTAssertEqual(path[1], "/user/theirs")
        XCTAssertEqual(path.last, theirs.path, "ZDOTDIR is the user's again")
    }

    // MARK: bash

    func testBashPutsTheShimDirectoryFirstBeforeThePrompt() throws {
        try dotfile(".bash_profile", "export PATH=/user/profile:$PATH\n")
        let path = try bashPath(tabEnvironment())
        XCTAssertEqual(path.first, shim.path, "\(path)")
        XCTAssertEqual(path[1], "/user/profile")
    }

    func testBashMovesNothingWithoutAShimDir() throws {
        try dotfile(".bash_profile", "export PATH=/user/profile:$PATH\n")
        let plain = try bashPath(["HOME": home.path, "TERM": "dumb", "PATH": "\(shim.path):/usr/bin:/bin"])
        XCTAssertEqual(try bashPath(tabEnvironment(shimDir: false)), plain)
    }

    /// A user who took the directory off `PATH` keeps it off.
    func testARemovedShimDirectoryStaysRemoved() throws {
        try dotfile(".bash_profile", "export PATH=/usr/bin:/bin\n")
        XCTAssertFalse(try bashPath(tabEnvironment()).contains(shim.path))
    }

    // MARK: The environment

    func testIntegrationIsIdempotentAndKeepsAnExistingPromptCommand() {
        let once = RouteShims.shellIntegration(["PROMPT_COMMAND": "history -a"], integration: Self.integration, inherited: [:])
        XCTAssertEqual(RouteShims.shellIntegration(once, integration: Self.integration, inherited: [:]), once)
        XCTAssertTrue(once["PROMPT_COMMAND"]?.hasSuffix("; history -a") == true, once["PROMPT_COMMAND"] ?? "")
        XCTAssertNil(once[RouteShims.userZDOTDIRVariable], "no ZDOTDIR of their own: zsh reads $HOME")
    }
}
