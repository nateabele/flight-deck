import XCTest
@testable import FlightDeck

/// `CodexControlAccess` is a pure builder: given a control socket and the options a codex
/// tab is about to launch with, it decides whether to grant that tab's sandbox the one extra
/// permission it needs to reach `flightdeck`'s control socket, and produces the five flags
/// that do it — as raw argv for `Process` (`launchArguments`, the shape `CodexIntegrationTests` spawns via `Process`) or as the
/// shell-quoted text Flight Deck types at a pty (`launchFlags`). See the type's own doc
/// comment for why the grant goes through `network_proxy` rather than a sandbox override.
///
/// `@MainActor` because the wiring tests at the bottom drive a real `SessionStore` — the pure
/// `CodexControlAccess` tests above don't need it, but nothing stops them running on it too.
@MainActor
final class CodexControlAccessTests: XCTestCase {
    private let socket = URL(fileURLWithPath: "/s/Flight Deck/control.sock")

    // MARK: - launchArguments (raw, unquoted argv)

    func testLaunchArgumentsReturnsTheFiveFlagsRawInOrder() {
        XCTAssertEqual(
            CodexControlAccess.launchArguments(socket: socket, options: CodexThreadOptions()),
            [
                "--enable", "network_proxy",
                "-c", #"default_permissions="flightdeck""#,
                "-c", #"permissions.flightdeck.extends=":workspace""#,
                "-c", "permissions.flightdeck.network.enabled=true",
                "-c", #"permissions.flightdeck.network.unix_sockets={"/s/Flight Deck/control.sock"="allow"}"#,
            ],
            "the unix-socket key must be the socket FILE, not its directory — codex emits "
                + "`(subpath <key>)`, so a directory key would also open every other socket "
                + "beside it, including the unauthenticated answer-trigger.sock"
        )
    }

    func testLaunchArgumentsIsEmptyWithNoSocket() {
        XCTAssertEqual(CodexControlAccess.launchArguments(socket: nil, options: CodexThreadOptions()), [])
    }

    /// codex-rs core/src/config/mod.rs refuses to start at all when `sandbox_mode` and
    /// `default_permissions` overrides are both set ("sandbox_mode and default_permissions
    /// overrides cannot both be set") — so a user who picked an explicit sandbox in
    /// Preferences must not also get this override, or their tab never launches.
    func testLaunchArgumentsIsEmptyWhenTheUserChoseASandbox() {
        for sandbox in ["workspace-write", "danger-full-access"] {
            XCTAssertEqual(
                CodexControlAccess.launchArguments(
                    socket: socket, options: CodexThreadOptions(sandbox: sandbox)),
                [],
                "an explicit sandbox (\(sandbox)) must skip injection, not race codex's own refusal"
            )
        }
    }

    // MARK: - launchFlags (shell-quoted, for the typed command line)

    func testLaunchFlagsShellQuotesOnlyTheDashCValues() {
        XCTAssertEqual(
            CodexControlAccess.launchFlags(socket: socket, options: CodexThreadOptions()),
            [
                "--enable", "network_proxy",
                "-c", ClaudeSession.shellQuoted(#"default_permissions="flightdeck""#),
                "-c", ClaudeSession.shellQuoted(#"permissions.flightdeck.extends=":workspace""#),
                "-c", ClaudeSession.shellQuoted("permissions.flightdeck.network.enabled=true"),
                "-c", ClaudeSession.shellQuoted(
                    #"permissions.flightdeck.network.unix_sockets={"/s/Flight Deck/control.sock"="allow"}"#),
            ],
            "each -c value must be exactly one shell word — `--enable`/`network_proxy` need no "
                + "quoting, since they contain no shell metacharacters"
        )
    }

    func testLaunchFlagsIsEmptyWithNoSocket() {
        XCTAssertEqual(CodexControlAccess.launchFlags(socket: nil, options: CodexThreadOptions()), [])
    }

    func testLaunchFlagsIsEmptyWhenTheUserChoseASandbox() {
        for sandbox in ["workspace-write", "danger-full-access"] {
            XCTAssertEqual(
                CodexControlAccess.launchFlags(
                    socket: socket, options: CodexThreadOptions(sandbox: sandbox)),
                []
            )
        }
    }

    // MARK: - Quoting survives a real shell AND a real TOML parse

    /// The state directory is user-controlled indirectly (it is wherever `Application
    /// Support` resolves to, which can contain an apostrophe from a machine's account name,
    /// e.g. `/Users/o'brien/...`) and this test also throws a literal `"` at it, which no real
    /// macOS path contains but which pins the TOML-escaping rule regardless. Round-trips the
    /// produced `-c` value through a real `/bin/sh`, then checks the resulting TOML value is
    /// exactly the inline table codex expects.
    func testAPathWithSpacesAndQuotesIsQuotedForShellAndToml() throws {
        let oddSocket = URL(fileURLWithPath: "/s/it's \"odd\"/x/control.sock")
        let flags = CodexControlAccess.launchFlags(socket: oddSocket, options: CodexThreadOptions())
        guard let quoted = flags.first(where: { $0.contains("unix_sockets") }) else {
            return XCTFail("expected a -c value carrying unix_sockets in \(flags)")
        }

        let unquoted = try runThroughShell(quoted)

        // `unquoted` is now exactly what codex's own TOML parser would see after `-c`:
        // `permissions.flightdeck.network.unix_sockets={"<socket>"="allow"}`. Split at the first
        // `=` to get the TOML value, then check it is the inline table TOML basic-string
        // escaping demands: `\"` for `"` (this path has no `\` of its own, so that rule is
        // exercised by `CodexControlAccessTests` unit-level TOML-escaping coverage below).
        guard let eq = unquoted.firstIndex(of: "=") else {
            return XCTFail("expected key=value, got \(unquoted)")
        }
        let value = String(unquoted[unquoted.index(after: eq)...])
        let expectedPath = #"/s/it's \"odd\"/x/control.sock"#
        XCTAssertEqual(value, "{\"\(expectedPath)\"=\"allow\"}",
                       "the path's own \" must be escaped as \\\" inside the TOML inline table")
    }

    /// Embeds `shellQuotedValue` exactly where it would sit on a typed `codex ... -c <value>`
    /// command line, then lets a REAL `/bin/sh` parse it — round-tripping the actual shell
    /// grammar `ClaudeSession.shellQuoted` targets, rather than a hand-rolled unquoter that
    /// could share its bugs. `printf %s` stands in for `codex` as the thing receiving the
    /// argument; only the quoting under test matters, not what consumes the result.
    private func runThroughShell(_ shellQuotedValue: String) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "printf %s \(shellQuotedValue)"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// `tomlEscaped` is private to `CodexControlAccess`, so its `\` rule (distinct from the
    /// `"` rule the shell round-trip above already exercises — a real macOS path is most
    /// unlikely to contain a backslash, but TOML's grammar still requires escaping one) is
    /// pinned through the public value it appears in.
    func testABackslashInTheDirectoryIsEscapedForToml() {
        let backslashSocket = URL(fileURLWithPath: #"/s/a\b/control.sock"#)
        let flags = CodexControlAccess.launchArguments(socket: backslashSocket, options: CodexThreadOptions())
        guard let raw = flags.last else { return XCTFail("expected a unix_sockets flag") }
        XCTAssertTrue(raw.contains(#"{"/s/a\\b/control.sock"="allow"}"#),
                      "a literal \\ in the path must become \\\\ in the TOML value, got \(raw)")
    }

    // MARK: - SessionStore pushes controlSocket onto the codex adapter, in both orders

    private final class MemoryPreferences: PreferencesPersisting {
        var stored: Preferences?
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences }
    }

    private func makeStore() -> SessionStore {
        SessionStore(
            provider: nil, persistence: nil,
            preferences: PreferencesStore(persistence: MemoryPreferences())
        )
    }

    /// `overrideAdapter` (used by most codex tests in this suite) bypasses `codexStacks`
    /// entirely, so it would prove nothing here — this goes through the real
    /// `makeCodexStackIfNeeded` path via `adapter(for:)`, the same one a launched codex tab uses.
    func testControlSocketSetBeforeTheAdapterExistsReachesItAtConstruction() {
        let store = makeStore()
        store.controlSocket = URL(fileURLWithPath: "/s/Flight Deck/control.sock")

        guard let adapter = store.adapter(for: .codex, account: nil) as? CodexAdapter else {
            return XCTFail("expected a real CodexAdapter from the codex-stack path")
        }
        XCTAssertEqual(adapter.controlSocket, store.controlSocket,
                       "a stack built after controlSocket was already set must pick it up "
                       + "immediately, not wait for a didSet that will never fire again")
    }

    func testControlSocketSetAfterTheAdapterExistsStillReachesIt() {
        let store = makeStore()
        guard store.adapter(for: .codex, account: nil) is CodexAdapter else {
            return XCTFail("expected a real CodexAdapter from the codex-stack path")
        }

        store.controlSocket = URL(fileURLWithPath: "/s/Flight Deck/control.sock")

        guard let adapter = store.adapter(for: .codex, account: nil) as? CodexAdapter else {
            return XCTFail("expected the same real CodexAdapter still installed")
        }
        XCTAssertEqual(adapter.controlSocket, store.controlSocket,
                       "a socket set after the stack/adapter already exists must still reach "
                       + "it — a codex tab opened before the app finished its own launch must "
                       + "not be permanently stuck without control access")
    }
}
