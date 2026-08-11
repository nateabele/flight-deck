# Preferences Pane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a three-tab Preferences window (⌘,) that configures the `claude` startup options for new sessions, with per-project overrides and a freeform command field kept in two-way sync with the controls.

**Architecture:** A declarative `FlagSpec` catalog drives everything — the parser, the serializer, the merge, the diagnostics, and the generically-rendered UI rows. The pure core (`tokenize → parse → serialize → merge`) is built and tested first with no UI at all; the SwiftUI layer is added on top and holds no parsing logic of its own. Preferences persist to `UserDefaults` behind a `PreferencesPersisting` protocol mirroring the existing `SessionPersisting` pair.

**Tech Stack:** Swift 5 language mode (Swift 6.3 compiler), SwiftUI + AppKit (`NSViewRepresentable` over `NSTextView`), XCTest, XcodeGen.

**Spec:** `docs/superpowers/specs/2026-08-11-preferences-design.md`

## Global Constraints

- **Swift 5 language mode** (`SWIFT_VERSION: "5.0"` in `project.yml`). Do not add Swift-6 strict-concurrency annotations that break the vendored Ghostty sources. Do not change this setting.
- **New files need no `project.yml` edit.** The `FlightDeck` target globs `Sources/FlightDeck`, and `scripts/test-unit.sh` runs `xcodegen generate` on every invocation. Same for `Tests/FlightDeckTests`.
- **Unit tests run with `./scripts/test-unit.sh`** (headless, in-process; see the script's header comment for why `xcodebuild test` cannot be used). To run one class, append `-XCTest <ClassName>` to the final `xcrun xctest` invocation, or just run the whole suite — it is fast.
- **All build commands need `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.** The scripts export it themselves. Do **not** run `sudo xcode-select`.
- **Test idiom:** `import XCTest` + `@testable import FlightDeck`, `final class XTests: XCTestCase`. Match `Tests/FlightDeckTests/ShellResolverTests.swift`.
- **Types touching SwiftUI or `SessionStore` are `@MainActor`.** Pure value types and `enum` namespaces are not.
- **Every value placed on the command line goes through `ClaudeFlagQuoting.quoteIfNeeded`.** Never reuse `ClaudeSession.sanitizedName` for flag values — it strips `$` and backticks, which corrupts legitimate prompt text.
- **Commit after every task** with a `feat:`/`test:`/`refactor:` prefix, matching the existing log style.

## File Structure

**Create — pure core (no UI):**

| File | Responsibility |
|---|---|
| `Sources/FlightDeck/Preferences/FlagSet.swift` | `FlagValue`, `FlagSet`, `Diagnostic` value types |
| `Sources/FlightDeck/Preferences/ClaudeFlagQuoting.swift` | `tokenize` + `quoteIfNeeded` — the shell-syntax layer |
| `Sources/FlightDeck/Preferences/ClaudeFlagCatalog.swift` | `FlagSpec`, `Kind`, `Section`, and the 36-entry table |
| `Sources/FlightDeck/Preferences/ClaudeFlagParser.swift` | `String → (FlagSet, [Diagnostic])` |
| `Sources/FlightDeck/Preferences/ClaudeFlagSerializer.swift` | `FlagSet → String` |
| `Sources/FlightDeck/Preferences/FlagSetMerge.swift` | per-flag merge of project over global |
| `Sources/FlightDeck/Preferences/FlagDiagnostics.swift` | cross-flag validation rules |
| `Sources/FlightDeck/Preferences/Preferences.swift` | `Preferences`, `ShellPreferences` |
| `Sources/FlightDeck/Preferences/PreferencesStore.swift` | `PreferencesPersisting`, `UserDefaultsPreferencesPersistence`, `PreferencesStore` |

**Create — UI:**

| File | Responsibility |
|---|---|
| `Sources/FlightDeck/Preferences/UI/LockedPrefixCommandField.swift` | `NSTextView` with an immutable prefix |
| `Sources/FlightDeck/Preferences/UI/FlagRow.swift` | one generic row rendering any `FlagSpec.Kind` |
| `Sources/FlightDeck/Preferences/UI/FlagEditor.swift` | sectioned control list + command field + diagnostics; shared by the Claude and Projects tabs |
| `Sources/FlightDeck/Preferences/UI/ClaudeSettingsTab.swift` | global tab |
| `Sources/FlightDeck/Preferences/UI/ProjectsSettingsTab.swift` | project list + override editor |
| `Sources/FlightDeck/Preferences/UI/ShellSettingsTab.swift` | shell path, env vars, marker scrub |
| `Sources/FlightDeck/Preferences/UI/PreferencesView.swift` | the `TabView` |

**Modify:** `ClaudeSession.swift` (flag-aware commands), `ShellResolver.swift` (override param), `SessionStore.swift` (resolve + pass flags and env), `FlightDeckApp.swift` (own `PreferencesStore`, add `Settings` scene).

**Tests:** one file per pure component under `Tests/FlightDeckTests/`, plus `UITests/FlightDeckUITests/PreferencesUITests.swift`.

---

### Task 1: Value types and the shell-syntax layer

The tokenizer and quoter are the foundation of the round-trip invariant. Built and tested with no catalog and no parser.

**Files:**
- Create: `Sources/FlightDeck/Preferences/FlagSet.swift`
- Create: `Sources/FlightDeck/Preferences/ClaudeFlagQuoting.swift`
- Test: `Tests/FlightDeckTests/ClaudeFlagQuotingTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `FlagValue`, `FlagSet`, `Diagnostic`, `ClaudeFlagQuoting.tokenize(_:) throws -> [String]`, `ClaudeFlagQuoting.quoteIfNeeded(_:) -> String`, `ClaudeFlagQuoting.TokenizeError.unterminatedQuote`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/ClaudeFlagQuotingTests.swift`:

```swift
import XCTest
@testable import FlightDeck

final class ClaudeFlagQuotingTests: XCTestCase {
    // MARK: tokenize

    func testSplitsOnWhitespace() throws {
        XCTAssertEqual(try ClaudeFlagQuoting.tokenize("--model opus"), ["--model", "opus"])
    }

    func testCollapsesRunsOfWhitespaceAndTrims() throws {
        XCTAssertEqual(try ClaudeFlagQuoting.tokenize("  --a   --b  "), ["--a", "--b"])
    }

    func testSingleQuotesPreserveSpacesAndAreLiteral() throws {
        XCTAssertEqual(
            try ClaudeFlagQuoting.tokenize("--name 'my session $x'"),
            ["--name", "my session $x"]
        )
    }

    func testDoubleQuotesPreserveSpaces() throws {
        XCTAssertEqual(try ClaudeFlagQuoting.tokenize("--name \"a b\""), ["--name", "a b"])
    }

    func testBackslashEscapeInsideDoubleQuotes() throws {
        XCTAssertEqual(try ClaudeFlagQuoting.tokenize("\"a\\\"b\""), ["a\"b"])
    }

    func testBackslashEscapeOutsideQuotes() throws {
        XCTAssertEqual(try ClaudeFlagQuoting.tokenize("a\\ b"), ["a b"])
    }

    func testAdjacentQuotedRunsConcatenateIntoOneToken() throws {
        XCTAssertEqual(try ClaudeFlagQuoting.tokenize("'a'b'c'"), ["abc"])
    }

    func testEmptyQuotedStringIsAToken() throws {
        XCTAssertEqual(try ClaudeFlagQuoting.tokenize("--tools ''"), ["--tools", ""])
    }

    func testEmptyInputProducesNoTokens() throws {
        XCTAssertEqual(try ClaudeFlagQuoting.tokenize("   "), [])
    }

    func testUnterminatedSingleQuoteThrows() {
        XCTAssertThrowsError(try ClaudeFlagQuoting.tokenize("--name 'oops")) { error in
            XCTAssertEqual(error as? ClaudeFlagQuoting.TokenizeError, .unterminatedQuote)
        }
    }

    func testUnterminatedDoubleQuoteThrows() {
        XCTAssertThrowsError(try ClaudeFlagQuoting.tokenize("--name \"oops")) { error in
            XCTAssertEqual(error as? ClaudeFlagQuoting.TokenizeError, .unterminatedQuote)
        }
    }

    // MARK: quoteIfNeeded

    func testSafeValueIsNotQuoted() {
        XCTAssertEqual(ClaudeFlagQuoting.quoteIfNeeded("opus"), "opus")
        XCTAssertEqual(ClaudeFlagQuoting.quoteIfNeeded("../shared/dir"), "../shared/dir")
        XCTAssertEqual(ClaudeFlagQuoting.quoteIfNeeded("a-b_c.d:e=f@g%h+i,j"), "a-b_c.d:e=f@g%h+i,j")
    }

    func testValueWithSpaceIsSingleQuoted() {
        XCTAssertEqual(ClaudeFlagQuoting.quoteIfNeeded("my session"), "'my session'")
    }

    func testShellMetacharactersAreQuotedNotStripped() {
        XCTAssertEqual(ClaudeFlagQuoting.quoteIfNeeded("$HOME"), "'$HOME'")
        XCTAssertEqual(ClaudeFlagQuoting.quoteIfNeeded("a;b"), "'a;b'")
    }

    func testEmbeddedSingleQuoteIsEscaped() {
        XCTAssertEqual(ClaudeFlagQuoting.quoteIfNeeded("it's"), "'it'\\''s'")
    }

    func testEmptyStringBecomesEmptyQuotes() {
        XCTAssertEqual(ClaudeFlagQuoting.quoteIfNeeded(""), "''")
    }

    // MARK: the invariant these two exist to uphold

    func testQuoteThenTokenizeRoundTripsIncludingInjectionAttempt() throws {
        let hostile = "'; rm -rf ~; '"
        let quoted = ClaudeFlagQuoting.quoteIfNeeded(hostile)
        XCTAssertEqual(try ClaudeFlagQuoting.tokenize(quoted), [hostile])
    }

    func testQuoteThenTokenizeRoundTripsAcrossAwkwardValues() throws {
        for value in ["a b", "", "$(whoami)", "back\\slash", "new\nline", "quote\"dq", "it's"] {
            let quoted = ClaudeFlagQuoting.quoteIfNeeded(value)
            XCTAssertEqual(try ClaudeFlagQuoting.tokenize(quoted), [value], "failed for \(value)")
        }
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `cannot find 'ClaudeFlagQuoting' in scope`.

- [ ] **Step 3: Write `FlagSet.swift`**

```swift
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
```

- [ ] **Step 4: Write `ClaudeFlagQuoting.swift`**

```swift
import Foundation

/// The shell-syntax boundary: turning a command-line string into tokens, and a value
/// back into a token that survives the shell.
///
/// This is a security boundary, not a formatting detail. Flag values reach a live pty
/// as part of a command line, so `quoteIfNeeded` must make any value a single literal
/// argument. Quoting — not stripping — is the tool: stripping `$` and backticks out of
/// a `--system-prompt` would corrupt legitimate content.
enum ClaudeFlagQuoting {
    enum TokenizeError: Error, Equatable { case unterminatedQuote }

    /// Characters safe to emit unquoted. Anything else forces single quotes.
    private static let safe = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_./:=@%+,"
    )

    /// POSIX-ish word splitting. Adjacent quoted and unquoted runs concatenate into one
    /// token (`'a'b` → `ab`), matching `sh`.
    static func tokenize(_ input: String) throws -> [String] {
        var tokens: [String] = []
        var current = ""
        var started = false          // distinguishes `''` (a real empty token) from no token
        var iterator = input.startIndex

        func flush() {
            if started { tokens.append(current) }
            current = ""
            started = false
        }

        while iterator < input.endIndex {
            let character = input[iterator]
            switch character {
            case " ", "\t", "\n", "\r":
                flush()
            case "'":
                started = true
                iterator = input.index(after: iterator)
                var closed = false
                while iterator < input.endIndex {
                    if input[iterator] == "'" { closed = true; break }
                    current.append(input[iterator])
                    iterator = input.index(after: iterator)
                }
                guard closed else { throw TokenizeError.unterminatedQuote }
            case "\"":
                started = true
                iterator = input.index(after: iterator)
                var closed = false
                while iterator < input.endIndex {
                    let inner = input[iterator]
                    if inner == "\"" { closed = true; break }
                    if inner == "\\" {
                        let next = input.index(after: iterator)
                        // Only these four are special inside double quotes; a backslash
                        // before anything else is literal, as in sh.
                        if next < input.endIndex, "\"\\$`".contains(input[next]) {
                            current.append(input[next])
                            iterator = input.index(after: next)
                            continue
                        }
                    }
                    current.append(inner)
                    iterator = input.index(after: iterator)
                }
                guard closed else { throw TokenizeError.unterminatedQuote }
            case "\\":
                started = true
                let next = input.index(after: iterator)
                if next < input.endIndex {
                    current.append(input[next])
                    iterator = next
                } else {
                    current.append(character)
                }
            default:
                started = true
                current.append(character)
            }
            if iterator < input.endIndex { iterator = input.index(after: iterator) }
        }
        flush()
        return tokens
    }

    /// Single-quotes `value` when it contains anything outside `safe`, rewriting embedded
    /// `'` as `'\''`. Leaves ordinary values (`opus`, `../dir`) unquoted so the command
    /// field stays readable.
    static func quoteIfNeeded(_ value: String) -> String {
        guard !value.isEmpty else { return "''" }
        let needsQuoting = value.unicodeScalars.contains { !safe.contains($0) }
        guard needsQuoting else { return value }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: all `ClaudeFlagQuotingTests` pass, existing suites still pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Preferences/FlagSet.swift \
        Sources/FlightDeck/Preferences/ClaudeFlagQuoting.swift \
        Tests/FlightDeckTests/ClaudeFlagQuotingTests.swift
git commit -m "feat: flag value types and shell tokenizer/quoter"
```

---

### Task 2: The flag catalog

**Files:**
- Create: `Sources/FlightDeck/Preferences/ClaudeFlagCatalog.swift`
- Test: `Tests/FlightDeckTests/ClaudeFlagCatalogTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1 (pure table).
- Produces: `FlagSpec`, `FlagSpec.Kind`, `FlagSpec.Section`, `ClaudeFlagCatalog.all: [FlagSpec]`, `ClaudeFlagCatalog.spec(for:) -> FlagSpec?`, `ClaudeFlagCatalog.appManaged: Set<String>`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/ClaudeFlagCatalogTests.swift`:

```swift
import XCTest
@testable import FlightDeck

final class ClaudeFlagCatalogTests: XCTestCase {
    func testLooksUpByCanonicalName() {
        XCTAssertEqual(ClaudeFlagCatalog.spec(for: "--model")?.canonical, "--model")
    }

    func testLooksUpByAlias() {
        XCTAssertEqual(ClaudeFlagCatalog.spec(for: "--allowed-tools")?.canonical, "--allowedTools")
    }

    func testLooksUpByNegatedFormOfNegatableFlag() {
        XCTAssertEqual(ClaudeFlagCatalog.spec(for: "--no-chrome")?.canonical, "--chrome")
    }

    func testUnknownFlagHasNoSpec() {
        XCTAssertNil(ClaudeFlagCatalog.spec(for: "--not-a-real-flag"))
    }

    func testAppManagedFlagsAreNotInTheCatalog() {
        for name in ClaudeFlagCatalog.appManaged {
            XCTAssertNil(ClaudeFlagCatalog.spec(for: name), "\(name) must not be user-editable")
        }
    }

    func testPrintOnlyAndSessionIdentityFlagsAreExcluded() {
        for name in ["--print", "--output-format", "--resume", "--continue", "--cloud", "--bg"] {
            XCTAssertNil(ClaudeFlagCatalog.spec(for: name), "\(name) must not have a control")
        }
    }

    func testCanonicalNamesAreUnique() {
        let names = ClaudeFlagCatalog.all.map(\.canonical)
        XCTAssertEqual(names.count, Set(names).count)
    }

    func testEverySpecIsReachableByItsOwnCanonicalName() {
        for spec in ClaudeFlagCatalog.all {
            XCTAssertEqual(ClaudeFlagCatalog.spec(for: spec.canonical)?.canonical, spec.canonical)
        }
    }

    func testEveryAliasResolvesToItsOwnSpec() {
        for spec in ClaudeFlagCatalog.all {
            for alias in spec.aliases {
                XCTAssertEqual(ClaudeFlagCatalog.spec(for: alias)?.canonical, spec.canonical)
            }
        }
    }

    func testCatalogCoversTheThirtySixSpecifiedOptions() {
        XCTAssertEqual(ClaudeFlagCatalog.all.count, 36)
    }

    func testEverySectionHasAtLeastOneFlag() {
        for section in FlagSpec.Section.allCases {
            XCTAssertFalse(
                ClaudeFlagCatalog.all.filter { $0.section == section }.isEmpty,
                "\(section) is empty"
            )
        }
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `cannot find 'ClaudeFlagCatalog' in scope`.

- [ ] **Step 3: Write `ClaudeFlagCatalog.swift`**

```swift
import Foundation

/// One `claude` option Flight Deck models with a control.
struct FlagSpec: Equatable {
    /// How the flag's value is written, and therefore how its control renders.
    enum Kind: Equatable {
        /// Bare presence: `--verbose`.
        case toggle
        /// Presence or explicit negation: `--chrome` / `--no-chrome`.
        case negatable(off: String)
        /// A fixed set of values. `allowsCustom` adds a "Custom…" entry with a text
        /// field — `--effort` is closed, but `--model` takes any full model name and
        /// `--autocompact` takes `auto` or a token count.
        case choice([String], allowsCustom: Bool)
        /// A flag whose argument may be omitted: `--debug [filter]`, `--worktree [name]`.
        case optionalValue
        /// A single required argument.
        case string
        /// A single required argument edited in a multi-line field.
        case multiline
        /// A single required argument that is a filesystem path (adds a Choose… button).
        case path
        /// Repeatable or variadic: `--add-dir a b`.
        case list
    }

    enum Section: String, CaseIterable {
        case modelEffort = "Model & Effort"
        case permissionsTools = "Permissions & Tools"
        case contextPrompts = "Context & Prompts"
        case mcpPlugins = "MCP & Plugins"
        case integrations = "Integrations"
        case troubleshooting = "Troubleshooting"
    }

    let canonical: String
    let aliases: [String]
    let kind: Kind
    let section: Section
    let label: String
    let help: String

    init(
        _ canonical: String,
        aliases: [String] = [],
        kind: Kind,
        section: Section,
        label: String,
        help: String
    ) {
        self.canonical = canonical
        self.aliases = aliases
        self.kind = kind
        self.section = section
        self.label = label
        self.help = help
    }
}

/// The options Flight Deck models, as a snapshot of `claude --help` taken 2026-08-11.
///
/// Deliberately excluded: `--print`-only options (`--output-format`, `--json-schema`,
/// `--max-budget-usd`, `--fallback-model`, `--include-partial-messages`,
/// `--replay-user-messages`, `--forward-subagent-text`, `--include-hook-events`,
/// `--no-session-persistence`, `--input-format`) and session-identity options that
/// collide with Flight Deck's own management (`--continue`, `--resume`, `--from-pr`,
/// `--teleport`, `--cloud`, `--bg`, `--environment`, `--file`, `--fork-session`).
/// They stay reachable through passthrough — excluded from the catalog is not forbidden.
enum ClaudeFlagCatalog {
    /// Owned by Flight Deck and never user-editable: the session id binds the transcript
    /// watcher, and the name is driven by sidebar rename.
    static let appManaged: Set<String> = ["--session-id", "--name", "-n"]

    static let all: [FlagSpec] = [
        // MARK: Model & Effort
        .init("--model", kind: .choice(["fable", "opus", "sonnet", "haiku"], allowsCustom: true),
              section: .modelEffort, label: "Model",
              help: "Alias for the latest model, or a full model name."),
        .init("--effort", kind: .choice(["low", "medium", "high", "xhigh", "max"], allowsCustom: false),
              section: .modelEffort, label: "Effort",
              help: "Reasoning effort level for the session."),
        .init("--autocompact", kind: .choice(["auto"], allowsCustom: true),
              section: .modelEffort, label: "Auto-compact",
              help: "Auto-compact window size: auto, or 100k–1M tokens."),

        // MARK: Permissions & Tools
        .init("--permission-mode",
              kind: .choice(["acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan"],
                            allowsCustom: false),
              section: .permissionsTools, label: "Permission mode",
              help: "How Claude asks before acting."),
        .init("--dangerously-skip-permissions", kind: .toggle,
              section: .permissionsTools, label: "Skip all permission checks",
              help: "Bypasses every permission check. Recommended only for sandboxes with no internet access."),
        .init("--allow-dangerously-skip-permissions", kind: .toggle,
              section: .permissionsTools, label: "Allow skipping permission checks",
              help: "Makes bypassing available without enabling it by default."),
        .init("--tools", kind: .list,
              section: .permissionsTools, label: "Available tools",
              help: #"Built-in tools to expose. "" disables all; "default" uses all."#),
        .init("--allowedTools", aliases: ["--allowed-tools"], kind: .list,
              section: .permissionsTools, label: "Allowed tools",
              help: #"Tools allowed without asking, e.g. "Bash(git *)" Edit."#),
        .init("--disallowedTools", aliases: ["--disallowed-tools"], kind: .list,
              section: .permissionsTools, label: "Disallowed tools",
              help: "Tools to deny outright."),
        .init("--disable-slash-commands", kind: .toggle,
              section: .permissionsTools, label: "Disable all skills",
              help: "Turns off slash commands and skills."),

        // MARK: Context & Prompts
        .init("--system-prompt", kind: .multiline,
              section: .contextPrompts, label: "System prompt",
              help: "Replaces the default system prompt."),
        .init("--append-system-prompt", kind: .multiline,
              section: .contextPrompts, label: "Append to system prompt",
              help: "Appended to the default system prompt."),
        .init("--add-dir", kind: .list,
              section: .contextPrompts, label: "Additional directories",
              help: "Extra directories tools may access."),
        .init("--agent", kind: .string,
              section: .contextPrompts, label: "Agent",
              help: "Agent for the session; overrides the 'agent' setting."),
        .init("--exclude-dynamic-system-prompt-sections", kind: .toggle,
              section: .contextPrompts, label: "Exclude dynamic prompt sections",
              help: "Moves per-machine sections into the first user message, improving cache reuse."),

        // MARK: MCP & Plugins
        .init("--mcp-config", kind: .list,
              section: .mcpPlugins, label: "MCP config",
              help: "Load MCP servers from JSON files or strings."),
        .init("--strict-mcp-config", kind: .toggle,
              section: .mcpPlugins, label: "Strict MCP config",
              help: "Use only servers from MCP config, ignoring all other MCP configuration."),
        .init("--plugin-dir", kind: .list,
              section: .mcpPlugins, label: "Plugin directories",
              help: "Load plugins from directories or .zip files, for this session only."),
        .init("--plugin-url", kind: .list,
              section: .mcpPlugins, label: "Plugin URLs",
              help: "Fetch plugin .zip files from URLs, for this session only."),
        .init("--settings", kind: .string,
              section: .mcpPlugins, label: "Settings",
              help: "Path to a settings JSON file, or a JSON string."),
        .init("--setting-sources", kind: .string,
              section: .mcpPlugins, label: "Setting sources",
              help: "Comma-separated list: user, project, local."),

        // MARK: Integrations
        .init("--ide", kind: .toggle,
              section: .integrations, label: "Connect to IDE",
              help: "Connect to an IDE on startup when exactly one valid IDE is available."),
        .init("--chrome", kind: .negatable(off: "--no-chrome"),
              section: .integrations, label: "Claude in Chrome",
              help: "Enable or disable the Chrome integration."),
        .init("--remote-control", kind: .optionalValue,
              section: .integrations, label: "Remote Control",
              help: "Start with Remote Control enabled, optionally named."),
        .init("--remote-control-session-name-prefix", kind: .string,
              section: .integrations, label: "Remote Control name prefix",
              help: "Prefix for auto-generated Remote Control session names."),
        .init("--worktree", aliases: ["-w"], kind: .optionalValue,
              section: .integrations, label: "Git worktree",
              help: "Create a new git worktree for the session, optionally named. Changes the session's working directory away from the project root."),
        .init("--tmux", kind: .toggle,
              section: .integrations, label: "tmux session",
              help: "Create a tmux session for the worktree. Requires a worktree."),
        .init("--brief", kind: .toggle,
              section: .integrations, label: "Agent-to-user messages",
              help: "Enable the SendUserMessage tool."),
        .init("--prompt-suggestions", kind: .optionalValue,
              section: .integrations, label: "Prompt suggestions",
              help: "Enable prompt suggestions."),

        // MARK: Troubleshooting
        .init("--bare", kind: .toggle,
              section: .troubleshooting, label: "Bare mode",
              help: "Skip hooks, LSP, plugin sync, auto-memory, and CLAUDE.md auto-discovery."),
        .init("--safe-mode", kind: .toggle,
              section: .troubleshooting, label: "Safe mode",
              help: "Start with all customizations disabled. Useful for troubleshooting a broken configuration."),
        .init("--verbose", kind: .toggle,
              section: .troubleshooting, label: "Verbose",
              help: "Override the verbose-mode setting."),
        .init("--debug", aliases: ["-d"], kind: .optionalValue,
              section: .troubleshooting, label: "Debug",
              help: #"Debug mode, optionally filtered, e.g. "api,hooks"."#),
        .init("--debug-file", kind: .path,
              section: .troubleshooting, label: "Debug log file",
              help: "Write debug logs to this path. Implicitly enables debug mode."),
        .init("--ax-screen-reader", kind: .toggle,
              section: .troubleshooting, label: "Screen-reader output",
              help: "Flat text, no decorative borders or animations."),
        .init("--betas", kind: .list,
              section: .troubleshooting, label: "Beta headers",
              help: "Beta headers to include in API requests (API-key users only)."),
    ]

    /// Resolves a canonical name, an alias, or a negatable flag's off-form.
    static func spec(for name: String) -> FlagSpec? {
        byName[name]
    }

    private static let byName: [String: FlagSpec] = {
        var table: [String: FlagSpec] = [:]
        for spec in all {
            table[spec.canonical] = spec
            for alias in spec.aliases { table[alias] = spec }
            if case .negatable(let off) = spec.kind { table[off] = spec }
        }
        return table
    }()
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: all `ClaudeFlagCatalogTests` pass. If the count assertion fails, count the table — do not change the assertion without checking against the spec's §3.1 table.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Preferences/ClaudeFlagCatalog.swift \
        Tests/FlightDeckTests/ClaudeFlagCatalogTests.swift
git commit -m "feat: claude flag catalog"
```

---

### Task 3: The parser

**Files:**
- Create: `Sources/FlightDeck/Preferences/ClaudeFlagParser.swift`
- Test: `Tests/FlightDeckTests/ClaudeFlagParserTests.swift`

**Interfaces:**
- Consumes: `ClaudeFlagQuoting.tokenize`, `ClaudeFlagCatalog.spec(for:)`, `FlagSet`, `FlagValue`, `Diagnostic`.
- Produces: `ClaudeFlagParser.ParseResult` (`flags: FlagSet`, `diagnostics: [Diagnostic]`), `ClaudeFlagParser.parse(_:) -> ParseResult`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/ClaudeFlagParserTests.swift`:

```swift
import XCTest
@testable import FlightDeck

final class ClaudeFlagParserTests: XCTestCase {
    func testParsesToggle() {
        let result = ClaudeFlagParser.parse("--verbose")
        XCTAssertEqual(result.flags.values["--verbose"], .on)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }

    func testParsesValueFlag() {
        XCTAssertEqual(ClaudeFlagParser.parse("--model opus").flags.values["--model"], .value("opus"))
    }

    func testParsesEqualsForm() {
        XCTAssertEqual(ClaudeFlagParser.parse("--model=opus").flags.values["--model"], .value("opus"))
    }

    func testResolvesAliasToCanonicalKey() {
        let flags = ClaudeFlagParser.parse("--allowed-tools Edit").flags
        XCTAssertEqual(flags.values["--allowedTools"], .list(["Edit"]))
        XCTAssertNil(flags.values["--allowed-tools"])
    }

    func testParsesNegatableOnAndOff() {
        XCTAssertEqual(ClaudeFlagParser.parse("--chrome").flags.values["--chrome"], .value("on"))
        XCTAssertEqual(ClaudeFlagParser.parse("--no-chrome").flags.values["--chrome"], .value("off"))
    }

    func testListFlagConsumesAllFollowingNonFlagTokens() {
        let flags = ClaudeFlagParser.parse("--add-dir a b c --verbose").flags
        XCTAssertEqual(flags.values["--add-dir"], .list(["a", "b", "c"]))
        XCTAssertEqual(flags.values["--verbose"], .on)
    }

    func testRepeatedListFlagAccumulates() {
        let flags = ClaudeFlagParser.parse("--plugin-dir a --plugin-dir b").flags
        XCTAssertEqual(flags.values["--plugin-dir"], .list(["a", "b"]))
    }

    func testOptionalValueTakesNextTokenWhenNotAFlag() {
        XCTAssertEqual(ClaudeFlagParser.parse("--debug api,hooks").flags.values["--debug"],
                       .value("api,hooks"))
    }

    func testOptionalValueIsBareWhenFollowedByAFlag() {
        let flags = ClaudeFlagParser.parse("--debug --verbose").flags
        XCTAssertEqual(flags.values["--debug"], .on)
        XCTAssertEqual(flags.values["--verbose"], .on)
    }

    func testOptionalValueIsBareAtEndOfInput() {
        XCTAssertEqual(ClaudeFlagParser.parse("--debug").flags.values["--debug"], .on)
    }

    func testQuotedValuePreservesSpaces() {
        XCTAssertEqual(ClaudeFlagParser.parse("--system-prompt 'be terse'").flags.values["--system-prompt"],
                       .value("be terse"))
    }

    func testValueFlagMissingItsValueWarnsAndIsDropped() {
        let result = ClaudeFlagParser.parse("--model")
        XCTAssertNil(result.flags.values["--model"])
        XCTAssertEqual(result.diagnostics.first?.severity, .warning)
        XCTAssertTrue(result.diagnostics.contains { $0.message.contains("--model") })
    }

    // MARK: passthrough

    func testUnknownFlagAndItsValuesGoToPassthroughVerbatim() {
        let result = ClaudeFlagParser.parse("--not-real a b --verbose")
        XCTAssertEqual(result.flags.passthrough, ["--not-real", "a", "b"])
        XCTAssertEqual(result.flags.values["--verbose"], .on)
    }

    func testUnknownFlagWarns() {
        let result = ClaudeFlagParser.parse("--modle opus")
        XCTAssertEqual(result.diagnostics.first?.severity, .warning)
        XCTAssertTrue(result.diagnostics.contains { $0.message.contains("--modle") })
    }

    func testBarePositionalGoesToPassthrough() {
        XCTAssertEqual(ClaudeFlagParser.parse("just some words").flags.passthrough,
                       ["just", "some", "words"])
    }

    func testAppManagedFlagIsRejectedToPassthroughWithWarning() {
        let result = ClaudeFlagParser.parse("--session-id abc")
        XCTAssertNil(result.flags.values["--session-id"])
        XCTAssertEqual(result.flags.passthrough, ["--session-id", "abc"])
        XCTAssertTrue(result.diagnostics.contains { $0.message.contains("managed by Flight Deck") })
    }

    // MARK: duplicates

    func testDuplicateFlagWarnsAndLastValueWins() {
        let result = ClaudeFlagParser.parse("--model opus --model sonnet")
        XCTAssertEqual(result.flags.values["--model"], .value("sonnet"))
        XCTAssertTrue(result.diagnostics.contains { $0.message.contains("more than once") })
    }

    func testChromeAndNoChromeAreReportedAsADuplicate() {
        let result = ClaudeFlagParser.parse("--chrome --no-chrome")
        XCTAssertEqual(result.flags.values["--chrome"], .value("off"))
        XCTAssertTrue(result.diagnostics.contains { $0.message.contains("more than once") })
    }

    // MARK: errors

    func testUnterminatedQuoteIsAnErrorAndYieldsNoFlags() {
        let result = ClaudeFlagParser.parse("--name 'oops")
        XCTAssertTrue(result.flags.isEmpty)
        XCTAssertEqual(result.diagnostics.first?.severity, .error)
    }

    func testEmptyInputIsCleanAndEmpty() {
        let result = ClaudeFlagParser.parse("   ")
        XCTAssertTrue(result.flags.isEmpty)
        XCTAssertTrue(result.diagnostics.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `cannot find 'ClaudeFlagParser' in scope`.

- [ ] **Step 3: Write `ClaudeFlagParser.swift`**

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: all `ClaudeFlagParserTests` pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Preferences/ClaudeFlagParser.swift \
        Tests/FlightDeckTests/ClaudeFlagParserTests.swift
git commit -m "feat: claude flag parser with verbatim passthrough"
```

---

### Task 4: The serializer and the round-trip invariant

This is the task that makes the two-way sync trustworthy. The round-trip property is the highest-value test in the plan.

**Files:**
- Create: `Sources/FlightDeck/Preferences/ClaudeFlagSerializer.swift`
- Test: `Tests/FlightDeckTests/ClaudeFlagSerializerTests.swift`

**Interfaces:**
- Consumes: `FlagSet`, `FlagValue`, `ClaudeFlagCatalog`, `ClaudeFlagQuoting.quoteIfNeeded`.
- Produces: `ClaudeFlagSerializer.serialize(_:) -> String`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/ClaudeFlagSerializerTests.swift`:

```swift
import XCTest
@testable import FlightDeck

final class ClaudeFlagSerializerTests: XCTestCase {
    func testSerializesToggle() {
        XCTAssertEqual(ClaudeFlagSerializer.serialize(FlagSet(values: ["--verbose": .on])), "--verbose")
    }

    func testSerializesValue() {
        XCTAssertEqual(ClaudeFlagSerializer.serialize(FlagSet(values: ["--model": .value("opus")])),
                       "--model opus")
    }

    func testSerializesNegatableOnAndOff() {
        XCTAssertEqual(ClaudeFlagSerializer.serialize(FlagSet(values: ["--chrome": .value("on")])),
                       "--chrome")
        XCTAssertEqual(ClaudeFlagSerializer.serialize(FlagSet(values: ["--chrome": .value("off")])),
                       "--no-chrome")
    }

    func testSerializesList() {
        XCTAssertEqual(ClaudeFlagSerializer.serialize(FlagSet(values: ["--add-dir": .list(["a", "b"])])),
                       "--add-dir a b")
    }

    func testOmitsEmptyList() {
        XCTAssertEqual(ClaudeFlagSerializer.serialize(FlagSet(values: ["--add-dir": .list([])])), "")
    }

    func testQuotesValuesThatNeedIt() {
        XCTAssertEqual(
            ClaudeFlagSerializer.serialize(FlagSet(values: ["--system-prompt": .value("be terse")])),
            "--system-prompt 'be terse'"
        )
    }

    func testOrderIsStableAndFollowsCatalogOrder() {
        let flags = FlagSet(values: ["--verbose": .on, "--model": .value("opus")])
        // --model is in Model & Effort, --verbose in Troubleshooting.
        XCTAssertEqual(ClaudeFlagSerializer.serialize(flags), "--model opus --verbose")
    }

    func testPassthroughIsAppendedAsATailVerbatim() {
        let flags = FlagSet(values: ["--verbose": .on], passthrough: ["--not-real", "a b"])
        XCTAssertEqual(ClaudeFlagSerializer.serialize(flags), "--verbose --not-real 'a b'")
    }

    func testEmptySetSerializesToEmptyString() {
        XCTAssertEqual(ClaudeFlagSerializer.serialize(FlagSet()), "")
    }

    // MARK: the invariant

    func testRoundTripAcrossEveryKindInTheCatalog() {
        let flags = FlagSet(
            values: [
                "--verbose": .on,                                   // toggle
                "--chrome": .value("off"),                          // negatable
                "--effort": .value("high"),                         // choice
                "--model": .value("claude-opus-5"),                 // choice, custom
                "--debug": .value("api,hooks"),                     // optionalValue with value
                "--brief": .on,                                     // toggle
                "--agent": .value("reviewer"),                      // string
                "--system-prompt": .value("be terse; use $VARS"),   // multiline, needs quoting
                "--debug-file": .value("/tmp/a b.log"),             // path, needs quoting
                "--add-dir": .list(["../shared", "/tmp/x y"]),      // list, one needs quoting
            ],
            passthrough: ["--not-real", "a b", "--another"]
        )
        let round = ClaudeFlagParser.parse(ClaudeFlagSerializer.serialize(flags))
        XCTAssertEqual(round.flags, flags)
    }

    func testRoundTripOfBareOptionalValue() {
        let flags = FlagSet(values: ["--debug": .on, "--verbose": .on])
        XCTAssertEqual(ClaudeFlagParser.parse(ClaudeFlagSerializer.serialize(flags)).flags, flags)
    }

    func testRoundTripPreservesInjectionAttemptAsLiteralText() {
        let flags = FlagSet(values: ["--system-prompt": .value("'; rm -rf ~; '")])
        XCTAssertEqual(ClaudeFlagParser.parse(ClaudeFlagSerializer.serialize(flags)).flags, flags)
    }

    func testRoundTripIsCleanOfDiagnostics() {
        let flags = FlagSet(values: ["--model": .value("opus"), "--verbose": .on])
        XCTAssertTrue(ClaudeFlagParser.parse(ClaudeFlagSerializer.serialize(flags)).diagnostics.isEmpty)
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `cannot find 'ClaudeFlagSerializer' in scope`.

- [ ] **Step 3: Write `ClaudeFlagSerializer.swift`**

```swift
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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: all `ClaudeFlagSerializerTests` pass, especially the four round-trip tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Preferences/ClaudeFlagSerializer.swift \
        Tests/FlightDeckTests/ClaudeFlagSerializerTests.swift
git commit -m "feat: claude flag serializer with parse/serialize round-trip"
```

---

### Task 5: Merge and cross-flag diagnostics

**Files:**
- Create: `Sources/FlightDeck/Preferences/FlagSetMerge.swift`
- Create: `Sources/FlightDeck/Preferences/FlagDiagnostics.swift`
- Test: `Tests/FlightDeckTests/FlagSetMergeTests.swift`
- Test: `Tests/FlightDeckTests/FlagDiagnosticsTests.swift`

**Interfaces:**
- Consumes: `FlagSet`, `FlagValue`, `Diagnostic`.
- Produces: `FlagSetMerge.merge(global:project:) -> FlagSet`, `FlagDiagnostics.validate(_:) -> [Diagnostic]`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/FlagSetMergeTests.swift`:

```swift
import XCTest
@testable import FlightDeck

final class FlagSetMergeTests: XCTestCase {
    func testProjectValueWinsForTheSameKey() {
        let merged = FlagSetMerge.merge(
            global: FlagSet(values: ["--model": .value("opus")]),
            project: FlagSet(values: ["--model": .value("sonnet")])
        )
        XCTAssertEqual(merged.values["--model"], .value("sonnet"))
    }

    func testKeysAbsentFromProjectAreInherited() {
        let merged = FlagSetMerge.merge(
            global: FlagSet(values: ["--model": .value("opus"), "--effort": .value("high")]),
            project: FlagSet(values: ["--model": .value("sonnet")])
        )
        XCTAssertEqual(merged.values["--effort"], .value("high"))
    }

    func testKeysOnlyInProjectAreAdded() {
        let merged = FlagSetMerge.merge(
            global: FlagSet(),
            project: FlagSet(values: ["--verbose": .on])
        )
        XCTAssertEqual(merged.values["--verbose"], .on)
    }

    func testEmptyProjectInheritsEverything() {
        let global = FlagSet(values: ["--model": .value("opus")], passthrough: ["--x"])
        XCTAssertEqual(FlagSetMerge.merge(global: global, project: FlagSet()), global)
    }

    /// Absent key means inherit; a present-but-empty list is a real override meaning
    /// "off". This distinction is the whole per-flag merge and must not regress.
    func testPresentButEmptyListOverridesRatherThanInherits() {
        let merged = FlagSetMerge.merge(
            global: FlagSet(values: ["--add-dir": .list(["a"])]),
            project: FlagSet(values: ["--add-dir": .list([])])
        )
        XCTAssertEqual(merged.values["--add-dir"], .list([]))
    }

    func testPassthroughTailsConcatenateGlobalFirst() {
        let merged = FlagSetMerge.merge(
            global: FlagSet(passthrough: ["--g"]),
            project: FlagSet(passthrough: ["--p"])
        )
        XCTAssertEqual(merged.passthrough, ["--g", "--p"])
    }
}
```

Create `Tests/FlightDeckTests/FlagDiagnosticsTests.swift`:

```swift
import XCTest
@testable import FlightDeck

final class FlagDiagnosticsTests: XCTestCase {
    func testCleanSetHasNoDiagnostics() {
        XCTAssertTrue(FlagDiagnostics.validate(FlagSet(values: ["--model": .value("opus")])).isEmpty)
    }

    func testTmuxWithoutWorktreeWarns() {
        let diagnostics = FlagDiagnostics.validate(FlagSet(values: ["--tmux": .on]))
        XCTAssertTrue(diagnostics.contains { $0.message.contains("--worktree") })
    }

    /// `--tmux --worktree` satisfies the pairing rule, so that warning goes quiet — but the
    /// working-directory consequence still applies, and applies most in exactly this case.
    func testTmuxWithWorktreeStillWarnsAboutTheWorkingDirectory() {
        let flags = FlagSet(values: ["--tmux": .on, "--worktree": .on])
        let diagnostics = FlagDiagnostics.validate(flags)
        XCTAssertEqual(diagnostics.count, 1)
        XCTAssertTrue(diagnostics[0].message.contains("working directory"))
        XCTAssertFalse(diagnostics.contains { $0.message.contains("requires --worktree") })
    }

    func testSkipPermissionsWarns() {
        let diagnostics = FlagDiagnostics.validate(
            FlagSet(values: ["--dangerously-skip-permissions": .on])
        )
        XCTAssertEqual(diagnostics.first?.severity, .warning)
        XCTAssertTrue(diagnostics.contains { $0.message.contains("permission") })
    }

    func testWorktreeWarnsThatTheWorkingDirectoryMoves() {
        let diagnostics = FlagDiagnostics.validate(FlagSet(values: ["--worktree": .on]))
        XCTAssertTrue(diagnostics.contains { $0.message.contains("working directory") })
    }

    func testDiagnosticsAreOrderStable() {
        let flags = FlagSet(values: ["--tmux": .on, "--dangerously-skip-permissions": .on])
        XCTAssertEqual(FlagDiagnostics.validate(flags), FlagDiagnostics.validate(flags))
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `cannot find 'FlagSetMerge' in scope`.

- [ ] **Step 3: Write `FlagSetMerge.swift`**

```swift
import Foundation

/// Combines a project's override with the global defaults, per flag.
///
/// Key *presence* is the override signal: an absent key inherits, while a present key —
/// even one holding an empty list — overrides. That is why `FlagSet.values` never uses a
/// sentinel "unset" value.
enum FlagSetMerge {
    static func merge(global: FlagSet, project: FlagSet) -> FlagSet {
        var merged = global
        for (key, value) in project.values {
            merged.values[key] = value
        }
        // Passthrough is unkeyed, so it cannot merge per-flag. Both tails are kept,
        // global first, and `claude`'s own last-wins parsing resolves any overlap.
        merged.passthrough = global.passthrough + project.passthrough
        return merged
    }
}
```

- [ ] **Step 4: Write `FlagDiagnostics.swift`**

```swift
import Foundation

/// Cross-flag checks that the parser cannot make, because they depend on the resolved
/// set rather than on the token stream. Everything here is a warning: the catalog is a
/// snapshot, and blocking on it would be worse than being wrong about it.
///
/// Single-flag concerns (unknown flags, duplicates, missing values) live in
/// `ClaudeFlagParser` and are not repeated here.
enum FlagDiagnostics {
    static func validate(_ flags: FlagSet) -> [Diagnostic] {
        var diagnostics: [Diagnostic] = []

        if flags.values["--dangerously-skip-permissions"] != nil {
            diagnostics.append(.warning(
                "Every new session will bypass all permission checks. Recommended only for sandboxes with no internet access."
            ))
        }

        if flags.values["--tmux"] != nil, flags.values["--worktree"] == nil {
            diagnostics.append(.warning("--tmux requires --worktree; claude will reject it on its own."))
        }

        if flags.values["--worktree"] != nil {
            diagnostics.append(.warning(
                "--worktree moves the session's working directory out of the project root, so its transcript and sidebar grouping follow the worktree."
            ))
        }

        return diagnostics
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: all `FlagSetMergeTests` and `FlagDiagnosticsTests` pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Preferences/FlagSetMerge.swift \
        Sources/FlightDeck/Preferences/FlagDiagnostics.swift \
        Tests/FlightDeckTests/FlagSetMergeTests.swift \
        Tests/FlightDeckTests/FlagDiagnosticsTests.swift
git commit -m "feat: per-flag merge and cross-flag diagnostics"
```

---

### Task 6: Preferences model and store

**Files:**
- Create: `Sources/FlightDeck/Preferences/Preferences.swift`
- Create: `Sources/FlightDeck/Preferences/PreferencesStore.swift`
- Test: `Tests/FlightDeckTests/PreferencesStoreTests.swift`

**Interfaces:**
- Consumes: `FlagSet`, `FlagSetMerge.merge(global:project:)`.
- Produces: `ShellPreferences` (`shellOverride: String?`, `environment: [String: String]`, `clearChildSessionMarker: Bool`), `Preferences` (`globalFlags`, `projectFlags`, `shell`), `PreferencesPersisting`, `UserDefaultsPreferencesPersistence`, `PreferencesStore` with `preferences`, `resolvedFlags(forProject:)`, `projectOverride(_:)`, `setProjectOverride(_:_:)`, `removeProjectOverride(_:)`, `overriddenProjectPaths`, `resolvedShell(environment:)`, `sessionEnvironment(inherited:)`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/PreferencesStoreTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class PreferencesStoreTests: XCTestCase {
    /// In-memory stand-in so tests never touch the real defaults domain.
    final class MemoryPersistence: PreferencesPersisting {
        var stored: Preferences?
        var saveCount = 0
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences; saveCount += 1 }
    }

    func testStartsFromDefaultsWhenNothingIsStored() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        XCTAssertTrue(store.preferences.globalFlags.isEmpty)
        XCTAssertNil(store.preferences.shell.shellOverride)
        XCTAssertTrue(store.preferences.shell.clearChildSessionMarker)
    }

    func testLoadsStoredPreferences() {
        let persistence = MemoryPersistence()
        persistence.stored = Preferences(globalFlags: FlagSet(values: ["--model": .value("opus")]))
        let store = PreferencesStore(persistence: persistence)
        XCTAssertEqual(store.preferences.globalFlags.values["--model"], .value("opus"))
    }

    func testMutationPersists() {
        let persistence = MemoryPersistence()
        let store = PreferencesStore(persistence: persistence)
        store.preferences.globalFlags.values["--verbose"] = .on
        XCTAssertEqual(persistence.stored?.globalFlags.values["--verbose"], .on)
    }

    func testResolvedFlagsMergeProjectOverProject() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        store.preferences.globalFlags = FlagSet(values: ["--model": .value("opus"), "--effort": .value("high")])
        store.setProjectOverride("/tmp/repo", FlagSet(values: ["--model": .value("sonnet")]))
        let resolved = store.resolvedFlags(forProject: "/tmp/repo")
        XCTAssertEqual(resolved.values["--model"], .value("sonnet"))
        XCTAssertEqual(resolved.values["--effort"], .value("high"))
    }

    func testProjectWithoutOverrideResolvesToGlobals() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        store.preferences.globalFlags = FlagSet(values: ["--model": .value("opus")])
        XCTAssertEqual(store.resolvedFlags(forProject: "/tmp/other"), store.preferences.globalFlags)
    }

    func testPathsAreStandardizedSoEquivalentPathsShareAnOverride() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        store.setProjectOverride("/tmp/repo/", FlagSet(values: ["--verbose": .on]))
        XCTAssertEqual(store.resolvedFlags(forProject: "/tmp/repo").values["--verbose"], .on)
    }

    func testRemoveProjectOverrideFallsBackToGlobals() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        store.preferences.globalFlags = FlagSet(values: ["--model": .value("opus")])
        store.setProjectOverride("/tmp/repo", FlagSet(values: ["--model": .value("sonnet")]))
        store.removeProjectOverride("/tmp/repo")
        XCTAssertEqual(store.resolvedFlags(forProject: "/tmp/repo").values["--model"], .value("opus"))
        XCTAssertTrue(store.overriddenProjectPaths.isEmpty)
    }

    /// A `Repo` disappears from `SessionStore` when its last session closes, so the
    /// override must not be enumerable only from open projects.
    func testOverridePathsSurviveIndependentlyOfOpenProjects() {
        let persistence = MemoryPersistence()
        let store = PreferencesStore(persistence: persistence)
        store.setProjectOverride("/tmp/repo", FlagSet(values: ["--verbose": .on]))
        let reloaded = PreferencesStore(persistence: persistence)
        XCTAssertEqual(reloaded.overriddenProjectPaths, ["/tmp/repo"])
    }

    func testOverriddenPathsAreSorted() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        store.setProjectOverride("/tmp/b", FlagSet(values: ["--verbose": .on]))
        store.setProjectOverride("/tmp/a", FlagSet(values: ["--verbose": .on]))
        XCTAssertEqual(store.overriddenProjectPaths, ["/tmp/a", "/tmp/b"])
    }

    func testCodableRoundTrip() throws {
        var preferences = Preferences()
        preferences.globalFlags = FlagSet(values: ["--add-dir": .list(["a"])], passthrough: ["--x"])
        preferences.projectFlags = ["/tmp/repo": FlagSet(values: ["--verbose": .on])]
        preferences.shell = ShellPreferences(
            shellOverride: "/bin/fish", environment: ["A": "B"], clearChildSessionMarker: false
        )
        let data = try JSONEncoder().encode(preferences)
        XCTAssertEqual(try JSONDecoder().decode(Preferences.self, from: data), preferences)
    }

    // MARK: shell

    func testResolvedShellPrefersTheOverride() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        store.preferences.shell.shellOverride = "/bin/fish"
        XCTAssertEqual(store.resolvedShell(environment: ["SHELL": "/bin/bash"]), "/bin/fish")
    }

    func testResolvedShellFallsBackToShellResolver() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        XCTAssertEqual(store.resolvedShell(environment: ["SHELL": "/bin/bash"]), "/bin/bash")
    }

    func testSessionEnvironmentIncludesCustomVariables() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        store.preferences.shell.environment = ["FOO": "bar"]
        XCTAssertEqual(store.sessionEnvironment(inherited: [:])["FOO"], "bar")
    }

    /// The FOLLOWUPS.md footgun: an inherited marker turns transcript saving off, which
    /// silently kills inbound rename sync.
    func testClearsChildSessionMarkerWhenInheritedAndEnabled() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        let environment = store.sessionEnvironment(inherited: ["CLAUDE_CODE_CHILD_SESSION": "1"])
        XCTAssertEqual(environment["CLAUDE_CODE_CHILD_SESSION"], "")
    }

    func testDoesNotClearChildSessionMarkerWhenDisabled() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        store.preferences.shell.clearChildSessionMarker = false
        let environment = store.sessionEnvironment(inherited: ["CLAUDE_CODE_CHILD_SESSION": "1"])
        XCTAssertNil(environment["CLAUDE_CODE_CHILD_SESSION"])
    }

    func testDoesNotAddTheMarkerWhenItWasNotInherited() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        XCTAssertNil(store.sessionEnvironment(inherited: [:])["CLAUDE_CODE_CHILD_SESSION"])
    }
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `cannot find 'PreferencesStore' in scope`.

- [ ] **Step 3: Write `Preferences.swift`**

```swift
import Foundation

/// The shell and environment new sessions are spawned into.
struct ShellPreferences: Codable, Equatable {
    /// nil means "use `$SHELL`", which is `ShellResolver`'s existing behaviour.
    var shellOverride: String?
    /// Extra variables merged into every new session's environment.
    var environment: [String: String]
    /// Blanks an inherited `CLAUDE_CODE_CHILD_SESSION`. Claude Code sets that marker for
    /// nested sessions, and it turns transcript saving off — which silently kills the
    /// sidebar's inbound rename sync, since the watcher tails a file that is never
    /// written. See docs/FOLLOWUPS.md. Defaults on.
    var clearChildSessionMarker: Bool

    init(
        shellOverride: String? = nil,
        environment: [String: String] = [:],
        clearChildSessionMarker: Bool = true
    ) {
        self.shellOverride = shellOverride
        self.environment = environment
        self.clearChildSessionMarker = clearChildSessionMarker
    }
}

/// Everything the Preferences window edits.
struct Preferences: Codable, Equatable {
    var globalFlags: FlagSet
    /// Keyed by standardized project path. Kept here rather than on `Repo` because a
    /// `Repo` is removed from `SessionStore` when its last session closes, and an
    /// override must outlive that.
    var projectFlags: [String: FlagSet]
    var shell: ShellPreferences

    init(
        globalFlags: FlagSet = FlagSet(),
        projectFlags: [String: FlagSet] = [:],
        shell: ShellPreferences = ShellPreferences()
    ) {
        self.globalFlags = globalFlags
        self.projectFlags = projectFlags
        self.shell = shell
    }
}
```

- [ ] **Step 4: Write `PreferencesStore.swift`**

```swift
import Foundation
import SwiftUI

@MainActor
protocol PreferencesPersisting: AnyObject {
    func load() -> Preferences?
    func save(_ preferences: Preferences)
}

/// Mirrors `UserDefaultsSessionPersistence` so there is one storage idiom in the codebase.
/// The same defaults domain (`dev.flightdeck.FlightDeck`) that `scripts/smoke.sh` wipes,
/// so the UITest gate stays hermetic.
@MainActor
final class UserDefaultsPreferencesPersistence: PreferencesPersisting {
    private let defaults: UserDefaults
    private let key = "preferences.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> Preferences? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Preferences.self, from: data)
    }

    func save(_ preferences: Preferences) {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: key)
    }
}

/// Single source of truth for preferences. Owned by `FlightDeckApp` and read by both the
/// Preferences window and `SessionStore` at session-creation time.
@MainActor
final class PreferencesStore: ObservableObject {
    @Published var preferences: Preferences {
        didSet { persistence?.save(preferences) }
    }

    private let persistence: PreferencesPersisting?

    init(persistence: PreferencesPersisting?) {
        self.persistence = persistence
        self.preferences = persistence?.load() ?? Preferences()
    }

    convenience init() {
        self.init(persistence: UserDefaultsPreferencesPersistence())
    }

    // MARK: Flags

    /// The flags a new session in `path` launches with: globals with the project's
    /// override applied per flag.
    func resolvedFlags(forProject path: String) -> FlagSet {
        FlagSetMerge.merge(
            global: preferences.globalFlags,
            project: preferences.projectFlags[Self.key(path)] ?? FlagSet()
        )
    }

    func projectOverride(_ path: String) -> FlagSet {
        preferences.projectFlags[Self.key(path)] ?? FlagSet()
    }

    func setProjectOverride(_ path: String, _ flags: FlagSet) {
        preferences.projectFlags[Self.key(path)] = flags
    }

    func removeProjectOverride(_ path: String) {
        preferences.projectFlags.removeValue(forKey: Self.key(path))
    }

    /// Sorted so the Projects tab's list order is stable across launches.
    var overriddenProjectPaths: [String] {
        preferences.projectFlags.keys.sorted()
    }

    /// Matches `SessionStore.indexOfRepo`, which compares `standardizedFileURL.path`.
    private static func key(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    // MARK: Shell

    func resolvedShell(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        ShellResolver.resolve(environment: environment, override: preferences.shell.shellOverride)
    }

    /// The environment overrides handed to `Ghostty.SurfaceConfiguration`. Only the deltas
    /// are returned; libghostty merges them over the inherited environment.
    ///
    /// The marker is blanked rather than removed because the surface config can only *set*
    /// variables, not unset them — and `claude` treats an empty value as absent.
    func sessionEnvironment(
        inherited: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var environment = preferences.shell.environment
        if preferences.shell.clearChildSessionMarker,
           inherited["CLAUDE_CODE_CHILD_SESSION"] != nil {
            environment["CLAUDE_CODE_CHILD_SESSION"] = ""
        }
        return environment
    }
}
```

- [ ] **Step 5: Extend `ShellResolver` with the override**

Modify `Sources/FlightDeck/ShellResolver.swift` in full:

```swift
import Foundation

enum ShellResolver {
    /// `override` comes from Preferences and wins over `$SHELL`. An empty or
    /// whitespace-only override is treated as unset, so a cleared text field in the
    /// Shell tab reverts to `$SHELL` rather than launching nothing.
    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        override: String? = nil
    ) -> String {
        if let override, !override.trimmingCharacters(in: .whitespaces).isEmpty {
            return override
        }
        if let shell = environment["SHELL"], !shell.isEmpty {
            return shell
        }
        return "/bin/zsh"
    }
}
```

- [ ] **Step 6: Add the override tests to `ShellResolverTests`**

Append to `Tests/FlightDeckTests/ShellResolverTests.swift`, inside the existing class:

```swift
    func testOverrideWinsOverShellEnv() {
        let shell = ShellResolver.resolve(environment: ["SHELL": "/bin/bash"], override: "/bin/fish")
        XCTAssertEqual(shell, "/bin/fish")
    }

    func testEmptyOverrideFallsBackToShellEnv() {
        let shell = ShellResolver.resolve(environment: ["SHELL": "/bin/bash"], override: "  ")
        XCTAssertEqual(shell, "/bin/bash")
    }

    func testNilOverrideFallsBackToShellEnv() {
        let shell = ShellResolver.resolve(environment: ["SHELL": "/bin/bash"], override: nil)
        XCTAssertEqual(shell, "/bin/bash")
    }
```

- [ ] **Step 7: Run tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: `PreferencesStoreTests` and the extended `ShellResolverTests` pass; the three original `ShellResolverTests` still pass (the new parameter is defaulted).

- [ ] **Step 8: Commit**

```bash
git add Sources/FlightDeck/Preferences/Preferences.swift \
        Sources/FlightDeck/Preferences/PreferencesStore.swift \
        Sources/FlightDeck/ShellResolver.swift \
        Tests/FlightDeckTests/PreferencesStoreTests.swift \
        Tests/FlightDeckTests/ShellResolverTests.swift
git commit -m "feat: preferences model, store, and shell override"
```

---

### Task 7: Flag-aware launch commands

**Files:**
- Modify: `Sources/FlightDeck/ClaudeSession.swift:88-103`
- Test: `Tests/FlightDeckTests/ClaudeSessionTests.swift`

**Interfaces:**
- Consumes: `FlagSet`, `ClaudeFlagSerializer.serialize`.
- Produces: `ClaudeSession.launchCommand(sessionID:title:flags:)`, `ClaudeSession.resumeCommand(sessionID:title:flags:)`, `ClaudeSession.lockedPrefix(sessionID:title:)`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/FlightDeckTests/ClaudeSessionTests.swift`, inside the existing class:

```swift
    private var fixedID: UUID { UUID(uuidString: "4F3A0000-0000-0000-0000-000000000001")! }

    func testLaunchCommandWithNoFlagsIsUnchanged() {
        let command = ClaudeSession.launchCommand(sessionID: fixedID, title: "one")
        XCTAssertEqual(
            command,
            "claude --session-id 4f3a0000-0000-0000-0000-000000000001 --name 'one'\n"
        )
    }

    func testLaunchCommandAppendsFlagsAfterAppManagedOnes() {
        let command = ClaudeSession.launchCommand(
            sessionID: fixedID, title: "one",
            flags: FlagSet(values: ["--model": .value("opus")])
        )
        XCTAssertEqual(
            command,
            "claude --session-id 4f3a0000-0000-0000-0000-000000000001 --name 'one' --model opus\n"
        )
    }

    func testResumeCommandAppliesFlagsToBothBranches() {
        let command = ClaudeSession.resumeCommand(
            sessionID: fixedID, title: "one",
            flags: FlagSet(values: ["--model": .value("opus")])
        )
        // The fallback branch must be configured too, or a pruned transcript silently
        // launches an unconfigured session.
        XCTAssertEqual(command.components(separatedBy: "--model opus").count - 1, 2)
    }

    func testResumeCommandWithNoFlagsIsUnchanged() {
        let command = ClaudeSession.resumeCommand(sessionID: fixedID, title: "one")
        let id = "4f3a0000-0000-0000-0000-000000000001"
        XCTAssertEqual(command, "claude --resume \(id) || claude --session-id \(id) --name 'one'\n")
    }

    func testFlagValuesAreQuotedNotStripped() throws {
        let hostile = "'; rm -rf ~; '"
        let command = ClaudeSession.launchCommand(
            sessionID: fixedID, title: "one",
            flags: FlagSet(values: ["--system-prompt": .value(hostile)])
        )
        // The real assertion: the value survives as ONE literal argument rather than
        // decomposing into shell syntax. Tokenizing the command is how we prove that.
        // `tokenize` returns `[ClaudeFlagQuoting.Token]` (Task 4 added `wasQuoted`), so
        // compare against `.text`.
        let texts = try ClaudeFlagQuoting.tokenize(
            command.trimmingCharacters(in: .newlines)
        ).map(\.text)
        guard let index = texts.firstIndex(of: "--system-prompt"), index + 1 < texts.count else {
            return XCTFail("--system-prompt missing from: \(command)")
        }
        XCTAssertEqual(texts[index + 1], hostile)
        XCTAssertFalse(texts.contains("rm"), "the value must not split into separate tokens")
        XCTAssertFalse(texts.contains(";"), "the value must not split into separate tokens")
    }

    func testLockedPrefixMatchesTheStartOfTheLaunchCommand() {
        let prefix = ClaudeSession.lockedPrefix(sessionID: fixedID, title: "one")
        let command = ClaudeSession.launchCommand(
            sessionID: fixedID, title: "one",
            flags: FlagSet(values: ["--model": .value("opus")])
        )
        XCTAssertTrue(command.hasPrefix(prefix))
    }

    func testLockedPrefixIsTheWholeCommandWhenThereAreNoFlags() {
        let prefix = ClaudeSession.lockedPrefix(sessionID: fixedID, title: "one")
        XCTAssertEqual(
            ClaudeSession.launchCommand(sessionID: fixedID, title: "one"),
            prefix + "\n"
        )
    }
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile failure — extra argument `flags` / `cannot find 'lockedPrefix'`.

- [ ] **Step 3: Replace the command builders in `ClaudeSession.swift`**

Replace lines 88–103 (the `launchCommand` and `resumeCommand` definitions) with:

```swift
    /// The app-managed portion of the command, always a contiguous prefix. The command
    /// field renders exactly this as its immutable region, which is what makes the
    /// locked-token UI a locked *prefix* rather than arbitrary inline tokens.
    static func lockedPrefix(sessionID: UUID, title: String) -> String {
        let name = sanitizedName(title) ?? "session"
        return "claude --session-id \(sessionID.uuidString.lowercased()) --name \(shellQuoted(name))"
    }

    /// The command the shell runs at session start, binding `claude` to our UUID and title.
    /// User flags follow the app-managed ones so the prefix stays contiguous.
    static func launchCommand(
        sessionID: UUID, title: String, flags: FlagSet = FlagSet()
    ) -> String {
        let tail = ClaudeFlagSerializer.serialize(flags)
        return lockedPrefix(sessionID: sessionID, title: title)
            + (tail.isEmpty ? "" : " \(tail)") + "\n"
    }

    /// The command for a session restored from a previous app launch. Reattaches to the
    /// existing conversation, falling back to a fresh session with the same id and name
    /// when the transcript has been deleted or pruned (`--resume` exits 1 in that case).
    ///
    /// Flags are applied to **both** branches: the fallback is a real session launch, and
    /// leaving it unconfigured would silently drop every preference the moment a
    /// transcript is pruned.
    static func resumeCommand(
        sessionID: UUID, title: String, flags: FlagSet = FlagSet()
    ) -> String {
        let id = sessionID.uuidString.lowercased()
        let name = sanitizedName(title) ?? "session"
        let tail = ClaudeFlagSerializer.serialize(flags)
        let suffix = tail.isEmpty ? "" : " \(tail)"
        return "claude --resume \(id)\(suffix) "
            + "|| claude --session-id \(id) --name \(shellQuoted(name))\(suffix)\n"
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: all `ClaudeSessionTests` pass, including the pre-existing ones (the `flags` parameter is defaulted, so no existing call site changes).

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/ClaudeSession.swift Tests/FlightDeckTests/ClaudeSessionTests.swift
git commit -m "feat: apply preference flags to launch and both resume branches"
```

---

### Task 8: Wire preferences into session creation

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift:36-50` (init), `:60-103` (`newSession`/`insertSession`), `:117-147` (`restore`)
- Test: `Tests/FlightDeckTests/SessionLaunchTests.swift`

**Interfaces:**
- Consumes: `PreferencesStore.resolvedFlags(forProject:)`, `.resolvedShell()`, `.sessionEnvironment()`.
- Produces: `SessionStore.init(provider:persistence:preferences:)` and `SessionStore.init(ghostty:resetState:preferences:)`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/FlightDeckTests/SessionLaunchTests.swift`, inside the existing class. If that file has no surface-capturing fake, add one — check what the file already provides and reuse it rather than duplicating:

```swift
    @MainActor
    func testNewSessionLaunchesWithResolvedFlags() {
        let preferences = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())
        preferences.preferences.globalFlags = FlagSet(values: ["--model": .value("opus")])
        let provider = RecordingSurfaceProvider()
        let store = SessionStore(provider: provider, persistence: nil, preferences: preferences)

        store.newSession(in: URL(fileURLWithPath: "/tmp", isDirectory: true))

        XCTAssertTrue(provider.lastConfig?.initialInput?.contains("--model opus") == true)
    }

    @MainActor
    func testProjectOverrideBeatsGlobalAtLaunch() {
        let preferences = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())
        preferences.preferences.globalFlags = FlagSet(values: ["--model": .value("opus")])
        preferences.setProjectOverride("/tmp", FlagSet(values: ["--model": .value("sonnet")]))
        let provider = RecordingSurfaceProvider()
        let store = SessionStore(provider: provider, persistence: nil, preferences: preferences)

        store.newSession(in: URL(fileURLWithPath: "/tmp", isDirectory: true))

        let input = provider.lastConfig?.initialInput ?? ""
        XCTAssertTrue(input.contains("--model sonnet"))
        XCTAssertFalse(input.contains("--model opus"))
    }

    @MainActor
    func testShellOverrideReachesTheSurfaceConfig() {
        let preferences = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())
        preferences.preferences.shell.shellOverride = "/bin/fish"
        let provider = RecordingSurfaceProvider()
        let store = SessionStore(provider: provider, persistence: nil, preferences: preferences)

        store.newSession(in: URL(fileURLWithPath: "/tmp", isDirectory: true))

        XCTAssertEqual(provider.lastConfig?.command, "/bin/fish")
    }

    @MainActor
    func testCustomEnvironmentReachesTheSurfaceConfig() {
        let preferences = PreferencesStore(persistence: PreferencesStoreTests.MemoryPersistence())
        preferences.preferences.shell.environment = ["FOO": "bar"]
        let provider = RecordingSurfaceProvider()
        let store = SessionStore(provider: provider, persistence: nil, preferences: preferences)

        store.newSession(in: URL(fileURLWithPath: "/tmp", isDirectory: true))

        XCTAssertEqual(provider.lastConfig?.environmentVariables["FOO"], "bar")
    }

    @MainActor
    func testStoreWithoutPreferencesStillLaunches() {
        let provider = RecordingSurfaceProvider()
        let store = SessionStore(provider: provider, persistence: nil)
        store.newSession(in: URL(fileURLWithPath: "/tmp", isDirectory: true))
        XCTAssertTrue(provider.lastConfig?.initialInput?.hasPrefix("claude --session-id") == true)
    }
```

Add this fake near the top of the file if the file does not already define an equivalent:

```swift
    @MainActor
    final class RecordingSurfaceProvider: SurfaceProvider {
        var lastConfig: Ghostty.SurfaceConfiguration?
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
            lastConfig = config
            return nil
        }
        func tick() {}
    }
```

Also make `PreferencesStoreTests.MemoryPersistence` reachable from this file by leaving it `internal` (it already is — `final class` inside an `internal` test class).

- [ ] **Step 2: Run tests to verify they fail**

Run: `./scripts/test-unit.sh`
Expected: compile failure — extra argument `preferences` in `SessionStore.init`.

- [ ] **Step 3: Add the dependency to `SessionStore`**

In `Sources/FlightDeck/SessionStore.swift`, add a stored property beside `persistence` (around line 36):

```swift
    /// Read at session-creation time only. Preferences configure *new* sessions; a
    /// running `claude` is never reconfigured, because its command line is already spent.
    private let preferences: PreferencesStore?
```

Replace both initialisers (lines 38–50):

```swift
    init(
        provider: SurfaceProvider?,
        persistence: SessionPersisting? = nil,
        preferences: PreferencesStore? = nil
    ) {
        self.provider = provider
        self.persistence = persistence
        self.preferences = preferences
    }

    /// `resetState` comes from the `-FlightDeckResetState YES` launch argument: `smoke.sh`
    /// wipes defaults once per run, but the UITest bundle launches the app once per test
    /// case, so a session persisted by an earlier case would otherwise survive into a later
    /// one and make tests order-dependent.
    convenience init(
        ghostty: GhosttyApp?, resetState: Bool = false, preferences: PreferencesStore? = nil
    ) {
        self.init(
            provider: ghostty,
            persistence: UserDefaultsSessionPersistence(),
            preferences: preferences
        )
        if resetState || !restore() { seedInitialSession() }
    }
```

- [ ] **Step 4: Resolve flags at creation and apply shell/env**

In `newSession(in:)` (line 60), replace the `initialInput:` argument:

```swift
            initialInput: ClaudeSession.launchCommand(
                sessionID: session.id,
                title: session.title,
                flags: preferences?.resolvedFlags(forProject: url.path) ?? FlagSet()
            )
```

In `restore(directoryExists:)` (line 132), replace the `initialInput:` argument:

```swift
                initialInput: ClaudeSession.resumeCommand(
                    sessionID: entry.id,
                    title: entry.title,
                    flags: preferences?.resolvedFlags(forProject: entry.workingDirectory) ?? FlagSet()
                )
```

In `insertSession(_:in:initialInput:)` (lines 92–95), replace the config construction:

```swift
        var config = Ghostty.SurfaceConfiguration()
        config.command = preferences?.resolvedShell() ?? ShellResolver.resolve()
        config.workingDirectory = url.path
        config.initialInput = initialInput
        config.environmentVariables = preferences?.sessionEnvironment() ?? [:]
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: the new `SessionLaunchTests` pass; every existing suite still passes (`preferences` is defaulted to nil everywhere).

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/SessionLaunchTests.swift
git commit -m "feat: resolve preferences at session creation"
```

---

### Task 9: The locked-prefix command field

The riskiest component, built standalone. If `NSTextView` fights back, the documented fallback is a read-only `Text` above a plain `TextField` — that loses the single-field feel and nothing else.

**Files:**
- Create: `Sources/FlightDeck/Preferences/UI/LockedPrefixCommandField.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `LockedPrefixCommandField(lockedPrefix:tail:onCommit:)` — a `View` with `@Binding var tail: String` and `onCommit: (String) -> Void`.

- [ ] **Step 1: Write the view**

```swift
import AppKit
import SwiftUI

/// The command field: an `NSTextView` whose leading `lockedPrefix` cannot be edited,
/// selected into, or deleted.
///
/// The app-managed flags are always a contiguous prefix of the command
/// (`ClaudeSession.lockedPrefix`), which is what reduces "locked tokens" to "locked
/// prefix" — no attachment cells, no inline token model, just a rejected edit range.
///
/// Sync is asymmetric by design: `tail` is pushed in immediately whenever a control
/// changes, but `onCommit` only fires on blur or ⌘↩, so the field is never re-canonicalized
/// under a live cursor.
struct LockedPrefixCommandField: NSViewRepresentable {
    let lockedPrefix: String
    @Binding var tail: String
    var onCommit: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.allowsUndo = true

        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        context.coordinator.textView = textView
        context.coordinator.render(prefix: lockedPrefix, tail: tail)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        // Only re-render when the model actually differs from what is on screen, or every
        // keystroke would reset the caret to the end.
        if context.coordinator.currentTail != tail || context.coordinator.currentPrefix != lockedPrefix {
            context.coordinator.render(prefix: lockedPrefix, tail: tail)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: LockedPrefixCommandField
        weak var textView: NSTextView?
        private(set) var currentPrefix = ""
        private(set) var currentTail = ""

        init(_ parent: LockedPrefixCommandField) {
            self.parent = parent
        }

        /// The locked region is `prefix` plus the single space separating it from the tail,
        /// so the user cannot delete that separator and glue their first flag onto `--name`.
        private var lockedLength: Int { (currentPrefix as NSString).length + 1 }

        func render(prefix: String, tail: String) {
            guard let textView else { return }
            currentPrefix = prefix
            currentTail = tail

            let full = prefix + " " + tail
            let attributed = NSMutableAttributedString(string: full)
            let font = NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            attributed.addAttributes(
                [.font: font, .foregroundColor: NSColor.labelColor],
                range: NSRange(location: 0, length: (full as NSString).length)
            )
            attributed.addAttributes(
                [.foregroundColor: NSColor.secondaryLabelColor],
                range: NSRange(location: 0, length: min(lockedLength, (full as NSString).length))
            )
            textView.textStorage?.setAttributedString(attributed)
            clampSelection()
        }

        // MARK: NSTextViewDelegate

        func textView(
            _ textView: NSTextView,
            shouldChangeTextIn affectedCharRange: NSRange,
            replacementString: String?
        ) -> Bool {
            affectedCharRange.location >= lockedLength
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            clampSelection()
        }

        func textDidChange(_ notification: Notification) {
            guard let textView else { return }
            let full = textView.string as NSString
            guard full.length >= lockedLength else { return }
            currentTail = full.substring(from: lockedLength)
            parent.tail = currentTail
        }

        func textDidEndEditing(_ notification: Notification) {
            parent.onCommit(currentTail)
        }

        /// ⌘↩ commits without leaving the field.
        func textView(
            _ textView: NSTextView,
            doCommandBy selector: Selector
        ) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)),
               NSEvent.modifierFlags.contains(.command) {
                parent.onCommit(currentTail)
                return true
            }
            return false
        }

        private func clampSelection() {
            guard let textView else { return }
            let length = (textView.string as NSString).length
            let floor = min(lockedLength, length)
            let selected = textView.selectedRange()
            if selected.location < floor {
                let overshoot = max(0, selected.location + selected.length - floor)
                textView.setSelectedRange(NSRange(location: floor, length: overshoot))
            }
        }
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `./scripts/test-unit.sh`
Expected: build succeeds, all existing tests still pass. There are no unit tests for this file — it is `NSViewRepresentable` glue whose behaviour is keyboard-driven; Task 15's UITest covers it end to end.

- [ ] **Step 3: Commit**

```bash
git add Sources/FlightDeck/Preferences/UI/LockedPrefixCommandField.swift
git commit -m "feat: locked-prefix command text field"
```

---

### Task 10: The generic flag row

**Files:**
- Create: `Sources/FlightDeck/Preferences/UI/FlagRow.swift`

**Interfaces:**
- Consumes: `FlagSpec`, `FlagValue`.
- Produces: `FlagRow(spec:value:inherited:onRevert:)`, where `value` is `Binding<FlagValue?>`, `inherited` is `FlagValue?` (nil in the global tab), and `onRevert` is `(() -> Void)?`.

- [ ] **Step 1: Write the view**

```swift
import SwiftUI

/// One control, rendered from its `FlagSpec.Kind`. Six shapes cover all thirty-six
/// options, which is why the catalog is declarative — adding a flag is a table entry,
/// not a new view.
///
/// `value == nil` means the flag is unset. In the Projects tab that means "inherit", and
/// `inherited` supplies the de-emphasised value shown in its place.
struct FlagRow: View {
    let spec: FlagSpec
    @Binding var value: FlagValue?
    var inherited: FlagValue?
    var onRevert: (() -> Void)?

    private var isOverridden: Bool { value != nil }

    var body: some View {
        LabeledContent {
            HStack(spacing: 6) {
                control
                if let onRevert, isOverridden, inherited != nil {
                    Button {
                        onRevert()
                    } label: {
                        Image(systemName: "arrow.uturn.backward")
                    }
                    .buttonStyle(.borderless)
                    .help("Revert to the global default")
                }
            }
        } label: {
            Text(spec.label)
                .fontWeight(isOverridden && inherited != nil ? .semibold : .regular)
        }
        .help(spec.help)
    }

    @ViewBuilder
    private var control: some View {
        switch spec.kind {
        case .toggle:
            Toggle("", isOn: boolBinding).labelsHidden()

        case .negatable:
            Picker("", selection: negatableBinding) {
                Text(inheritedLabel("Default")).tag("")
                Text("On").tag("on")
                Text("Off").tag("off")
            }
            .labelsHidden()
            .frame(width: 120)

        case .choice(let options, let allowsCustom):
            HStack(spacing: 6) {
                Picker("", selection: choiceBinding(options, allowsCustom: allowsCustom)) {
                    Text(inheritedLabel("Default")).tag("")
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                    if allowsCustom { Text("Custom…").tag(customTag) }
                }
                .labelsHidden()
                .frame(width: 160)

                if allowsCustom, isCustomValue(options) {
                    TextField("", text: stringBinding)
                        .frame(width: 160)
                }
            }

        case .optionalValue:
            HStack(spacing: 6) {
                Toggle("", isOn: boolBinding).labelsHidden()
                TextField(optionalPlaceholder, text: stringBinding)
                    .frame(width: 200)
                    .disabled(value == nil)
            }

        case .string:
            TextField(inheritedLabel(""), text: stringBinding).frame(width: 240)

        case .path:
            HStack(spacing: 6) {
                TextField(inheritedLabel(""), text: stringBinding).frame(width: 200)
                Button("Choose…") { chooseFile() }
            }

        case .multiline:
            TextEditor(text: stringBinding)
                .font(.body.monospaced())
                .frame(width: 320, height: 64)
                .border(.separator)

        case .list:
            TextField(inheritedLabel("space-separated"), text: listBinding).frame(width: 320)
        }
    }

    private var customTag: String { "\u{1}custom" }

    private func inheritedLabel(_ fallback: String) -> String {
        guard let inherited else { return fallback }
        switch inherited {
        case .on: return "Inherited: on"
        case .value(let raw): return "Inherited: \(raw)"
        case .list(let items): return "Inherited: \(items.joined(separator: " "))"
        }
    }

    private func isCustomValue(_ options: [String]) -> Bool {
        if case .value(let raw)? = value { return !options.contains(raw) }
        return false
    }

    // MARK: Bindings

    private var boolBinding: Binding<Bool> {
        Binding(
            get: { value != nil },
            set: { value = $0 ? .on : nil }
        )
    }

    private var negatableBinding: Binding<String> {
        Binding(
            get: { if case .value(let raw)? = value { return raw }; return "" },
            set: { value = $0.isEmpty ? nil : .value($0) }
        )
    }

    private func choiceBinding(_ options: [String], allowsCustom: Bool) -> Binding<String> {
        Binding(
            get: {
                guard case .value(let raw)? = value else { return "" }
                return options.contains(raw) ? raw : customTag
            },
            set: { selection in
                if selection.isEmpty {
                    value = nil
                } else if selection == customTag {
                    // Keep any existing custom text; otherwise start empty.
                    if case .value(let raw)? = value, !options.contains(raw) { return }
                    value = .value("")
                } else {
                    value = .value(selection)
                }
            }
        )
    }

    private var stringBinding: Binding<String> {
        Binding(
            get: {
                if case .value(let raw)? = value { return raw }
                return ""
            },
            set: { value = $0.isEmpty ? (value == nil ? nil : .value("")) : .value($0) }
        )
    }

    private var listBinding: Binding<String> {
        Binding(
            get: {
                if case .list(let items)? = value { return items.joined(separator: " ") }
                return ""
            },
            set: { raw in
                let items = raw.split(separator: " ").map(String.init)
                value = items.isEmpty ? (value == nil ? nil : .list([])) : .list(items)
            }
        )
    }

    private var optionalPlaceholder: String {
        value == nil ? "" : "optional"
    }

    private func chooseFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            value = .value(url.path)
        }
    }
}
```

Add `import AppKit` at the top alongside `import SwiftUI` for `NSOpenPanel`.

- [ ] **Step 2: Verify it compiles**

Run: `./scripts/test-unit.sh`
Expected: build succeeds, all existing tests still pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/FlightDeck/Preferences/UI/FlagRow.swift
git commit -m "feat: generic flag control row"
```

---

### Task 11: The flag editor (controls + field + diagnostics)

Shared by the Claude and Projects tabs — the sync logic lives here once.

**Files:**
- Create: `Sources/FlightDeck/Preferences/UI/FlagEditor.swift`

**Interfaces:**
- Consumes: `FlagSpec`, `FlagSet`, `ClaudeFlagCatalog.all`, `ClaudeFlagParser.parse`, `ClaudeFlagSerializer.serialize`, `FlagDiagnostics.validate`, `FlagRow`, `LockedPrefixCommandField`.
- Produces: `FlagEditor(flags:inherited:lockedPrefix:)` where `flags` is `Binding<FlagSet>` and `inherited` is `FlagSet?`.

- [ ] **Step 1: Write the view**

```swift
import SwiftUI

/// The controls, the command field, and the diagnostics beneath it — the whole two-way
/// sync in one place, used by both the Claude tab (global) and the Projects tab (override).
///
/// Sync is asymmetric (design spec §3.3):
/// - controls → text is immediate: any control change re-serializes the tail.
/// - text → controls happens on blur or ⌘↩, so the field is never rewritten mid-typing.
struct FlagEditor: View {
    @Binding var flags: FlagSet
    /// Non-nil in the Projects tab: the globals this override inherits from.
    var inherited: FlagSet?
    let lockedPrefix: String

    @State private var tail: String = ""
    @State private var parseDiagnostics: [Diagnostic] = []

    private var effective: FlagSet {
        guard let inherited else { return flags }
        return FlagSetMerge.merge(global: inherited, project: flags)
    }

    private var diagnostics: [Diagnostic] {
        parseDiagnostics + FlagDiagnostics.validate(effective)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                ForEach(FlagSpec.Section.allCases, id: \.self) { section in
                    Section(section.rawValue) {
                        ForEach(specs(in: section), id: \.canonical) { spec in
                            FlagRow(
                                spec: spec,
                                value: binding(for: spec),
                                inherited: inherited?.values[spec.canonical],
                                onRevert: inherited == nil ? nil : {
                                    flags.values.removeValue(forKey: spec.canonical)
                                    syncTextFromControls()
                                }
                            )
                        }
                    }
                }
            }
            .formStyle(.grouped)

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Launch command")
                    .font(.subheadline.weight(.medium))
                LockedPrefixCommandField(
                    lockedPrefix: lockedPrefix,
                    tail: $tail,
                    onCommit: applyTextToControls
                )
                .frame(height: 60)

                ForEach(Array(diagnostics.enumerated()), id: \.offset) { _, diagnostic in
                    Label {
                        Text(diagnostic.message)
                    } icon: {
                        Image(systemName: diagnostic.severity == .error
                              ? "exclamationmark.octagon.fill"
                              : "exclamationmark.triangle.fill")
                    }
                    .font(.caption)
                    .foregroundStyle(diagnostic.severity == .error ? .red : .orange)
                }

                Text("Applies to new sessions. Running sessions keep the command line they started with.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
        }
        .onAppear { syncTextFromControls() }
    }

    private func specs(in section: FlagSpec.Section) -> [FlagSpec] {
        ClaudeFlagCatalog.all.filter { $0.section == section }
    }

    private func binding(for spec: FlagSpec) -> Binding<FlagValue?> {
        Binding(
            get: { flags.values[spec.canonical] },
            set: { newValue in
                if let newValue {
                    flags.values[spec.canonical] = newValue
                } else {
                    flags.values.removeValue(forKey: spec.canonical)
                }
                syncTextFromControls()
            }
        )
    }

    /// controls → text, immediate.
    private func syncTextFromControls() {
        tail = ClaudeFlagSerializer.serialize(flags)
    }

    /// text → controls, on blur or ⌘↩. A parse *error* (unterminated quote) keeps the last
    /// good `FlagSet` and leaves the controls alone rather than clobbering them from garbage.
    private func applyTextToControls(_ text: String) {
        let result = ClaudeFlagParser.parse(text)
        parseDiagnostics = result.diagnostics
        guard !result.diagnostics.contains(where: { $0.severity == .error }) else { return }
        flags = result.flags
        syncTextFromControls()
    }
}
```

- [ ] **Step 2: Verify it compiles**

Run: `./scripts/test-unit.sh`
Expected: build succeeds, all existing tests still pass.

- [ ] **Step 3: Commit**

```bash
git add Sources/FlightDeck/Preferences/UI/FlagEditor.swift
git commit -m "feat: flag editor with two-way control/text sync"
```

---

### Task 12: The three tabs and the Settings scene

**Files:**
- Create: `Sources/FlightDeck/Preferences/UI/ClaudeSettingsTab.swift`
- Create: `Sources/FlightDeck/Preferences/UI/ProjectsSettingsTab.swift`
- Create: `Sources/FlightDeck/Preferences/UI/ShellSettingsTab.swift`
- Create: `Sources/FlightDeck/Preferences/UI/PreferencesView.swift`
- Modify: `Sources/FlightDeck/FlightDeckApp.swift` (whole file)

**Interfaces:**
- Consumes: `PreferencesStore`, `SessionStore.repos`, `FlagEditor`, `ClaudeSession.lockedPrefix`.
- Produces: `PreferencesView(preferences:sessions:)`.

- [ ] **Step 1: Write `ClaudeSettingsTab.swift`**

```swift
import SwiftUI

/// Global defaults: the flags every new session starts with, in every project.
struct ClaudeSettingsTab: View {
    @ObservedObject var preferences: PreferencesStore

    var body: some View {
        FlagEditor(
            flags: $preferences.preferences.globalFlags,
            inherited: nil,
            lockedPrefix: Self.placeholderPrefix
        )
    }

    /// There is no real session in the global tab, so the immutable prefix shows what
    /// Flight Deck will substitute rather than a concrete id and name.
    static let placeholderPrefix = "claude --session-id ⟨generated⟩ --name ⟨session title⟩"
}
```

- [ ] **Step 2: Write `ProjectsSettingsTab.swift`**

```swift
import SwiftUI

/// Per-project overrides. The project list is the union of currently-open projects and
/// projects with a saved override — a `Repo` vanishes from `SessionStore` when its last
/// session closes, so open projects alone would lose overrides from view.
struct ProjectsSettingsTab: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var sessions: SessionStore
    @State private var selected: String?

    private var paths: [String] {
        let open = sessions.repos.map(\.url.standardizedFileURL.path)
        return Array(Set(open).union(preferences.overriddenProjectPaths)).sorted()
    }

    var body: some View {
        NavigationSplitView {
            List(paths, id: \.self, selection: $selected) { path in
                VStack(alignment: .leading, spacing: 1) {
                    Text(URL(fileURLWithPath: path).lastPathComponent)
                    Text(path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .badge(preferences.projectOverride(path).isEmpty ? nil : Text("override"))
                .tag(path)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } detail: {
            if let selected {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(selected).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Remove Override") {
                            preferences.removeProjectOverride(selected)
                        }
                        .disabled(preferences.projectOverride(selected).isEmpty)
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 8)

                    FlagEditor(
                        flags: binding(for: selected),
                        inherited: preferences.preferences.globalFlags,
                        lockedPrefix: ClaudeSettingsTab.placeholderPrefix
                    )
                }
            } else {
                ContentUnavailableView(
                    "No Project Selected",
                    systemImage: "folder",
                    description: Text("Select a project to override its Claude options.")
                )
            }
        }
    }

    private func binding(for path: String) -> Binding<FlagSet> {
        Binding(
            get: { preferences.projectOverride(path) },
            set: { preferences.setProjectOverride(path, $0) }
        )
    }
}
```

- [ ] **Step 3: Write `ShellSettingsTab.swift`**

```swift
import SwiftUI

/// The shell and environment new sessions are spawned into.
struct ShellSettingsTab: View {
    @ObservedObject var preferences: PreferencesStore
    @State private var newKey = ""
    @State private var newValue = ""

    private var shell: Binding<ShellPreferences> { $preferences.preferences.shell }

    var body: some View {
        Form {
            Section("Shell") {
                LabeledContent("Shell") {
                    HStack(spacing: 6) {
                        TextField(
                            ShellResolver.resolve(),
                            text: Binding(
                                get: { shell.wrappedValue.shellOverride ?? "" },
                                set: { shell.wrappedValue.shellOverride = $0.isEmpty ? nil : $0 }
                            )
                        )
                        .frame(width: 240)
                        Button("Choose…") { chooseShell() }
                    }
                }
                Text("Empty uses $SHELL, falling back to /bin/zsh.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Environment") {
                Toggle(
                    "Clear CLAUDE_CODE_CHILD_SESSION in new sessions",
                    isOn: shell.clearChildSessionMarker
                )
                Text("Claude Code sets this marker for nested sessions, and it turns transcript saving off — which silently stops the sidebar from picking up renames. Leave on unless you know you need it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(shell.wrappedValue.environment.keys.sorted(), id: \.self) { key in
                    LabeledContent(key) {
                        HStack(spacing: 6) {
                            TextField(
                                "",
                                text: Binding(
                                    get: { shell.wrappedValue.environment[key] ?? "" },
                                    set: { shell.wrappedValue.environment[key] = $0 }
                                )
                            )
                            .frame(width: 200)
                            Button {
                                shell.wrappedValue.environment.removeValue(forKey: key)
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }

                LabeledContent("Add") {
                    HStack(spacing: 6) {
                        TextField("NAME", text: $newKey).frame(width: 120)
                        TextField("value", text: $newValue).frame(width: 160)
                        Button("Add") {
                            let key = newKey.trimmingCharacters(in: .whitespaces)
                            guard !key.isEmpty else { return }
                            shell.wrappedValue.environment[key] = newValue
                            newKey = ""
                            newValue = ""
                        }
                        .disabled(newKey.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }

            Section {
                Text("Applies to new sessions. Running sessions keep the environment they started with.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseShell() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/bin")
        if panel.runModal() == .OK, let url = panel.url {
            shell.wrappedValue.shellOverride = url.path
        }
    }
}
```

Add `import AppKit` alongside `import SwiftUI`.

- [ ] **Step 4: Write `PreferencesView.swift`**

```swift
import SwiftUI

struct PreferencesView: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var sessions: SessionStore

    var body: some View {
        TabView {
            ClaudeSettingsTab(preferences: preferences)
                .tabItem { Label("Claude", systemImage: "sparkles") }
                .accessibilityIdentifier("prefs-claude")

            ProjectsSettingsTab(preferences: preferences, sessions: sessions)
                .tabItem { Label("Projects", systemImage: "folder") }
                .accessibilityIdentifier("prefs-projects")

            ShellSettingsTab(preferences: preferences)
                .tabItem { Label("Shell & Environment", systemImage: "terminal") }
                .accessibilityIdentifier("prefs-shell")
        }
        .frame(width: 720, height: 560)
    }
}
```

- [ ] **Step 5: Wire the Settings scene in `FlightDeckApp.swift`**

Replace the whole file. Note the construction order: `PreferencesStore` must exist **before** `SessionStore`, because `SessionStore(ghostty:resetState:preferences:)` restores sessions inside its own initialiser and therefore resolves flags immediately.

```swift
import SwiftUI

@main
struct FlightDeckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var preferences: PreferencesStore
    @StateObject private var store: SessionStore

    init() {
        let resetState = UserDefaults.standard.bool(forKey: "FlightDeckResetState")
        // Preferences first: SessionStore's convenience init restores sessions inline and
        // resolves each one's flags as it goes, so it needs a live store to read from.
        let preferences = PreferencesStore()
        _preferences = StateObject(wrappedValue: preferences)
        _store = StateObject(
            wrappedValue: SessionStore(
                ghostty: GhosttyApp.shared, resetState: resetState, preferences: preferences
            )
        )
    }

    var body: some Scene {
        RootWindow(store: store)
            .commands { SessionCommands(store: store) }

        // A `Settings` scene gives ⌘, and the standard Preferences window for free.
        Settings {
            PreferencesView(preferences: preferences, sessions: store)
        }
    }
}
```

- [ ] **Step 6: Run tests and build**

Run: `./scripts/test-unit.sh`
Expected: build succeeds, every existing suite still passes.

- [ ] **Step 7: Launch and check the window by hand**

```bash
./scripts/build.sh && open DerivedData/Build/Products/Debug/FlightDeck.app
```

Press ⌘, and confirm: three tabs appear; toggling **Verbose** appends `--verbose` to the command field; the `claude --session-id ⟨generated⟩ --name ⟨session title⟩` prefix cannot be selected into or deleted.

- [ ] **Step 8: Commit**

```bash
git add Sources/FlightDeck/Preferences/UI/ClaudeSettingsTab.swift \
        Sources/FlightDeck/Preferences/UI/ProjectsSettingsTab.swift \
        Sources/FlightDeck/Preferences/UI/ShellSettingsTab.swift \
        Sources/FlightDeck/Preferences/UI/PreferencesView.swift \
        Sources/FlightDeck/FlightDeckApp.swift
git commit -m "feat: preferences window with claude, projects, and shell tabs"
```

---

### Task 13: Dangerous-flag confirmation

**Files:**
- Modify: `Sources/FlightDeck/Preferences/UI/FlagEditor.swift`

**Interfaces:**
- Consumes: `FlagEditor`'s existing `binding(for:)`.
- Produces: no new public API.

- [ ] **Step 1: Add the confirmation state**

Add to `FlagEditor`'s properties:

```swift
    @State private var pendingDangerousFlag: FlagSpec?

    /// Flags that silently widen what every future session may do without asking.
    private static let requiresConfirmation: Set<String> = ["--dangerously-skip-permissions"]
```

- [ ] **Step 2: Gate the binding's setter**

Replace `binding(for:)`'s `set` closure with:

```swift
            set: { newValue in
                if newValue != nil, Self.requiresConfirmation.contains(spec.canonical) {
                    pendingDangerousFlag = spec
                    return
                }
                if let newValue {
                    flags.values[spec.canonical] = newValue
                } else {
                    flags.values.removeValue(forKey: spec.canonical)
                }
                syncTextFromControls()
            }
```

- [ ] **Step 3: Attach the alert**

Add to the outermost `VStack`, beside `.onAppear`:

```swift
        .alert(
            "Skip all permission checks?",
            isPresented: Binding(
                get: { pendingDangerousFlag != nil },
                set: { if !$0 { pendingDangerousFlag = nil } }
            ),
            presenting: pendingDangerousFlag
        ) { spec in
            Button("Cancel", role: .cancel) { pendingDangerousFlag = nil }
            Button("Enable", role: .destructive) {
                flags.values[spec.canonical] = .on
                syncTextFromControls()
                pendingDangerousFlag = nil
            }
        } message: { _ in
            Text("Every new session will bypass all permission checks and act without asking. Recommended only for sandboxes with no internet access.")
        }
```

Note: typing `--dangerously-skip-permissions` into the command field bypasses this alert by design — the field is the explicit, expert path, and blocking it there would break the round-trip invariant.

- [ ] **Step 4: Verify by hand**

```bash
./scripts/build.sh && open DerivedData/Build/Products/Debug/FlightDeck.app
```

⌘, → Claude → Permissions & Tools → toggle **Skip all permission checks**. Confirm the alert appears, Cancel leaves it off, Enable turns it on and appends the flag.

- [ ] **Step 5: Run tests and commit**

Run: `./scripts/test-unit.sh`
Expected: all pass.

```bash
git add Sources/FlightDeck/Preferences/UI/FlagEditor.swift
git commit -m "feat: confirm before enabling permission bypass"
```

---

### Task 14: UITests and documentation

**Files:**
- Modify: `UITests/FlightDeckUITests/TerminalSmokeTests.swift`
- Modify: `docs/ARCHITECTURE.md`, `docs/FOLLOWUPS.md`

> **Do NOT create a new UI test class or a new test method.** The UI suite is deliberately
> **one app launch total** — every `launch()` seizes the machine's foreground, so the suite
> is a single session that accumulates assertions in dependency order. Add the preferences
> checks as new `XCTContext.runActivity` groups inside the existing
> `testTheWholeShellInOneSession`, positioned **after** the close-session group and
> **before** the ⌘Q group (⌘Q terminates the app and must stay last).

**Interfaces:**
- Consumes: the accessibility identifiers from Task 12.
- Produces: nothing.

- [ ] **Step 1: Read an existing UITest for the launch idiom**

Run: `ls UITests/FlightDeckUITests/ && head -40 UITests/FlightDeckUITests/*.swift`

Match how it launches the app — in particular the `-ApplePersistenceIgnoreState YES` argument (without it the window never materialises under XCUITest; see `docs/done/HANDOFF-smoke-gate.md`) and `-FlightDeckResetState YES`.

- [ ] **Step 2: Add the preferences groups to the existing single session**

Insert these into `testTheWholeShellInOneSession`, after the "closing a session keeps the app
alive" group and before the ⌘Q group. They share the already-running `app` — no new launch.

```swift
        XCTContext.runActivity(named: "⌘, opens Preferences with three tabs") { _ in
            app.typeKey(",", modifierFlags: .command)
            let prefs = app.windows["Preferences"]
            XCTAssertTrue(prefs.waitForExistence(timeout: 5), "Preferences window did not open")
            XCTAssertTrue(prefs.buttons["Claude"].exists)
            XCTAssertTrue(prefs.buttons["Projects"].exists)
            XCTAssertTrue(prefs.buttons["Shell & Environment"].exists)
        }

        XCTContext.runActivity(named: "toggling a control updates the command field") { _ in
            let prefs = app.windows["Preferences"]
            prefs.buttons["Claude"].click()
            let field = prefs.textViews.firstMatch
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            XCTAssertFalse((field.value as? String ?? "").contains("--verbose"))

            prefs.checkBoxes.matching(identifier: "Verbose").firstMatch.click()
            expectation(
                for: NSPredicate(format: "value CONTAINS %@", "--verbose"), evaluatedWith: field
            )
            waitForExpectations(timeout: 5)
        }

        // The other direction of the sync, and the reason ⌘↩ exists: commit without blurring.
        XCTContext.runActivity(named: "typing in the command field updates the controls") { _ in
            let prefs = app.windows["Preferences"]
            let field = prefs.textViews.firstMatch
            let checkbox = prefs.checkBoxes.matching(identifier: "Brief").firstMatch
            XCTAssertEqual(checkbox.value as? Int, 0)

            field.click()
            field.typeText(" --brief")
            field.typeKey(.return, modifierFlags: .command)

            expectation(for: NSPredicate(format: "value == 1"), evaluatedWith: checkbox)
            waitForExpectations(timeout: 5)
        }

        // The whole point of the locked prefix: select-all + delete must not destroy it.
        XCTContext.runActivity(named: "the locked prefix survives select-all and delete") { _ in
            let prefs = app.windows["Preferences"]
            let field = prefs.textViews.firstMatch
            field.click()
            field.typeKey("a", modifierFlags: .command)
            field.typeKey(.delete, modifierFlags: [])

            let value = field.value as? String ?? ""
            XCTAssertTrue(value.hasPrefix("claude --session-id"), "locked prefix was destroyed: \(value)")
        }

        // Close Preferences so the ⌘Q group below acts on the main window.
        app.typeKey("w", modifierFlags: .command)
```

If `identifier: "Verbose"` / `"Brief"` do not match, add `.accessibilityIdentifier(spec.label)`
to `FlagRow`'s `control` in `FlagRow.swift`. Note `--verbose` is toggled on by the second group
and left on, which is why the third group asserts on a *different* flag (`--brief`) rather than
re-using `--verbose` — in a single shared session, earlier groups' mutations persist.

- [ ] **Step 3: Run the UITests**

Run: `./scripts/smoke.sh`
Expected: `SMOKE PASS`, then run the preferences suite:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeck \
  -destination 'platform=macOS' -derivedDataPath DerivedData \
  test -only-testing:FlightDeckUITests/PreferencesUITests
```

Expected: 4 tests pass. If the window title is not "Preferences", read the actual title from the failure output and fix the accessor — macOS localizes it and it may be "FlightDeck Settings".

- [ ] **Step 4: Update `docs/ARCHITECTURE.md`**

Add a section after "Runtime model":

```markdown
## Preferences

`Sources/FlightDeck/Preferences/` holds a pure core and a SwiftUI shell over it.

The core is a declarative `FlagSpec` catalog (`ClaudeFlagCatalog`, a snapshot of
`claude --help` at 2026-08-11) plus four pure functions: `ClaudeFlagQuoting` (tokenize /
quote), `ClaudeFlagParser` (text → `FlagSet` + diagnostics), `ClaudeFlagSerializer`
(`FlagSet` → text), and `FlagSetMerge` (project over global, per flag). The invariant
`parse(serialize(x)) == x` is what makes the two-way sync between the controls and the
command field safe; it is pinned in `ClaudeFlagSerializerTests`.

`PreferencesStore` (owned by `FlightDeckApp`, constructed **before** `SessionStore` because
that store restores inline) persists to `UserDefaults` behind `PreferencesPersisting`.
`SessionStore.insertSession` reads it once per session at creation: preferences configure
*new* sessions and never reconfigure a running one.

Project overrides are keyed by standardized path in `Preferences.projectFlags`, not held on
`Repo` — a `Repo` is removed when its last session closes, and an override must outlive that.

Unknown flags are preserved verbatim in `FlagSet.passthrough` and warned about rather than
rejected, so a `claude` release that adds a flag does not make the field lossy.
```

- [ ] **Step 5: Update `docs/FOLLOWUPS.md`**

Under "Deferred from session name sync (2026-08-11)", amend the `CLAUDE_CODE_CHILD_SESSION` entry by appending:

```markdown
  **Update (preferences, 2026-08-11):** now fixed behind a preference. `ShellSettingsTab`
  exposes *Clear `CLAUDE_CODE_CHILD_SESSION` in new sessions*, defaulted **on**, which blanks
  an inherited marker via `Ghostty.SurfaceConfiguration.environmentVariables`. The marker is
  blanked rather than unset because the surface config can only set variables; `claude`
  treats an empty value as absent.
```

Add a new entry under "Minor cleanups":

```markdown
- **The flag catalog is a snapshot of `claude --help` at 2026-08-11.** New `claude` releases
  add options that will fall through to passthrough with a warning until the catalog is
  updated. That degradation is by design, but the catalog is worth re-auditing whenever
  Claude Code ships a notable release.
```

- [ ] **Step 6: Commit**

```bash
git add UITests/FlightDeckUITests/PreferencesUITests.swift docs/ARCHITECTURE.md docs/FOLLOWUPS.md
git commit -m "test: preferences UITests; docs: architecture and followups"
```

---

## Self-Review

**Spec coverage.** Design §2 → Tasks 1–5. §2.1 quoting-as-security → Task 1 Step 1 (`testQuoteThenTokenizeRoundTripsIncludingInjectionAttempt`) and Task 7 (`testFlagValuesAreQuotedNotStripped`). §3.1 catalog → Task 2. §3.2 locked prefix → Tasks 7 (`lockedPrefix`) and 9. §3.3 asymmetric sync → Task 11. §4 diagnostics → Tasks 3, 5, 13. §5 persistence, incl. overrides outliving their `Repo` → Task 6. §6 Projects tab, incl. absent-vs-empty → Tasks 5, 6, 10, 12. §7 Shell tab → Tasks 6, 12. §8 launch wiring, both resume branches → Tasks 7, 8. §9 testing → covered per task, plus Task 14. §10 out-of-scope items appear in no task, as intended. §11 risks: the locked-prefix field is isolated in Task 9 with its fallback documented.

**Type consistency.** `FlagSet`/`FlagValue`/`Diagnostic` (Task 1) are used unchanged through Task 12. `ClaudeFlagQuoting.tokenize`/`quoteIfNeeded` (1) are consumed by Tasks 3 and 4. `ClaudeFlagCatalog.spec(for:)`/`.all`/`.appManaged` (2) by Tasks 3, 4, 11. `ClaudeFlagParser.ParseResult` (3) by Task 11. `ClaudeFlagSerializer.serialize` (4) by Tasks 7, 11. `FlagSetMerge.merge(global:project:)` (5) by Tasks 6, 11. `FlagDiagnostics.validate` (5) by Task 11. `PreferencesStore`'s five accessors (6) by Tasks 8 and 12. `ClaudeSession.lockedPrefix` (7) by Task 12. `FlagRow`'s four parameters (10) match every call site in Task 11. `ShellResolver.resolve(environment:override:)` (6) matches its caller in `PreferencesStore.resolvedShell`.

**Known soft spots, called out rather than hidden.** Task 14's UITest selectors (window title, checkbox identifiers) are the least certain thing in this plan — macOS names the Settings window inconsistently across versions, so that step includes explicit instructions for reading the real name from the failure output rather than guessing again. Task 8 assumes `SessionLaunchTests` either has a surface-recording fake or will accept the one supplied; the step says to check first and reuse.
