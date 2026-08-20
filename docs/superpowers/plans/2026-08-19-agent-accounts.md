# Agent Accounts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let Flight Deck run each tab under a chosen agent login (`nate@radify.io` vs `nate@fieldwealth.ai`), assignable per project, with observation following the account instead of staying pinned to `~/.claude`.

**Architecture:** An account is an opaque-identity record pointing at a config-directory home. The home is injected into the spawned process as `CLAUDE_CONFIG_DIR` / `CODEX_HOME` by the agent's own adapter, and every watcher root is derived from it. `SessionStore`'s adapter/runtime registries are re-keyed from `AgentID` to `(AgentID, accountID)`, which turns "one codex app-server" into "one `CodexStack` per account" without restructuring anything.

**Tech Stack:** Swift 6, SwiftUI + AppKit, XCTest, libghostty. macOS only.

**Spec:** `docs/superpowers/specs/2026-08-19-agent-accounts-design.md`

## Global Constraints

- **Never break an existing on-disk blob.** Every new `Preferences` field is Optional in storage (`preferences.v1` in `UserDefaults`), and every new `SessionSnapshot.Entry` field is Optional (`sessions.json`). Synthesized `Codable` throws on a missing non-optional key, and `UserDefaultsPreferencesPersistence.load()` decodes with `try?` — so one non-optional addition silently resets every flag, override and tab the user has.
- **Never fall back to a different account.** An unresolvable account is a *broken* session that does not launch. Falling back resumes under the wrong login, finds no conversation, and starts a fresh one.
- **The built-in account is not removable.** `~/.claude` and `~/.codex` are what `Session.accountID == nil` normalises to.
- **Tests never touch real state.** No committed test spawns `codex app-server`, writes under `~/.claude`, or reads the real `UserDefaults` domain. Use `MemoryPersistence` (already in `PreferencesStoreTests`) and `FileManager.default.temporaryDirectory`.
- **Do not run `scripts/smoke.sh`.** It steals focus for ~40s and the user's typing registers as test failures.
- **Build/test:** `./scripts/test-unit.sh` runs the whole headless suite. It takes no filter argument; to run one test during TDD, after one full run has staged the bundle:
  ```bash
  DYLD_LIBRARY_PATH="$PWD/DerivedData/Build/Products/Debug/Flight Deck.app/Contents/MacOS" \
  DYLD_FRAMEWORK_PATH="$PWD/DerivedData/Build/Products/Debug/Flight Deck.app/Contents/MacOS" \
  xcrun xctest -XCTest AgentAccountTests/testBuiltInHomeForClaude \
    "DerivedData/Build/Products/Debug/Flight Deck.app/Contents/PlugIns/FlightDeckTests.xctest"
  ```
- **New source files must be added to `project.yml`'s target sources only if it enumerates files.** It globs `Sources/FlightDeck`, so a new file under that tree is picked up by `xcodegen generate` (which `test-unit.sh` runs). New test files under `Tests/FlightDeckTests` are picked up the same way.
- **Commit after every task.** Conventional-commit subjects, lowercase, imperative, no trailing period.

---

### Task 1: `AgentAccount` model and built-in homes

**Files:**
- Create: `Sources/FlightDeck/Agents/AgentAccount.swift`
- Test: `Tests/FlightDeckTests/AgentAccountTests.swift`

**Interfaces:**
- Consumes: `AgentID` from `Sources/FlightDeck/Agents/AgentKind.swift`
- Produces: `AgentAccount` (`id`, `agent`, `displayName`, `home`, `cachedIdentity`), `AccountIdentity` (`email`, `organization`, `readAt`), `AgentID.builtInHome`, `AgentAccount.isBuiltIn`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/FlightDeckTests/AgentAccountTests.swift
import XCTest
@testable import FlightDeck

final class AgentAccountTests: XCTestCase {
    func testBuiltInHomes() {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        XCTAssertEqual(AgentID.claude.builtInHome, home.appendingPathComponent(".claude", isDirectory: true))
        XCTAssertEqual(AgentID.codex.builtInHome, home.appendingPathComponent(".codex", isDirectory: true))
    }

    /// The whole point of `isBuiltIn` being computed: it must not depend on a stored flag that
    /// a relocate could leave stale.
    func testIsBuiltInComparesTheHomeNotAStoredFlag() {
        let builtIn = AgentAccount(agent: .claude, displayName: "Default", home: AgentID.claude.builtInHome)
        let other = AgentAccount(
            agent: .claude, displayName: "Work",
            home: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".claude-work")
        )
        XCTAssertTrue(builtIn.isBuiltIn)
        XCTAssertFalse(other.isBuiltIn)
    }

    /// Trailing-slash and `..` differences must not make one home look like two — the
    /// duplicate-home rule in Task 5 leans on this.
    func testIsBuiltInIgnoresPathSpelling() {
        let spelled = URL(fileURLWithPath: NSHomeDirectory() + "/./.claude/", isDirectory: true)
        XCTAssertTrue(AgentAccount(agent: .claude, displayName: "D", home: spelled).isBuiltIn)
    }

    func testRoundTripsThroughJSON() throws {
        let account = AgentAccount(
            agent: .codex, displayName: "Work", home: AgentID.codex.builtInHome,
            cachedIdentity: AccountIdentity(email: "a@b.c", organization: "Org", readAt: Date(timeIntervalSince1970: 1))
        )
        let data = try JSONEncoder().encode(account)
        XCTAssertEqual(try JSONDecoder().decode(AgentAccount.self, from: data), account)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `cannot find 'AgentAccount' in scope`

- [ ] **Step 3: Write the implementation**

```swift
// Sources/FlightDeck/Agents/AgentAccount.swift
import Foundation

extension AgentID {
    /// The config directory the agent uses when no environment variable names one. Spelled
    /// out rather than treated as "no account": `CLAUDE_CONFIG_DIR=$HOME/.claude` is exactly
    /// equivalent to setting nothing, so making it a concrete home removes a "nil means
    /// default" branch from every watcher and every launch path.
    var builtInHome: URL {
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        switch self {
        case .claude: return home.appendingPathComponent(".claude", isDirectory: true)
        case .codex:  return home.appendingPathComponent(".codex", isDirectory: true)
        }
    }

    /// The variable that binds a process to a home. Read by `AgentAdapter.environment(for:)`,
    /// and nowhere else — callers name accounts, never variables.
    var homeEnvironmentKey: String {
        switch self {
        case .claude: return "CLAUDE_CONFIG_DIR"
        case .codex:  return "CODEX_HOME"
        }
    }
}

/// Who an account is, read from its home. Display only, and deliberately so: a menu must not
/// touch disk, and a stale email must never affect which process is spawned.
struct AccountIdentity: Codable, Equatable, Sendable {
    var email: String?
    var organization: String?
    var readAt: Date

    init(email: String? = nil, organization: String? = nil, readAt: Date = Date()) {
        self.email = email
        self.organization = organization
        self.readAt = readAt
    }
}

/// One logged-in identity for one agent.
///
/// `id` is opaque and permanent. Renaming the label or relocating the directory never changes
/// what sessions and projects point at, which is what makes rename free and relocate a
/// one-field edit rather than a migration.
struct AgentAccount: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var agent: AgentID
    var displayName: String
    var home: URL
    var cachedIdentity: AccountIdentity?

    init(
        id: UUID = UUID(),
        agent: AgentID,
        displayName: String,
        home: URL,
        cachedIdentity: AccountIdentity? = nil
    ) {
        self.id = id
        self.agent = agent
        self.displayName = displayName
        self.home = home
        self.cachedIdentity = cachedIdentity
    }

    /// Computed, never stored. A stored flag would go stale the moment a relocate moved the
    /// directory, and this predicate is what protects the account `Session.accountID == nil`
    /// resolves to from being deleted.
    var isBuiltIn: Bool { Self.key(home) == Self.key(agent.builtInHome) }

    /// The comparison key for "same home". Standardised and trailing-slash-insensitive, so
    /// `~/.claude` and `~/./.claude/` are one home — the duplicate-home rejection depends on it.
    static func key(_ url: URL) -> String { url.standardizedFileURL.resolvingSymlinksInPath().path }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS, no other test regressed

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/AgentAccount.swift Tests/FlightDeckTests/AgentAccountTests.swift
git commit -m "feat: model an agent account as an opaque identity over a config home"
```

---

### Task 2: Reading identity and discovering accounts on disk

**Files:**
- Create: `Sources/FlightDeck/Agents/AccountDirectory.swift`
- Test: `Tests/FlightDeckTests/AccountDirectoryTests.swift`

**Interfaces:**
- Consumes: `AgentAccount`, `AccountIdentity`, `AgentID` (Task 1)
- Produces: `AccountDirectory.identity(atHome:agent:) -> AccountIdentity?`, `AccountDirectory.discover(in:agent:) -> [URL]`, `AccountDirectory.looksLikeHome(_:agent:) -> Bool`

Both functions take an explicit directory so tests never read `$HOME`. Identity parsing is split
from file reading so the JWT and JSON rules are assertable against literal bytes.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/FlightDeckTests/AccountDirectoryTests.swift
import XCTest
@testable import FlightDeck

final class AccountDirectoryTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeHome(_ name: String, file: String, contents: String) throws -> URL {
        let home = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try contents.write(to: home.appendingPathComponent(file), atomically: true, encoding: .utf8)
        return home
    }

    func testReadsClaudeIdentity() throws {
        let home = try makeHome(".claude-work", file: ".claude.json", contents: """
        {"oauthAccount":{"emailAddress":"nate@fieldwealth.ai","organizationName":"Acme"}}
        """)
        let identity = AccountDirectory.identity(atHome: home, agent: .claude)
        XCTAssertEqual(identity?.email, "nate@fieldwealth.ai")
        XCTAssertEqual(identity?.organization, "Acme")
    }

    /// Fails closed. An unreadable or unrecognised home yields nil rather than a guess, and
    /// the row shows its display name alone.
    func testUnreadableClaudeHomeYieldsNil() throws {
        let home = try makeHome(".claude-broken", file: ".claude.json", contents: "not json")
        XCTAssertNil(AccountDirectory.identity(atHome: home, agent: .claude))
    }

    func testReadsCodexIdentityFromTheIdToken() throws {
        // Unsigned, unverified: the payload is read for display only, never for authorisation.
        let payload = Data(#"{"email":"nate@radify.io"}"#.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        let home = try makeHome(".codex-work", file: "auth.json", contents: """
        {"tokens":{"id_token":"header.\(payload).signature"}}
        """)
        XCTAssertEqual(AccountDirectory.identity(atHome: home, agent: .codex)?.email, "nate@radify.io")
    }

    func testDiscoversSiblingHomesButNotTheBuiltInOrUnrelatedDirectories() throws {
        _ = try makeHome(".claude", file: ".claude.json", contents: "{}")
        _ = try makeHome(".claude-work", file: ".claude.json", contents: "{}")
        _ = try makeHome(".claude-empty", file: "README", contents: "no marker here")
        _ = try makeHome(".codex-work", file: "auth.json", contents: "{}")

        let found = AccountDirectory.discover(in: root, agent: .claude).map(\.lastPathComponent)
        XCTAssertEqual(found, [".claude-work"])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `cannot find 'AccountDirectory' in scope`

- [ ] **Step 3: Write the implementation**

```swift
// Sources/FlightDeck/Agents/AccountDirectory.swift
import Foundation

/// Reads what a config directory says about itself, and finds directories that look like one.
///
/// Every rule here fails closed: an unreadable or unrecognised home yields nil rather than a
/// guess. Identity is display-only, so a wrong answer must degrade to "no answer", never to a
/// plausible-looking wrong email next to a real account.
enum AccountDirectory {
    /// The file whose presence marks a directory as one of this agent's homes.
    static func marker(for agent: AgentID) -> String {
        switch agent {
        case .claude: return ".claude.json"
        case .codex:  return "auth.json"
        }
    }

    static func looksLikeHome(_ url: URL, agent: AgentID) -> Bool {
        FileManager.default.fileExists(atPath: url.appendingPathComponent(marker(for: agent)).path)
    }

    /// Sibling homes under `directory`, excluding the agent's built-in one — which is seeded
    /// explicitly and must not be discovered twice.
    static func discover(in directory: URL, agent: AgentID) -> [URL] {
        let builtInName = agent.builtInHome.lastPathComponent
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]
        )) ?? []
        // `.skipsHiddenFiles` hides dot-directories, which is every candidate — enumerate names
        // instead and filter by prefix.
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        _ = contents
        return names
            .filter { $0.hasPrefix(builtInName + "-") }
            .sorted()
            .map { directory.appendingPathComponent($0, isDirectory: true) }
            .filter { looksLikeHome($0, agent: agent) }
    }

    static func identity(atHome home: URL, agent: AgentID) -> AccountIdentity? {
        guard let data = try? Data(contentsOf: home.appendingPathComponent(marker(for: agent)))
        else { return nil }
        switch agent {
        case .claude: return claudeIdentity(from: data)
        case .codex:  return codexIdentity(from: data)
        }
    }

    /// `<home>/.claude.json` → `oauthAccount.emailAddress` / `organizationName`.
    static func claudeIdentity(from data: Data) -> AccountIdentity? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"] as? [String: Any]
        else { return nil }
        let email = account["emailAddress"] as? String
        let organization = account["organizationName"] as? String
        guard email != nil || organization != nil else { return nil }
        return AccountIdentity(email: email, organization: organization)
    }

    /// `<home>/auth.json` → the `email` claim of `tokens.id_token`.
    ///
    /// The JWT is decoded, never verified: this is a label under a row, not an authorisation
    /// decision, and the only alternative source would be a network call.
    static func codexIdentity(from data: Data) -> AccountIdentity? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = root["tokens"] as? [String: Any],
              let token = tokens["id_token"] as? String
        else { return nil }
        let parts = token.split(separator: ".")
        guard parts.count >= 2, let payload = base64URLDecode(String(parts[1])),
              let claims = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        guard let email = claims["email"] as? String else { return nil }
        return AccountIdentity(email: email, organization: claims["organization"] as? String)
    }

    /// JWT payloads are base64url with the padding stripped; `Data(base64Encoded:)` accepts
    /// neither difference.
    private static func base64URLDecode(_ text: String) -> Data? {
        var s = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while s.count % 4 != 0 { s += "=" }
        return Data(base64Encoded: s)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS

- [ ] **Step 5: Remove the dead `contents` probe**

The `contentsOfDirectory(at:)` call above is unused — delete it and its `_ = contents` line, leaving only the name-based enumeration. Re-run `./scripts/test-unit.sh`; expected PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Agents/AccountDirectory.swift Tests/FlightDeckTests/AccountDirectoryTests.swift
git commit -m "feat: read an account's identity from its home, and find sibling homes"
```

---

### Task 3: Dictionary keys, `ProjectSettings`, and the codex options merge

**Files:**
- Modify: `Sources/FlightDeck/Agents/AgentKind.swift` (add the `CodingKeyRepresentable` conformance next to `AgentID`)
- Modify: `Sources/FlightDeck/Agents/Codex/CodexThreadOptions.swift` (add `merge`)
- Create: `Sources/FlightDeck/Preferences/ProjectSettings.swift`
- Test: `Tests/FlightDeckTests/ProjectSettingsTests.swift`

**Interfaces:**
- Consumes: `AgentID`, `AgentOptions`, `FlagSet`, `CodexThreadOptions`
- Produces: `ProjectSettings` (`defaultAgent`, `accounts`, `options`, `isEmpty`), `CodexThreadOptions.merge(global:project:)`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/FlightDeckTests/ProjectSettingsTests.swift
import XCTest
@testable import FlightDeck

final class ProjectSettingsTests: XCTestCase {
    /// The reason for the `CodingKeyRepresentable` conformance: without it Swift encodes an
    /// enum-keyed dictionary as a flat alternating array, which is unreadable on disk and
    /// breaks the "raw values are a storage format" contract on `AgentID`.
    func testAgentKeyedDictionariesEncodeAsObjects() throws {
        let settings = ProjectSettings(defaultAgent: .codex, accounts: [.claude: UUID()], options: [:])
        let json = try JSONSerialization.jsonObject(
            with: try JSONEncoder().encode(settings)
        ) as? [String: Any]
        XCTAssertNotNil((json?["accounts"] as? [String: Any])?["claude"])
    }

    func testEmptinessIgnoresPresentButEmptyOptions() {
        var settings = ProjectSettings()
        XCTAssertTrue(settings.isEmpty)
        settings.options[.claude] = .claude(FlagSet())
        XCTAssertTrue(settings.isEmpty, "an empty FlagSet is not an override")
        settings.options[.claude] = .claude(FlagSet(values: ["--model": .value("opus")]))
        XCTAssertFalse(settings.isEmpty)
    }

    func testEmptinessSeesADefaultAgentAndAnAccount() {
        XCTAssertFalse(ProjectSettings(defaultAgent: .claude).isEmpty)
        XCTAssertFalse(ProjectSettings(accounts: [.codex: UUID()]).isEmpty)
    }

    func testCodexMergeInheritsNilFieldsAndOverridesSetOnes() {
        let global = CodexThreadOptions(model: "gpt-5", sandbox: "read-only", addDirs: ["/g"])
        let project = CodexThreadOptions(sandbox: "workspace-write")
        let merged = CodexThreadOptions.merge(global: global, project: project)
        XCTAssertEqual(merged.model, "gpt-5")
        XCTAssertEqual(merged.sandbox, "workspace-write")
        XCTAssertEqual(merged.addDirs, ["/g"], "an empty project list inherits rather than clearing")
    }

    func testCodexMergeReplacesAddDirsWhenTheProjectSetsThem() {
        let merged = CodexThreadOptions.merge(
            global: CodexThreadOptions(addDirs: ["/g"]), project: CodexThreadOptions(addDirs: ["/p"])
        )
        XCTAssertEqual(merged.addDirs, ["/p"])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `cannot find 'ProjectSettings' in scope`

- [ ] **Step 3: Write the implementation**

Append to `Sources/FlightDeck/Agents/AgentKind.swift`:

```swift
/// So `[AgentID: T]` encodes as a JSON object keyed `"claude"` / `"codex"` rather than Swift's
/// default alternating-array form. The stdlib supplies the whole implementation for a
/// `String`-backed `RawRepresentable` (SE-0320), which is why the body is empty — and the raw
/// values are already documented above as a storage format, so this keeps that promise legible.
extension AgentID: CodingKeyRepresentable {}
```

Append to `Sources/FlightDeck/Agents/Codex/CodexThreadOptions.swift`:

```swift
extension CodexThreadOptions {
    /// Codex's counterpart to `FlagSetMerge.merge`. A nil project field inherits; a set field
    /// overrides. `addDirs` has no nil to test, so emptiness stands in for it — an empty
    /// project list inherits rather than clearing the global one, because "I set no extra
    /// directories here" is the overwhelmingly common state and must not erase a global.
    static func merge(global: CodexThreadOptions, project: CodexThreadOptions) -> CodexThreadOptions {
        CodexThreadOptions(
            model: project.model ?? global.model,
            sandbox: project.sandbox ?? global.sandbox,
            approvalPolicy: project.approvalPolicy ?? global.approvalPolicy,
            addDirs: project.addDirs.isEmpty ? global.addDirs : project.addDirs
        )
    }
}
```

```swift
// Sources/FlightDeck/Preferences/ProjectSettings.swift
import Foundation

/// One project's overrides. Absent entirely for a project the user has never configured, which
/// is the default state — the Projects pane opens on `<Use global settings>`.
///
/// `options` is keyed by agent so switching which agent the pane edits never discards the
/// other's values, and so a per-project override stays in force whenever that agent launches
/// here regardless of what `defaultAgent` currently says.
struct ProjectSettings: Codable, Equatable {
    /// nil = "use global settings": inherit the global agent order untouched.
    var defaultAgent: AgentID?
    /// A missing key means that agent's default account — the top of its list.
    var accounts: [AgentID: UUID]
    var options: [AgentID: AgentOptions]

    init(
        defaultAgent: AgentID? = nil,
        accounts: [AgentID: UUID] = [:],
        options: [AgentID: AgentOptions] = [:]
    ) {
        self.defaultAgent = defaultAgent
        self.accounts = accounts
        self.options = options
    }

    /// A record that says nothing is deleted rather than stored, matching how an emptied flag
    /// override already drops a project from the Projects list. A *present but empty* options
    /// payload says nothing, so it does not keep the record alive.
    var isEmpty: Bool {
        defaultAgent == nil && accounts.isEmpty && options.values.allSatisfy(\.isEmpty)
    }
}

extension AgentOptions {
    /// Whether this payload overrides anything. Per-agent, because "empty" is agent-shaped:
    /// claude's is an empty `FlagSet`, codex's is every field unset.
    var isEmpty: Bool {
        switch self {
        case .claude(let flags): return flags.isEmpty
        case .codex(let options):
            return options.model == nil && options.sandbox == nil
                && options.approvalPolicy == nil && options.addDirs.isEmpty
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/AgentKind.swift Sources/FlightDeck/Agents/Codex/CodexThreadOptions.swift Sources/FlightDeck/Preferences/ProjectSettings.swift Tests/FlightDeckTests/ProjectSettingsTests.swift
git commit -m "feat: give projects per-agent settings, and codex a merge to match claude's"
```

---

### Task 4: Preferences storage and the three migrations

**Files:**
- Modify: `Sources/FlightDeck/Preferences/Preferences.swift`
- Test: `Tests/FlightDeckTests/PreferencesMigrationTests.swift`

**Interfaces:**
- Consumes: `AgentAccount`, `AccountDirectory`, `ProjectSettings`
- Produces: `Preferences.storedAccounts` / `accounts` / `moveAccounts(forAgent:fromOffsets:toOffset:)`, `Preferences.storedProjectSettings` / `projectSettings`, `migrateAccountsIfNeeded(discoveryRoot:)`, `migrateProjectSettingsIfNeeded()`, `migrateGlobalFlagsIfNeeded()`

Migrations run in that order — accounts must exist before anything resolves against them.
`discoveryRoot` is a parameter so tests never scan the real `$HOME`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/FlightDeckTests/PreferencesMigrationTests.swift
import XCTest
@testable import FlightDeck

final class PreferencesMigrationTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in [".claude-work", ".codex-work"] {
            let home = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
            let marker = name.hasPrefix(".claude") ? ".claude.json" : "auth.json"
            try "{}".write(to: home.appendingPathComponent(marker), atomically: true, encoding: .utf8)
        }
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    func testSeedsABuiltInAccountPerAgentAndDiscoversSiblings() {
        var prefs = Preferences()
        prefs.migrateAccountsIfNeeded(discoveryRoot: root)

        let claude = prefs.accounts(for: .claude)
        XCTAssertEqual(claude.count, 2)
        XCTAssertTrue(claude[0].isBuiltIn, "the built-in home is seeded first and is the default")
        XCTAssertEqual(claude[1].home.lastPathComponent, ".claude-work")
        XCTAssertEqual(prefs.accounts(for: .codex).count, 2)
    }

    /// Idempotence is what makes it safe on every load. A re-scan would resurrect an account
    /// the user removed.
    func testMigrationDoesNotRescanOnceAccountsExist() {
        var prefs = Preferences()
        prefs.migrateAccountsIfNeeded(discoveryRoot: root)
        prefs.storedAccounts?.removeAll { !$0.isBuiltIn }
        prefs.migrateAccountsIfNeeded(discoveryRoot: root)
        XCTAssertEqual(prefs.accounts(for: .claude).count, 1)
    }

    func testProjectFlagsBecomeUnspecifiedProjectSettingsWithFlagsIntact() {
        let flags = FlagSet(values: ["--model": .value("opus")])
        var prefs = Preferences(projectFlags: ["/p": flags])
        prefs.migrateProjectSettingsIfNeeded()

        let settings = prefs.projectSettings["/p"]
        XCTAssertNil(settings?.defaultAgent)
        XCTAssertTrue(settings?.accounts.isEmpty ?? false)
        XCTAssertEqual(settings?.options[.claude], .claude(flags))
    }

    func testGlobalFlagsFoldIntoTheClaudeAgentRow() {
        let flags = FlagSet(values: ["--verbose": .on])
        var prefs = Preferences(globalFlags: flags)
        prefs.migrateAgentsIfNeeded()
        prefs.migrateGlobalFlagsIfNeeded()
        XCTAssertEqual(prefs.agents.first { $0.id == .claude }?.options, .claude(flags))
    }

    /// The load-bearing guarantee: a blob written before any of this decodes rather than
    /// throwing, which is what stops a silent reset of every setting the user has.
    func testAPreAccountsBlobStillDecodes() throws {
        let legacy = Data(#"{"globalFlags":{"values":{},"passthrough":[]},"projectFlags":{},"shell":{"environment":{},"clearChildSessionMarker":true}}"#.utf8)
        let decoded = try JSONDecoder().decode(Preferences.self, from: legacy)
        XCTAssertNil(decoded.storedAccounts)
        XCTAssertTrue(decoded.projectSettings.isEmpty)
    }

    func testReorderingAccountsChangesTheDefaultForOneAgentOnly() {
        var prefs = Preferences()
        prefs.migrateAccountsIfNeeded(discoveryRoot: root)
        let codexBefore = prefs.accounts(for: .codex).map(\.id)
        prefs.moveAccounts(forAgent: .claude, fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(prefs.accounts(for: .claude)[0].home.lastPathComponent, ".claude-work")
        XCTAssertEqual(prefs.accounts(for: .codex).map(\.id), codexBefore)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `value of type 'Preferences' has no member 'migrateAccountsIfNeeded'`

- [ ] **Step 3: Write the implementation**

Add to `Preferences` in `Sources/FlightDeck/Preferences/Preferences.swift`, alongside `storedAgents` / `storedTools` and following their exact optional-in-storage discipline:

```swift
    /// Ordered. Relative order *within one agent's* entries is that agent's default ordering:
    /// the topmost is what a project with no explicit choice resolves to.
    ///
    /// Optional in storage for the same reason `storedAgents` is — see that property. `nil`
    /// means "never migrated", which `migrateAccountsIfNeeded` fills in.
    var storedAccounts: [AgentAccount]?
    /// Keyed by standardized project path, replacing `projectFlags`. Optional for the same
    /// reason; `migrateProjectSettingsIfNeeded` folds the old field in.
    var storedProjectSettings: [String: ProjectSettings]?
```

Add both to the memberwise `init` with `= nil` defaults and assign them, then add:

```swift
    var accounts: [AgentAccount] {
        get { storedAccounts ?? [] }
        set { storedAccounts = newValue }
    }

    func accounts(for agent: AgentID) -> [AgentAccount] {
        accounts.filter { $0.agent == agent }
    }

    var projectSettings: [String: ProjectSettings] {
        get { storedProjectSettings ?? [:] }
        set { storedProjectSettings = newValue }
    }

    /// Reorders one agent's accounts without disturbing any other agent's.
    ///
    /// `accounts` is one flat array, so offsets from a per-agent list cannot be applied to it
    /// directly. This maps them back: pull out this agent's entries, reorder them, then write
    /// them into the positions the flat array already reserved for that agent.
    mutating func moveAccounts(forAgent agent: AgentID, fromOffsets source: IndexSet, toOffset destination: Int) {
        var mine = accounts(for: agent)
        mine.move(fromOffsets: source, toOffset: destination)
        var reordered = mine.makeIterator()
        accounts = accounts.map { $0.agent == agent ? (reordered.next() ?? $0) : $0 }
    }

    /// Seeds the built-in account per agent, then discovers siblings ONCE.
    ///
    /// Deliberately not a re-scan on later launches: a re-scan resurrects accounts the user
    /// removed. The Accounts pane offers "Scan for Accounts…" for additions made afterwards.
    mutating func migrateAccountsIfNeeded(
        discoveryRoot: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    ) {
        guard storedAccounts == nil else { return }
        var seeded: [AgentAccount] = []
        for agent in AgentID.allCases {
            let builtIn = agent.builtInHome
            seeded.append(AgentAccount(
                agent: agent,
                displayName: AccountDirectory.identity(atHome: builtIn, agent: agent)?.email ?? "Default",
                home: builtIn,
                cachedIdentity: AccountDirectory.identity(atHome: builtIn, agent: agent)
            ))
            for home in AccountDirectory.discover(in: discoveryRoot, agent: agent) {
                let identity = AccountDirectory.identity(atHome: home, agent: agent)
                seeded.append(AgentAccount(
                    agent: agent,
                    displayName: identity?.email ?? home.lastPathComponent,
                    home: home,
                    cachedIdentity: identity
                ))
            }
        }
        storedAccounts = seeded
    }

    /// Folds today's per-project claude flags into the per-agent record. Every existing project
    /// lands in the unspecified state — no default agent, no account — with its flags intact.
    mutating func migrateProjectSettingsIfNeeded() {
        guard storedProjectSettings == nil else { return }
        storedProjectSettings = projectFlags.mapValues {
            ProjectSettings(options: [.claude: .claude($0)])
        }
    }

    /// Makes `agents[claude].options` the single source for global claude flags.
    ///
    /// `globalFlags` and the claude agent row have held the same value in parallel since the
    /// Agents tab shipped, with only the former being read. Two homes for one setting is
    /// tolerable while nothing else writes either; it is not once per-(project, agent) options
    /// exist. `globalFlags` stays as a decode-only legacy field.
    mutating func migrateGlobalFlagsIfNeeded() {
        guard let index = agents.firstIndex(where: { $0.id == .claude }),
              case .claude(let existing) = agents[index].options, existing.isEmpty,
              !globalFlags.isEmpty
        else { return }
        var list = agents
        list[index].options = .claude(globalFlags)
        agents = list
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Preferences/Preferences.swift Tests/FlightDeckTests/PreferencesMigrationTests.swift
git commit -m "feat: store accounts and per-project agent settings, migrating what exists"
```

---

### Task 5: Resolution rules and account mutation in `PreferencesStore`

**Files:**
- Modify: `Sources/FlightDeck/Preferences/PreferencesStore.swift`
- Modify: `Sources/FlightDeck/Preferences/UI/ProjectsSettingsTab.swift` (only where it calls the removed `projectOverride` API — keep it compiling; the visual restructure is Task 13)
- Test: `Tests/FlightDeckTests/AccountResolutionTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 1–4
- Produces: `PreferencesStore.account(for:project:)`, `.account(id:)`, `.resolvedAccountID(for:in:)`, `.resolvedOptions(for:project:)`, `.agentOrder(forProject:)`, `.addAccount(_:)`, `.removeAccount(id:)`, `.relocateAccount(id:to:)`, `.renameAccount(id:to:)`, `.homeIsTaken(_:excluding:)`

Call `migrateAccountsIfNeeded()`, `migrateProjectSettingsIfNeeded()` and `migrateGlobalFlagsIfNeeded()`
from `PreferencesStore.init`, in that order, immediately after the existing `migrateAgentsIfNeeded()`.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/FlightDeckTests/AccountResolutionTests.swift
import XCTest
@testable import FlightDeck

@MainActor
final class AccountResolutionTests: XCTestCase {
    private func store(_ accounts: [AgentAccount], projects: [String: ProjectSettings] = [:]) -> PreferencesStore {
        let store = PreferencesStore(persistence: nil)
        store.preferences.storedAccounts = accounts
        store.preferences.storedProjectSettings = projects
        return store
    }

    private func account(_ agent: AgentID, _ name: String) -> AgentAccount {
        AgentAccount(agent: agent, displayName: name, home: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    func testAProjectWithNoChoiceGetsTheTopAccount() {
        let top = account(.claude, "top"), other = account(.claude, "other")
        XCTAssertEqual(store([top, other]).account(for: .claude, project: "/p")?.id, top.id)
    }

    func testAnExplicitAssignmentWins() {
        let top = account(.claude, "top"), chosen = account(.claude, "chosen")
        let store = store([top, chosen], projects: ["/p": ProjectSettings(accounts: [.claude: chosen.id])])
        XCTAssertEqual(store.account(for: .claude, project: "/p")?.id, chosen.id)
    }

    /// The rule that must never soften. A dangling id resolves to nothing, not to the top
    /// account — resuming under the wrong login would find no conversation and start a fresh one.
    func testADanglingAssignmentIsBrokenNotAFallback() {
        let top = account(.claude, "top")
        let store = store([top], projects: ["/p": ProjectSettings(accounts: [.claude: UUID()])])
        XCTAssertNil(store.account(for: .claude, project: "/p"))
    }

    func testANilSessionAccountNormalisesToTheBuiltInAccount() {
        let builtIn = AgentAccount(agent: .claude, displayName: "Default", home: AgentID.claude.builtInHome)
        let store = store([account(.claude, "first"), builtIn])
        XCTAssertEqual(store.resolvedAccountID(for: .claude, in: nil), builtIn.id,
                       "nil means the built-in home, never merely the topmost account")
    }

    func testProjectOptionsOverrideGlobalPerAgentAndSurviveTheDefaultAgentBeingUnset() {
        let store = store([account(.codex, "c")], projects: [
            "/p": ProjectSettings(defaultAgent: nil, options: [.codex: .codex(CodexThreadOptions(sandbox: "read-only"))])
        ])
        store.preferences.agents = [
            AgentSettings(id: .codex, options: .codex(CodexThreadOptions(model: "gpt-5")))
        ]
        guard case .codex(let merged) = store.resolvedOptions(for: .codex, project: "/p") else {
            return XCTFail("expected codex options")
        }
        XCTAssertEqual(merged.model, "gpt-5")
        XCTAssertEqual(merged.sandbox, "read-only")
    }

    func testAgentOrderPromotesTheProjectDefaultAndKeepsTheRestGlobal() {
        let store = store([])
        store.preferences.agents = [
            AgentSettings(id: .claude, options: .claude(FlagSet())),
            AgentSettings(id: .codex, options: .codex(CodexThreadOptions())),
        ]
        store.preferences.projectSettings["/p"] = ProjectSettings(defaultAgent: .codex)
        XCTAssertEqual(store.agentOrder(forProject: "/p").map(\.id), [.codex, .claude])
        XCTAssertEqual(store.agentOrder(forProject: "/other").map(\.id), [.claude, .codex])
    }

    func testTwoAccountsMayNotShareAHome() {
        let existing = account(.claude, "a")
        let store = store([existing])
        XCTAssertTrue(store.homeIsTaken(existing.home, excluding: nil))
        XCTAssertFalse(store.homeIsTaken(existing.home, excluding: existing.id))
    }

    func testRemovingAnAccountClearsProjectsThatReferencedIt() {
        let doomed = account(.claude, "doomed"), keep = account(.claude, "keep")
        let store = store([keep, doomed], projects: ["/p": ProjectSettings(accounts: [.claude: doomed.id])])
        store.removeAccount(id: doomed.id)
        XCTAssertNil(store.preferences.projectSettings["/p"], "the record became empty and was dropped")
        XCTAssertEqual(store.preferences.accounts.map(\.id), [keep.id])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `value of type 'PreferencesStore' has no member 'account(for:project:)'`

- [ ] **Step 3: Write the implementation**

Add to `PreferencesStore`, in a `// MARK: Accounts` section after `// MARK: Flags`:

```swift
    func account(id: UUID) -> AgentAccount? { preferences.accounts.first { $0.id == id } }

    /// The account a new session for `agent` in `project` launches under. nil is BROKEN — an
    /// explicit assignment that no longer resolves must never silently become another login.
    func account(for agent: AgentID, project: String) -> AgentAccount? {
        if let assigned = preferences.projectSettings[Self.key(project)]?.accounts[agent] {
            return account(id: assigned)
        }
        return preferences.accounts.first { $0.agent == agent }
    }

    /// Normalises a stored `Session.accountID`. nil means the agent's built-in home — not "the
    /// current default" — so a legacy tab and a tab created today on that home share one
    /// identity, and one home can never carry two instance keys.
    func resolvedAccountID(for agent: AgentID, in stored: UUID?) -> UUID? {
        if let stored { return account(id: stored)?.id }
        return preferences.accounts.first { $0.agent == agent && $0.isBuiltIn }?.id
    }

    /// Global agent options merged with the project's. Applies whenever that agent launches
    /// here, independently of `defaultAgent` — the Projects dropdown chooses what you edit and
    /// what ⌘N picks, not whether an override is in force.
    func resolvedOptions(for agent: AgentID, project: String) -> AgentOptions {
        let global = preferences.agents.first { $0.id == agent }?.options
        let override = preferences.projectSettings[Self.key(project)]?.options[agent]
        switch (global ?? Self.emptyOptions(for: agent), override) {
        case (.claude(let g), .claude(let p)?): return .claude(FlagSetMerge.merge(global: g, project: p))
        case (.codex(let g), .codex(let p)?):   return .codex(CodexThreadOptions.merge(global: g, project: p))
        case (let g, _):                        return g
        }
    }

    private static func emptyOptions(for agent: AgentID) -> AgentOptions {
        switch agent {
        case .claude: return .claude(FlagSet())
        case .codex:  return .codex(CodexThreadOptions())
        }
    }

    /// The agent list as this project sees it: its default agent promoted to the front, every
    /// other agent following in global order. Feeds `NewSessionAffordance`, so ⌘N is always the
    /// project's agent and no agent is left unreachable by shortcut.
    func agentOrder(forProject project: String) -> [AgentSettings] {
        let global = preferences.agents
        guard let preferred = preferences.projectSettings[Self.key(project)]?.defaultAgent,
              let row = global.first(where: { $0.id == preferred })
        else { return global }
        return [row] + global.filter { $0.id != preferred }
    }

    func homeIsTaken(_ home: URL, excluding id: UUID?) -> Bool {
        preferences.accounts.contains { $0.id != id && AgentAccount.key($0.home) == AgentAccount.key(home) }
    }

    func addAccount(_ account: AgentAccount) { preferences.accounts.append(account) }

    func renameAccount(id: UUID, to name: String) {
        guard let index = preferences.accounts.firstIndex(where: { $0.id == id }) else { return }
        preferences.accounts[index].displayName = name
    }

    func relocateAccount(id: UUID, to home: URL) {
        guard let index = preferences.accounts.firstIndex(where: { $0.id == id }) else { return }
        preferences.accounts[index].home = home
        preferences.accounts[index].cachedIdentity =
            AccountDirectory.identity(atHome: home, agent: preferences.accounts[index].agent)
    }

    /// Drops the account AND every project assignment naming it, so nothing is left pointing at
    /// an id that no longer resolves. A record emptied by that clearing is removed, matching how
    /// an emptied flag override already drops a project from the list.
    func removeAccount(id: UUID) {
        preferences.accounts.removeAll { $0.id == id }
        for (path, var settings) in preferences.projectSettings {
            let before = settings.accounts
            settings.accounts = settings.accounts.filter { $0.value != id }
            guard settings.accounts != before else { continue }
            preferences.projectSettings[path] = settings.isEmpty ? nil : settings
        }
    }

    func projectSettings(_ path: String) -> ProjectSettings {
        preferences.projectSettings[Self.key(path)] ?? ProjectSettings()
    }

    /// The single write path, so an emptied record can never linger with its badge hidden and
    /// its Remove button disabled.
    func setProjectSettings(_ path: String, _ settings: ProjectSettings) {
        preferences.projectSettings[Self.key(path)] = settings.isEmpty ? nil : settings
    }

    /// Sorted so the Projects tab's list order is stable across launches.
    var configuredProjectPaths: [String] { preferences.projectSettings.keys.sorted() }
```

Delete `projectOverride(_:)`, `setProjectOverride(_:_:)`, `removeProjectOverride(_:)`,
`overriddenProjectPaths` and `resolvedFlags(forProject:)`, and update `ProjectsSettingsTab`'s
references to the new API so the target still builds — reading the claude flags out of
`projectSettings(path).options[.claude]` and writing them back through `setProjectSettings`.
`resolvedCodexOptions()` also goes: `SessionStore.options(for:project:)` becomes a single call to
`resolvedOptions(for:project:)` in Task 10.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS. Existing `PreferencesStoreTests` cases covering `projectOverride` will need
updating to the new API — do that here rather than leaving them deleted.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Preferences Tests/FlightDeckTests
git commit -m "feat: resolve an account, options and agent order for a project"
```

---

### Task 6: `Session.accountID` and its snapshot round-trip

**Files:**
- Modify: `Sources/FlightDeck/SessionModel.swift`
- Modify: `Sources/FlightDeck/SessionPersistence.swift`
- Modify: `Sources/FlightDeck/SessionStore.swift` (wherever `Session` ↔ `SessionSnapshot.Entry` is built)
- Test: `Tests/FlightDeckTests/SessionPersistenceTests.swift` (extend)

**Interfaces:**
- Consumes: nothing new
- Produces: `Session.accountID: UUID?`, `SessionSnapshot.Entry.accountID: UUID?`

- [ ] **Step 1: Write the failing test**

```swift
// append to Tests/FlightDeckTests/SessionPersistenceTests.swift
    /// The migration that needs no migration: an absent key is nil is the built-in home.
    func testASnapshotWithoutAnAccountDecodesAsNil() throws {
        let json = Data(#"{"sessions":[{"id":"00000000-0000-0000-0000-000000000001","title":"s","workingDirectory":"/p"}],"sessionCounter":1}"#.utf8)
        let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: json)
        XCTAssertNil(snapshot.sessions[0].accountID)
    }

    func testAnAccountSurvivesTheRoundTrip() throws {
        let id = UUID()
        let entry = SessionSnapshot.Entry(
            id: UUID(), title: "s", workingDirectory: "/p", accountID: id
        )
        var snapshot = SessionSnapshot()
        snapshot.sessions = [entry]
        let decoded = try JSONDecoder().decode(
            SessionSnapshot.self, from: try JSONEncoder().encode(snapshot)
        )
        XCTAssertEqual(decoded.sessions[0].accountID, id)
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `extra argument 'accountID' in call`

- [ ] **Step 3: Write the implementation**

In `Session`, after `agent`:

```swift
    /// Which login this tab runs as. **nil means the agent's built-in home**, not "the current
    /// default": every tab that predates accounts decodes as nil, and its conversation really
    /// does live in `~/.claude`, so it stays correct even after another account is dragged to
    /// the top. `PreferencesStore.resolvedAccountID(for:in:)` normalises it before use.
    var accountID: UUID?
```

Add `accountID: UUID? = nil` to `Session.init` and assign it. Mirror the field and its
`init` parameter on `SessionSnapshot.Entry` with the same doc comment reasoning as the other
optionals there. Then thread it through both directions in `SessionStore` wherever an `Entry` is
built from a `Session` and vice versa (`persist()` and `restore()`).

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionModel.swift Sources/FlightDeck/SessionPersistence.swift Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/SessionPersistenceTests.swift
git commit -m "feat: remember which account a tab runs as"
```

---

### Task 7: `environment(for:)` and `loginInvocation(for:)` on the adapter

**Files:**
- Modify: `Sources/FlightDeck/Agents/AgentAdapter.swift`
- Modify: `Sources/FlightDeck/Agents/ClaudeAdapter.swift`
- Modify: `Sources/FlightDeck/Agents/Codex/CodexAdapter.swift`
- Test: `Tests/FlightDeckTests/AgentAccountEnvironmentTests.swift`

**Interfaces:**
- Consumes: `AgentAccount`, `AgentID.homeEnvironmentKey`
- Produces: `AgentAdapter.environment(for:)`, `AgentAdapter.loginInvocation(for:)`, `LoginInvocation` (`command`, `inject`)

The spec writes the second as a tuple; a named struct keeps call sites readable and is
`Equatable` for tests.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/FlightDeckTests/AgentAccountEnvironmentTests.swift
import XCTest
@testable import FlightDeck

@MainActor
final class AgentAccountEnvironmentTests: XCTestCase {
    private func account(_ agent: AgentID) -> AgentAccount {
        AgentAccount(agent: agent, displayName: "Work", home: URL(fileURLWithPath: "/tmp/home"))
    }

    func testEachAgentNamesItsOwnVariable() {
        XCTAssertEqual(ClaudeAdapter().environment(for: account(.claude)), ["CLAUDE_CONFIG_DIR": "/tmp/home"])
        XCTAssertEqual(CodexAdapter(rpc: CodexRPC(transport: NullTransport())).environment(for: account(.codex)),
                       ["CODEX_HOME": "/tmp/home"])
    }

    /// Claude has no shell-level login subcommand — it authenticates inside a running session —
    /// so its invocation is a launch plus an injection, while codex's is a plain command.
    func testLoginInvocationsDifferInShape() {
        XCTAssertEqual(ClaudeAdapter().loginInvocation(for: account(.claude)),
                       LoginInvocation(command: "claude", inject: "/login"))
        XCTAssertEqual(CodexAdapter(rpc: CodexRPC(transport: NullTransport())).loginInvocation(for: account(.codex)),
                       LoginInvocation(command: "codex login", inject: nil))
    }
}
```

If `NullTransport` does not already exist in the test target, add it next to this test:

```swift
/// `CodexTransport` requires exactly two things — `send(_:)` and `onLine` — so a fake that
/// answers nothing is three lines. `CodexResumeTests` already has richer fakes
/// (`ScriptedTransport`, `SilentTransport`); reuse one of those instead if it is already
/// visible from this file rather than adding a fourth.
final class NullTransport: CodexTransport {
    var onLine: ((String) -> Void)?
    func send(_ line: String) {}
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `value of type 'ClaudeAdapter' has no member 'environment'`

- [ ] **Step 3: Write the implementation**

In `AgentAdapter.swift`:

```swift
/// How to sign an account in. Two fields rather than one because the two agents differ in
/// shape: codex has a `login` subcommand, claude authenticates inside a running session.
struct LoginInvocation: Equatable, Sendable {
    let command: String
    let inject: String?
}
```

Add to the `AgentAdapter` protocol, with defaults in the existing extension so no adapter is
forced to restate the obvious:

```swift
    /// The environment that binds a process to this account. Claude answers `CLAUDE_CONFIG_DIR`,
    /// codex `CODEX_HOME`; a third agent answers its own, and no caller ever learns which.
    func environment(for account: AgentAccount) -> [String: String]

    /// What to run, and what to type once it is up, to sign this account in.
    func loginInvocation(for account: AgentAccount) -> LoginInvocation
```

```swift
extension AgentAdapter {
    /// The variable's name is the only agent-specific part, and `AgentID` already knows it —
    /// so this default is correct for every agent whose home is selected by one variable, and
    /// an agent that needs more can still override.
    func environment(for account: AgentAccount) -> [String: String] {
        [account.agent.homeEnvironmentKey: account.home.path]
    }
}
```

Then implement `loginInvocation` on each adapter: `ClaudeAdapter` returns
`LoginInvocation(command: "claude", inject: "/login")`; `CodexAdapter` returns
`LoginInvocation(command: "codex login", inject: nil)`. Comment claude's with the reason it
carries an injection at all.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents Tests/FlightDeckTests/AgentAccountEnvironmentTests.swift
git commit -m "feat: let each agent name the variable that binds it to an account"
```

---

### Task 8: Key the adapter, runtime and codex-stack registries by account

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift`
- Create: `Sources/FlightDeck/Agents/AgentInstance.swift`
- Test: `Tests/FlightDeckTests/AgentInstanceTests.swift`

**Interfaces:**
- Consumes: `AgentAccount`, `PreferencesStore.resolvedAccountID(for:in:)`
- Produces: `AgentInstance` (`agent`, `account`), `SessionStore.adapter(for:account:)`, `.runtime(for:account:)`, `.overrideAdapter(_:for:account:)`, `.overrideRuntime(_:for:account:)`

`AgentInstance.account` is a **concrete** `UUID`: the optional lives only in
`Session.accountID`'s storage and is normalised away before any instance is keyed, so one home
can never map to two instances.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/FlightDeckTests/AgentInstanceTests.swift
import XCTest
@testable import FlightDeck

@MainActor
final class AgentInstanceTests: XCTestCase {
    /// `ClaudeAdapter` is a struct, so there is no identity to compare — the registry seam is
    /// the observable fact, mirroring the existing `hasCodexStackForTesting` style.
    func testTwoAccountsOnOneAgentGetTwoInstances() {
        let store = SessionStore(provider: nil, persistence: nil)
        _ = store.adapter(for: .claude, account: UUID())
        _ = store.adapter(for: .claude, account: UUID())
        XCTAssertEqual(store.adapterCountForTesting, 2, "an adapter is per (agent, account), not per agent")
    }

    /// A runtime is stateful — it holds the attachment `detach` has to find — so two instances
    /// for one key would start a watcher nothing can stop.
    func testOneAccountIsMemoizedNotRebuilt() {
        let store = SessionStore(provider: nil, persistence: nil)
        let a = UUID()
        XCTAssertTrue(store.runtime(for: .claude, account: a) === store.runtime(for: .claude, account: a))
        XCTAssertEqual(store.runtimeCountForTesting, 1)
    }

    func testAnOverrideIsScopedToItsAccount() {
        let store = SessionStore(provider: nil, persistence: nil)
        let a = UUID(), b = UUID()
        let fake = FakeRuntime()
        store.overrideRuntime(fake, for: .claude, account: a)
        XCTAssertTrue(store.runtime(for: .claude, account: a) === fake)
        XCTAssertFalse(store.runtime(for: .claude, account: b) === fake)
    }

    /// The invariant nil-normalisation exists to protect: one home, one stack. Two keys for
    /// `~/.claude` would put two app-servers on one `session_index.jsonl`.
    func testOneAccountYieldsOneCodexStack() {
        let store = SessionStore(provider: nil, persistence: nil)
        let a = UUID()
        _ = store.adapter(for: .codex, account: a)
        _ = store.runtime(for: .codex, account: a)
        XCTAssertEqual(store.codexStackCountForTesting, 1)
    }

    @MainActor final class FakeRuntime: AgentRuntime {
        func attach(_ binding: AgentBinding, onEvent: @escaping (AgentEvent) -> Void) {}
        func detach(_ binding: AgentBinding) {}
    }
}
```

Building a `CodexStack` spawns nothing — only `startCodex()` runs a process — so the last test
stays inside the "no committed test spawns an app-server" rule.

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `extra argument 'account' in call`

- [ ] **Step 3: Write the implementation**

```swift
// Sources/FlightDeck/Agents/AgentInstance.swift
import Foundation

/// One agent running as one account. The key for every registry that used to be keyed by
/// `AgentID` alone.
///
/// `account` is concrete on purpose. `Session.accountID` is optional in *storage* only —
/// normalising nil to the built-in account before keying is what stops one home carrying two
/// instances, which would put two `CodexStack`s on one `session_index.jsonl`.
struct AgentInstance: Hashable, Sendable {
    let agent: AgentID
    let account: UUID
}
```

In `SessionStore`:

- Change `adapters` and `runtimes` to `[AgentInstance: any AgentAdapter]` / `[AgentInstance: any AgentRuntime]`, dropping the `lazy` literal initialisers in favour of building each entry on first request (the claude adapter's wiring — `projectsRoot` and `injectRename` — moves into that builder unchanged).
- Change `codexStack: CodexStack?` to `codexStacks: [UUID: CodexStack]` and `codexHandshake` to `[UUID: Task<Void, Error>]`, both keyed by account id.
- `adapter(for:account:)` and `runtime(for:account:)` memoize on miss, exactly as `runtime(for:)` does today, keeping its comment about why a fresh instance per call would break `detach`.
- `makeCodexStackIfNeeded(account:)` builds and stores per account; `stopCodexIfUnused` narrows its predicate from "no codex tabs remain" to "no tabs on **this account** remain", and iterates only the stack for the account whose last tab closed.
- Keep `hasCodexStackForTesting` working by reporting `!codexStacks.isEmpty`, and add `codexStackCountForTesting`, `adapterCountForTesting` and `runtimeCountForTesting` alongside it, in the same "test seam, documented as such" style as the existing ones.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS, including the existing codex lifetime tests

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Agents/AgentInstance.swift Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/AgentInstanceTests.swift
git commit -m "feat: key adapters, runtimes and codex stacks by account as well as agent"
```

---

### Task 9: Derive every observation root from the account's home

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (adapter/runtime builders, `startStatusWatching`)
- Modify: `Sources/FlightDeck/Agents/Codex/CodexNameWatcher.swift`
- Modify: `Sources/FlightDeck/SessionFixture.swift` / `Sources/FlightDeck/FlightDeckApp.swift` (fixture retarget)
- Test: `Tests/FlightDeckTests/AccountObservationRootTests.swift`

**Interfaces:**
- Consumes: `AgentAccount.home`, `AgentInstance`
- Produces: `CodexNameWatcher.indexURL(forHome:)`, per-account `SessionStatusWatcher` instances

This is the task that fixes the two hazards in the spec's §2.1. Its tests are the most valuable
in the plan.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/FlightDeckTests/AccountObservationRootTests.swift
import XCTest
@testable import FlightDeck

@MainActor
final class AccountObservationRootTests: XCTestCase {
    /// Would have caught the shipped bug: the index URL was read from Flight Deck's OWN
    /// process environment, so every account tailed one file.
    func testCodexIndexComesFromTheAccountHomeNotTheProcessEnvironment() {
        let home = URL(fileURLWithPath: "/tmp/codex-work")
        XCTAssertEqual(
            CodexNameWatcher.indexURL(forHome: home),
            home.appendingPathComponent("session_index.jsonl")
        )
    }

    func testClaudeTranscriptPathsComeFromTheAccountHome() {
        // `SessionStore.preferences` is a `let` injected at init — it cannot be assigned after
        // construction, so every test here builds the store around its preferences.
        let preferences = PreferencesStore(persistence: nil)
        let work = AgentAccount(agent: .claude, displayName: "Work", home: URL(fileURLWithPath: "/tmp/claude-work"))
        preferences.preferences.storedAccounts = [work]
        let store = SessionStore(provider: nil, persistence: nil, preferences: preferences)

        let session = Session(title: "s", workingDirectory: "/p", accountID: work.id)
        let url = store.adapter(for: .claude, account: work.id).binding(for: session).transcriptURL
        XCTAssertEqual(url?.path.hasPrefix("/tmp/claude-work/projects/"), true)
    }

    func testTheStatusWatcherRootFollowsTheAccount() {
        let store = SessionStore(provider: nil, persistence: nil)
        let work = AgentAccount(agent: .claude, displayName: "W", home: URL(fileURLWithPath: "/tmp/claude-work"))
        XCTAssertEqual(store.statusRoot(for: work), URL(fileURLWithPath: "/tmp/claude-work/sessions"))
    }

    /// A fixture run that missed one account would write into the real `~/.claude/sessions` —
    /// the exact corruption `SessionFixture` exists to prevent.
    func testAFixtureRootOverridesEveryAccount() {
        let store = SessionStore(provider: nil, persistence: nil)
        let fixture = URL(fileURLWithPath: "/tmp/fixture")
        store.transcriptsRootOverride = fixture.appendingPathComponent("projects")
        store.statusRootOverride = fixture.appendingPathComponent("status")
        let a = AgentAccount(agent: .claude, displayName: "A", home: URL(fileURLWithPath: "/tmp/a"))
        let b = AgentAccount(agent: .claude, displayName: "B", home: URL(fileURLWithPath: "/tmp/b"))
        XCTAssertEqual(store.statusRoot(for: a), store.statusRoot(for: b))
        XCTAssertEqual(store.statusRoot(for: a), fixture.appendingPathComponent("status"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `type 'CodexNameWatcher' has no member 'indexURL'`

- [ ] **Step 3: Write the implementation**

- `CodexNameWatcher`: replace `defaultIndexURL`'s read of `ProcessInfo…["CODEX_HOME"]` with
  `static func indexURL(forHome home: URL) -> URL { home.appendingPathComponent("session_index.jsonl") }`.
  Keep a `defaultIndexURL` that calls it with `AgentID.codex.builtInHome` so existing callers and
  tests keep compiling, and replace its doc comment: the old one says it honours `CODEX_HOME`,
  which becomes false and is exactly the sort of stale claim this codebase pins down.
- The codex half is smaller than it looks: `CodexStack.init(clock:indexURL:)` and the store's
  `codexIndexURL` already exist, so this is changing what feeds that seam — `codexIndexURL`
  becomes `CodexNameWatcher.indexURL(forHome: account.home)`, computed where the stack is built
  for an account, rather than one store-wide value.
- `SessionStore`: rename the single `projectsRoot` / `sessionsRoot` fields to
  `transcriptsRootOverride: URL?` / `statusRootOverride: URL?` (nil = derive per account), and add:

```swift
    /// Where this account's claude transcripts live. The override is the fixture seam and wins
    /// for EVERY account — a fixture that retargeted only the built-in one would let a second
    /// account write into the developer's real `~/.claude`.
    func transcriptsRoot(for account: AgentAccount) -> URL {
        transcriptsRootOverride ?? account.home.appendingPathComponent("projects", isDirectory: true)
    }

    func statusRoot(for account: AgentAccount) -> URL {
        statusRootOverride ?? account.home.appendingPathComponent("sessions", isDirectory: true)
    }
```

- The claude adapter builder in `adapter(for:account:)` passes
  `projectsRoot: { [weak self] in self.map { $0.transcriptsRoot(for: account) } ?? ClaudeSession.defaultProjectsRoot }`.
- `startStatusWatching()` becomes per account: one `SessionStatusWatcher` per account with a
  live claude tab, created alongside its runtime and torn down with it, each feeding the same
  `applyRegistry` path. Keep the existing single-watcher guard shape, keyed by account id.
- `FlightDeckApp` keeps passing the fixture's `projectsRoot` / `statusRoot`, now into the two
  `*Override` fields.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS, including the existing `SessionFixtureTests`

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck Tests/FlightDeckTests/AccountObservationRootTests.swift
git commit -m "fix: derive every watcher root from the account, not from this process"
```

---

### Task 10: Launch under the account, and fail loudly when it is missing

**Files:**
- Modify: `Sources/FlightDeck/Preferences/PreferencesStore.swift` (`sessionEnvironment`)
- Modify: `Sources/FlightDeck/SessionStore.swift` (`insertSession`, `createSession`, `options(for:project:)`)
- Modify: `Sources/FlightDeck/Agents/Codex/CodexProcessTransport.swift`
- Modify: `Sources/FlightDeck/Agents/AgentLaunchFailureReporter.swift`
- Test: `Tests/FlightDeckTests/AccountLaunchTests.swift`

**Interfaces:**
- Consumes: `AgentAdapter.environment(for:)`, `PreferencesStore.account(for:project:)`
- Produces: `PreferencesStore.sessionEnvironment(for:inherited:)`, `AgentLaunchError.accountMissing(String)`, `.accountHomeMissing(String)`, `CodexProcessTransport.init(executable:home:)`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/FlightDeckTests/AccountLaunchTests.swift
import XCTest
@testable import FlightDeck

@MainActor
final class AccountLaunchTests: XCTestCase {
    func testTheAccountVariableIsMergedIntoTheSessionEnvironment() {
        let store = PreferencesStore(persistence: nil)
        store.preferences.shell.environment = ["FOO": "bar"]
        let account = AgentAccount(agent: .claude, displayName: "W", home: URL(fileURLWithPath: "/tmp/w"))
        let environment = store.sessionEnvironment(for: account, inherited: [:])
        XCTAssertEqual(environment["FOO"], "bar")
        XCTAssertEqual(environment["CLAUDE_CONFIG_DIR"], "/tmp/w")
    }

    /// The account wins over a variable the user typed into the Shell pane: the pane cannot be
    /// allowed to silently repoint a tab at another login.
    func testTheAccountOverridesAHandTypedVariable() {
        let store = PreferencesStore(persistence: nil)
        store.preferences.shell.environment = ["CLAUDE_CONFIG_DIR": "/tmp/typed"]
        let account = AgentAccount(agent: .claude, displayName: "W", home: URL(fileURLWithPath: "/tmp/w"))
        XCTAssertEqual(store.sessionEnvironment(for: account, inherited: [:])["CLAUDE_CONFIG_DIR"], "/tmp/w")
    }

    func testAMissingAccountIsReportedRatherThanSubstituted() async {
        let preferences = PreferencesStore(persistence: nil)
        preferences.preferences.storedAccounts = []
        preferences.preferences.storedProjectSettings = ["/p": ProjectSettings(accounts: [.claude: UUID()])]
        let store = SessionStore(provider: nil, persistence: nil, preferences: preferences)

        let result = await store.createSession(agent: .claude, in: "/p")
        guard case .failure(let error) = result else { return XCTFail("expected a failure") }
        XCTAssertEqual(error, .accountMissing("Claude"))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `extra argument 'for' in call` on `sessionEnvironment`

- [ ] **Step 3: Write the implementation**

- `sessionEnvironment(for account: AgentAccount?, inherited:)` keeps the existing
  `clearChildSessionMarker` behaviour and merges the adapter's `environment(for:)` **last**, so
  a hand-typed `CLAUDE_CONFIG_DIR` in the Shell pane cannot repoint a tab at another login.
  Because `PreferencesStore` must not depend on adapters, take the pair as
  `[account.agent.homeEnvironmentKey: account.home.path]` directly — the same expression the
  adapter default uses, and `AgentID` already owns the key.
- `AgentLaunchError` gains `case accountMissing(String)` and `case accountHomeMissing(String)`
  with `errorDescription`s naming the agent and, for the second, offering Relocate.
- `createSession(agent:in:at:)` resolves the account first and returns `.failure(.accountMissing…)`
  when it cannot, *before* minting a draft session or touching codex. It also checks
  `FileManager.default.fileExists` on the home and returns `.accountHomeMissing` when it is gone.
- `insertSession` passes the session's resolved account to `sessionEnvironment(for:)`.
- `options(for:project:)` collapses to `preferences?.resolvedOptions(for: agent, project: project) ?? …`,
  and its comment claiming codex has no project layer is deleted — it is false as of Task 5.
- `CodexProcessTransport.init(executable:home:)` stores the home and sets
  `process.environment = ProcessInfo.processInfo.environment.merging([AgentID.codex.homeEnvironmentKey: home.path]) { _, new in new }`
  in `start()`, so the app-server lives in the same home as the tabs it serves.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck Tests/FlightDeckTests/AccountLaunchTests.swift
git commit -m "feat: launch a tab in its account's home, and refuse when there isn't one"
```

---

### Task 11: External tools inherit the session's account

**Files:**
- Modify: `Sources/FlightDeck/Tools/ToolContext.swift`
- Modify: `Sources/FlightDeck/Tools/ToolTemplate.swift`
- Modify: `Sources/FlightDeck/Tools/ToolLauncher.swift` (or whichever type owns the launch call site holding a `ToolContext`)
- Modify: `Sources/FlightDeck/SessionStore.swift` (`toolContext()`)
- Test: `Tests/FlightDeckTests/ToolTemplateTests.swift` (extend)

**Interfaces:**
- Consumes: the resolved `AgentAccount` for the selected session
- Produces: `ToolContext.accountName`, `ToolContext.accountHome`, `ToolContext.accountEnvironment`

- [ ] **Step 1: Write the failing test**

```swift
// append to Tests/FlightDeckTests/ToolTemplateTests.swift
    func testAccountNamesExpandAndAreQuoted() {
        var context = ToolContext(
            workingDirectory: "/p", projectPath: "/p", projectName: "p", sessionTitle: "s",
            agent: .claude, conversationID: UUID()
        )
        context.accountName = "Work Account"
        context.accountHome = "/tmp/claude work"
        XCTAssertEqual(
            ToolTemplate.expand("x ${account} ${accountHome}", in: context),
            "x 'Work Account' '/tmp/claude work'"
        )
    }

    /// Unknown names still reach the login shell verbatim — which is what makes the account's
    /// own variables usable without any template change.
    func testTheAccountVariableIsLeftForTheShell() {
        let context = ToolContext(
            workingDirectory: "/p", projectPath: "/p", projectName: "p", sessionTitle: "s",
            agent: .claude, conversationID: UUID()
        )
        XCTAssertEqual(ToolTemplate.expand("ls ${CLAUDE_CONFIG_DIR}", in: context), "ls ${CLAUDE_CONFIG_DIR}")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: FAIL — `${account}` is left literal because it is not yet a known name

- [ ] **Step 3: Write the implementation**

- `ToolContext` gains `var accountName: String?`, `var accountHome: String?` and
  `var accountEnvironment: [String: String] = [:]`, all defaulted so existing call sites compile.
- `ToolTemplate.knownNames` gains `"account"` and `"accountHome"`; `value(for:in:)` returns them.
  Both go through `quote`, so a home containing a space stays one argument.
- `SessionStore.toolContext()` fills all three from the resolved account.
- The launch call site merges `context.accountEnvironment` over the launcher's environment. It
  cannot go inside `ToolLauncher.configured(_:)`'s `environment` closure — that closure takes no
  session — so it is applied where the `ToolContext` is already in hand. Leave a comment saying
  exactly that, because the closure is the obvious-looking wrong place.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Tools Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/ToolTemplateTests.swift
git commit -m "feat: run a tool as the account its session runs as"
```

---

### Task 12: Accounts list in the Agents tab

**Files:**
- Create: `Sources/FlightDeck/Preferences/UI/AccountsSection.swift`
- Create: `Sources/FlightDeck/Preferences/UI/AddAccountSheet.swift`
- Modify: `Sources/FlightDeck/Preferences/UI/AgentsSettingsTab.swift`
- Test: `Tests/FlightDeckTests/AccountsSectionTests.swift`

**Interfaces:**
- Consumes: `PreferencesStore` account mutators (Task 5), `AccountDirectory`
- Produces: `AccountsSection(preferences:agent:)`, `AddAccountSheet`, `AccountDraft.defaultHome(for:name:)`

Views are hard to unit-test; the testable part is the draft's path derivation and the
enable/disable predicates, so those live outside the view body.

- [ ] **Step 1: Write the failing test**

```swift
// Tests/FlightDeckTests/AccountsSectionTests.swift
import XCTest
@testable import FlightDeck

@MainActor
final class AccountsSectionTests: XCTestCase {
    func testDefaultHomeIsDerivedFromTheNameAndAgent() {
        let home = AccountDraft.defaultHome(for: .claude, name: "Field Wealth")
        XCTAssertEqual(home.lastPathComponent, ".claude-field-wealth")
        XCTAssertEqual(AccountDraft.defaultHome(for: .codex, name: "Work").lastPathComponent, ".codex-work")
    }

    func testTheBuiltInAccountCannotBeRemoved() {
        let builtIn = AgentAccount(agent: .claude, displayName: "D", home: AgentID.claude.builtInHome)
        XCTAssertFalse(AccountsSection.canRemove(builtIn, boundAccountIDs: []))
    }

    func testAnAccountWithLiveSessionsCannotBeRemovedOrRelocated() {
        let work = AgentAccount(agent: .claude, displayName: "W", home: URL(fileURLWithPath: "/tmp/w"))
        XCTAssertFalse(AccountsSection.canRemove(work, boundAccountIDs: [work.id]))
        XCTAssertTrue(AccountsSection.canRemove(work, boundAccountIDs: []))
    }

    /// Two accounts on one home would put two `CodexStack`s on one `session_index.jsonl`, so the
    /// sheet refuses before anything is created rather than failing later at launch.
    func testTheAddSheetRefusesAHomeAnotherAccountAlreadyUses() {
        let store = PreferencesStore(persistence: nil)
        let taken = AgentAccount(agent: .claude, displayName: "W", home: URL(fileURLWithPath: "/tmp/w"))
        store.preferences.storedAccounts = [taken]
        XCTAssertEqual(
            AccountDraft.validate(home: URL(fileURLWithPath: "/tmp/w"), editing: nil, in: store),
            .homeAlreadyUsed
        )
        XCTAssertEqual(
            AccountDraft.validate(home: URL(fileURLWithPath: "/tmp/other"), editing: nil, in: store),
            .ok
        )
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `cannot find 'AccountDraft' in scope`

- [ ] **Step 3: Write the implementation**

`AccountDraft` (in `AddAccountSheet.swift`) holds `name`, `home`, and the derivation:

```swift
    /// `~/.claude-field-wealth` for "Field Wealth". Lowercased, non-alphanumerics collapsed to
    /// single dashes, so a typed display name yields a path that is legal and predictable.
    static func defaultHome(for agent: AgentID, name: String) -> URL {
        let slug = name.lowercased()
            .map { $0.isLetter || $0.isNumber ? String($0) : "-" }
            .joined()
            .split(separator: "-").joined(separator: "-")
        let base = agent.builtInHome.lastPathComponent
        return URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(slug.isEmpty ? base : "\(base)-\(slug)", isDirectory: true)
    }
```

`AccountDraft.validate(home:editing:in:)` returns an `enum Validation { case ok, homeAlreadyUsed }`
by calling `store.homeIsTaken(home, excluding: editing)` (Task 5). Both the Add sheet's confirm
button and Relocate… gate on it, which is where §8's duplicate-home rejection actually lands.

**Sign In** is what makes an added account usable, and it needs no new machinery: read the
account's `LoginInvocation` from `store.adapter(for:account:)` (Task 7), open an ordinary session
tab on that account in the frontmost project with `command` as the initial input, and — when
`inject` is non-nil — send it through the existing text-injection path once the tab is up, the
same route `ClaudeAdapter.injectRename` already uses. **Sign In Again** in the context menu calls
exactly the same function. If no project is open, open the tab in the account's own home
directory rather than refusing.

`AccountsSection` renders the listbox described in the spec §7.1: a `List` of
`preferences.preferences.accounts(for: agent)` with `.onMove` → `moveAccounts(forAgent:…)`,
`+` / `−` beneath, a row showing `displayName` over `email · organization`, the caption
*"Projects that haven't chosen an account use the topmost one."*, inline rename on double-click,
and a context menu with Relocate…, Sign In Again, Reveal in Finder, Refresh Identity. Removal
opens a confirm with **Remove from Flight Deck** as the default and **Also delete files…** as a
second, separately-confirmed destructive action. Expose the predicates as static functions so the
tests above can reach them:

```swift
    /// The built-in account is what `Session.accountID == nil` resolves to, so removing it would
    /// strand every legacy tab. Bound accounts are refused for the ordinary reason: their tabs
    /// are pointing at conversations inside that home right now.
    static func canRemove(_ account: AgentAccount, boundAccountIDs: Set<UUID>) -> Bool {
        !account.isBuiltIn && !boundAccountIDs.contains(account.id)
    }
```

Add the section to `AgentsSettingsTab`'s detail pane, below the existing per-agent options pane.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Preferences/UI Tests/FlightDeckTests/AccountsSectionTests.swift
git commit -m "feat: manage an agent's accounts from its preferences pane"
```

---

### Task 13: Restructure the Projects tab

**Files:**
- Modify: `Sources/FlightDeck/Preferences/UI/ProjectsSettingsTab.swift`
- Test: `Tests/FlightDeckTests/ProjectsSettingsTabTests.swift`

**Interfaces:**
- Consumes: `PreferencesStore.projectSettings(_:)` / `.setProjectSettings(_:_:)` / `.account(for:project:)`
- Produces: `ProjectsSettingsTab.hiddenOverrideSummary(_:excluding:)`

- [ ] **Step 1: Write the failing test**

```swift
// Tests/FlightDeckTests/ProjectsSettingsTabTests.swift
import XCTest
@testable import FlightDeck

@MainActor
final class ProjectsSettingsTabTests: XCTestCase {
    /// With `<Use global settings>` selected the editor is hidden, but the overrides are still
    /// in force — so the pane has to say so, or they are invisible and active.
    func testHiddenOverridesAreNamed() {
        let settings = ProjectSettings(options: [.codex: .codex(CodexThreadOptions(sandbox: "read-only"))])
        XCTAssertEqual(
            ProjectsSettingsTab.hiddenOverrideSummary(settings, excluding: nil),
            "Codex has project overrides. Select Codex to edit them."
        )
    }

    func testTheEditedAgentIsNotListedAsHidden() {
        let settings = ProjectSettings(options: [.codex: .codex(CodexThreadOptions(sandbox: "read-only"))])
        XCTAssertNil(ProjectsSettingsTab.hiddenOverrideSummary(settings, excluding: .codex))
    }

    func testEmptyOptionsAreNotAnOverride() {
        XCTAssertNil(ProjectsSettingsTab.hiddenOverrideSummary(
            ProjectSettings(options: [.codex: .codex(CodexThreadOptions())]), excluding: nil
        ))
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `type 'ProjectsSettingsTab' has no member 'hiddenOverrideSummary'`

- [ ] **Step 3: Write the implementation**

The detail pane becomes three sections in order: an **Agent** picker whose first entry is
`<Use global settings>` (tag `nil`) followed by each agent; an **Account** picker rendered only
when `preferences.preferences.accounts(for: selectedAgent).count > 1`, offering
*Default (<name>)* plus each account; and the agent-appropriate **Options** editor bound through
`setProjectSettings`. The project list's source becomes
`Set(open).union(preferences.configuredProjectPaths)`, and its badge reads from
`projectSettings(path).isEmpty`. **Remove Overrides** clears the whole record. The empty state's
copy stops naming Claude.

```swift
    /// Overrides belonging to an agent the pane is not currently showing. They stay in force
    /// regardless of the dropdown — the dropdown picks what you edit and what ⌘N launches, not
    /// whether an override applies — so leaving them unmentioned would make them invisible and
    /// active at the same time.
    static func hiddenOverrideSummary(_ settings: ProjectSettings, excluding shown: AgentID?) -> String? {
        let hidden = AgentID.allCases.filter { agent in
            agent != shown && !(settings.options[agent]?.isEmpty ?? true)
        }
        guard !hidden.isEmpty else { return nil }
        let names = hidden.map(\.displayName)
        return "\(names.joined(separator: " and ")) \(hidden.count == 1 ? "has" : "have") project overrides. Select \(names.joined(separator: " or ")) to edit them."
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Preferences/UI/ProjectsSettingsTab.swift Tests/FlightDeckTests/ProjectsSettingsTabTests.swift
git commit -m "feat: give a project an agent, an account and that agent's options"
```

---

### Task 14: New Session dropdown and the sidebar marker

**Files:**
- Modify: `Sources/FlightDeck/Agents/NewSessionAffordance.swift`
- Modify: `Sources/FlightDeck/SessionSidebar.swift`
- Modify: `Sources/FlightDeck/SessionCommands.swift`
- Modify: `Sources/FlightDeck/SidebarRow.swift`
- Test: `Tests/FlightDeckTests/NewSessionAffordanceTests.swift` (extend)

**Interfaces:**
- Consumes: `PreferencesStore.agentOrder(forProject:)`, `.account(for:project:)`
- Produces: `NewSessionAffordance.menu(agents:accounts:resolved:)` returning `[MenuEntry]`

- [ ] **Step 1: Write the failing test**

```swift
// append to Tests/FlightDeckTests/NewSessionAffordanceTests.swift
    /// Shortcuts follow the project's order, so ⌘N is always the agent this project uses.
    func testSlotsFollowTheProjectOrder() {
        let order = [
            AgentSettings(id: .codex, options: .codex(CodexThreadOptions())),
            AgentSettings(id: .claude, options: .claude(FlagSet())),
        ]
        XCTAssertEqual(NewSessionAffordance.slots(for: order).first?.agent, .codex)
    }

    /// An agent with one account contributes one flat row; more than one nests them, so the
    /// common case does not grow a submenu.
    func testTheMenuNestsOnlyWhenAnAgentHasSeveralAccounts() {
        let one = AgentAccount(agent: .claude, displayName: "Personal", home: URL(fileURLWithPath: "/a"))
        let two = AgentAccount(agent: .claude, displayName: "Work", home: URL(fileURLWithPath: "/b"))
        let flat = NewSessionAffordance.menu(
            agents: [AgentSettings(id: .claude, options: .claude(FlagSet()))],
            accounts: [one], resolved: [.claude: one.id]
        )
        XCTAssertEqual(flat, [.agent(.claude, account: one.id, isResolved: true)])

        let nested = NewSessionAffordance.menu(
            agents: [AgentSettings(id: .claude, options: .claude(FlagSet()))],
            accounts: [one, two], resolved: [.claude: two.id]
        )
        XCTAssertEqual(nested, [
            .submenu(.claude, [
                .agent(.claude, account: one.id, isResolved: false),
                .agent(.claude, account: two.id, isResolved: true),
            ])
        ])
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `type 'NewSessionAffordance' has no member 'menu'`

- [ ] **Step 3: Write the implementation**

Add to `NewSessionAffordance`:

```swift
    /// One entry per agent, nesting its accounts only when it has more than one. The checkmark
    /// rides on `isResolved` so the menu shows what ⌘N would actually do in this project.
    enum MenuEntry: Equatable {
        case agent(AgentID, account: UUID, isResolved: Bool)
        indirect case submenu(AgentID, [MenuEntry])
    }

    static func menu(
        agents: [AgentSettings], accounts: [AgentAccount], resolved: [AgentID: UUID]
    ) -> [MenuEntry] {
        agents.compactMap { settings in
            let mine = accounts.filter { $0.agent == settings.id }
            guard !mine.isEmpty else { return nil }
            let rows = mine.map {
                MenuEntry.agent(settings.id, account: $0.id, isResolved: resolved[settings.id] == $0.id)
            }
            return mine.count == 1 ? rows[0] : .submenu(settings.id, rows)
        }
    }
```

Then: the sidebar's New Session button gets a trailing chevron rendering that menu; the app's
New Session menu item renders the same — it is SwiftUI (`SessionCommands.swift`), not AppKit;
`258dc2f` never touched it (that commit built the *Tools* menu, over
`AppDelegate.swift`/`RootView.swift`/`Sources/FlightDeck/Tools/*`). `SessionCommands` and the
sidebar read `agentOrder(forProject:)` for the selected project instead of `preferences.agents`,
which is how the per-project ordering reaches this menu; and `SidebarRow` shows a small account
marker when a session's resolved account differs from its project's.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck Tests/FlightDeckTests/NewSessionAffordanceTests.swift
git commit -m "feat: choose an account when starting a session, and show when one differs"
```

---

### Task 15: Correct the documentation this work falsifies

**Files:**
- Modify: `docs/HANDOFF-agent-adapters.md`
- Modify: `docs/ARCHITECTURE.md`
- Modify: `docs/FOLLOWUPS.md`

**Interfaces:**
- Consumes: everything above
- Produces: no code

- [ ] **Step 1: Correct the adapters handoff**

Its `AgentRuntime` row reads "observation. App-wide **per agent kind**, not per session — one
status registry for claude, one app-server for codex, N tabs each". Change it to per
(agent, account), and note that `CodexStack` is now one per account.

- [ ] **Step 2: Correct the architecture doc**

Update the observation section wherever it names `~/.claude/projects` or `~/.claude/sessions` as
app-wide constants: they are now derived from the launching session's account home.

- [ ] **Step 3: Record what accounts left behind**

Add to `docs/FOLLOWUPS.md`: relocating an account is blocked while any of its sessions are open
(the simple rule, not a migration); "Scan for Accounts…" is the only way to pick up a home
created after first launch; and codex's `-p` config profiles remain unimplemented and unrelated
to accounts.

- [ ] **Step 4: Verify the full suite one last time**

Run: `./scripts/test-unit.sh`
Expected: PASS, zero failures. Report the actual counts.

- [ ] **Step 5: Commit**

```bash
git add docs
git commit -m "docs: record that observation is now per account, not per agent"
```

---

## Manual verification

After Task 15, once, by hand — the automated suite deliberately never touches a real account:

1. Open Preferences → Agents → Claude. `nate@radify.io` and `nate@fieldwealth.ai` should both be
   listed, discovered from `~/.claude` and `~/.claude-fieldwealth` with their emails filled in.
2. Preferences → Projects → this repo. Set Agent to Claude, Account to `nate@fieldwealth.ai`.
3. Open a new session here. Confirm **the sidebar shows a live activity glyph** and that an
   in-session `/rename` **updates the tab title**. Those two signals are the whole point: they
   only work if the status registry and transcript were read from `~/.claude-fieldwealth`
   rather than `~/.claude`.
4. Quit and relaunch. The tab restores on the same account and keeps its status.
5. Set the project back to `<Use global settings>` and confirm a new tab opens on
   `nate@radify.io` while the existing tab stays on the work account.
