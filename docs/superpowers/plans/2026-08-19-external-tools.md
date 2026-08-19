# External Tools Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Launch external tools (editor, terminal, git client) from Flight Deck by menu shortcut or by translucent buttons floating over the terminal, configured in a new Tools preferences pane.

**Architecture:** A tool is a shell command template with an SF Symbol and a recorded chord. Everything agent-shaped reaches the tools subsystem through `AgentAdapter`; everything else is a pure value type. Expansion is a pure function, launching goes through `$SHELL -lc` detached, the menu is AppKit (SwiftUI cannot vary a key equivalent at runtime), and the overlay's fade is a clock-free state machine driven by one passive `NSEvent` monitor.

**Tech Stack:** Swift 5 / SwiftUI / AppKit, XCTest, xcodegen + xcodebuild.

**Spec:** `docs/superpowers/specs/2026-08-19-external-tools-design.md` — read it before Task 1. The plan argues from the spec; where this document says "because", the spec says why at length.

## Global Constraints

- `SWIFT_VERSION: "5.0"` is deliberate (vendored Ghostty is not Swift-6 clean). Never "fix" it.
- Deployment target macOS 14.0.
- **No `project.yml` change is needed.** `sources: - Sources/FlightDeck` is a directory reference, so a new `Sources/FlightDeck/Tools/` folder is picked up automatically. Same for `Tests/FlightDeckTests`.
- TDD, and **confirm the test fails against the missing/broken code before implementing.** Never weaken an assertion to go green.
- Comments explain *why* and name the failure they prevent. That is the house style; match it.
- Tests are XCTest: `@MainActor final class XTests: XCTestCase` + `@testable import FlightDeck`.
- Test loop is `./scripts/test-unit.sh` (headless). **Never run `./scripts/smoke.sh`** for this feature — it seizes the foreground for ~70s and captures the user's keystrokes as phantom failures.
- **Never launch a bundle from `DerivedData/`.** Flight Deck has no argv parsing, so even `--help` boots a second full app instance that spawns duplicate `claude --resume` processes. Verification in this plan is "build succeeds + unit tests pass"; visual checks are handed to the user.
- This checkout is **shared by concurrent sessions.** Never `git stash`, `git checkout .`, or revert. Stage only the files you touched, by name.
- Commits: lowercase, behavioral, imperative subject; body covers mechanism and rejected alternatives; trailer `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`.
- Every `xcodebuild` needs `DEVELOPER_DIR` and `-derivedDataPath DerivedData` — the scripts handle both. Never `sudo xcode-select`.

---

### Task 1: The adapter boundary — `AgentLocation`

Nothing in the tools subsystem may read `Session.transcriptPath`, `Session.transcriptDirectory` or `Session.pinnedConversationID`, or call `ClaudeSession`. `AgentBinding` already normalizes conversation id and transcript URL; the working directory has no accessor. This task adds one.

**Files:**
- Modify: `Sources/FlightDeck/Agents/AgentKind.swift` (add `AgentLocation` after `AgentBinding`)
- Modify: `Sources/FlightDeck/Agents/AgentAdapter.swift` (protocol requirement + extension default)
- Test: `Tests/FlightDeckTests/AgentLocationTests.swift`

**Interfaces:**
- Consumes: existing `AgentBinding`, `AgentAdapter.binding(for:)`, `Session`.
- Produces: `struct AgentLocation: Equatable, Sendable { let workingDirectory: String; let binding: AgentBinding }` and `AgentAdapter.location(for: Session) -> AgentLocation`. Task 5 is the only consumer.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/AgentLocationTests.swift`:

```swift
import XCTest
@testable import FlightDeck

/// The seam that keeps claude's path derivation out of the tools subsystem. These tests pin
/// that a location is the ADAPTER's answer — not a field read — which is what makes a third
/// agent able to disagree.
@MainActor
final class AgentLocationTests: XCTestCase {
    private func session(cwd: String, live: String) -> Session {
        Session(title: "w", workingDirectory: cwd, transcriptDirectory: live)
    }

    func testDefaultReportsTheAgentsLiveDirectoryNotTheFiledProject() {
        // A worktree is the case that separates the two: the tab stays filed under the
        // project, but the agent is working somewhere else and that is where a tool goes.
        let s = session(cwd: "/w/a", live: "/w/a/.claude/worktrees/tools")
        XCTAssertEqual(
            ClaudeAdapter().location(for: s).workingDirectory,
            "/w/a/.claude/worktrees/tools"
        )
    }

    func testDefaultCarriesTheAdaptersOwnBinding() {
        let adapter = ClaudeAdapter()
        let s = session(cwd: "/w/a", live: "/w/a")
        XCTAssertEqual(adapter.location(for: s).binding, adapter.binding(for: s),
                       "a location must not invent a second identity rule")
    }

    func testAnAdapterMayOverrideTheDefault() {
        // The whole point of the seam: an agent whose cwd is not `transcriptDirectory` has
        // somewhere to say so. Without an override point this would be a field read.
        let s = session(cwd: "/w/a", live: "/w/a")
        XCTAssertEqual(RelocatingAdapter().location(for: s).workingDirectory, "/elsewhere")
    }

    /// Mirrors `ClaudeAdapter` with only `location` replaced.
    private struct RelocatingAdapter: AgentAdapter {
        static let id: AgentID = .claude
        func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding {
            binding(for: session)
        }
        func binding(for session: Session) -> AgentBinding {
            AgentBinding(conversationID: session.pinnedConversationID, transcriptURL: nil)
        }
        func location(for session: Session) -> AgentLocation {
            AgentLocation(workingDirectory: "/elsewhere", binding: binding(for: session))
        }
        func launchCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "" }
        func resumeCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "" }
        func rename(_: AgentBinding, to: String) async throws {}
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `value of type 'ClaudeAdapter' has no member 'location'`.

- [ ] **Step 3: Add `AgentLocation`**

In `Sources/FlightDeck/Agents/AgentKind.swift`, immediately after the `AgentBinding` declaration:

```swift
/// Where an agent is working right now, and what it is bound to.
///
/// The adapter's answer to "describe this live session", so a caller never learns which agent
/// produced it. `AgentBinding` alone was not enough: it settles *identity*, which is fixed at
/// prepare time, while the working directory moves for the life of the tab — an agent that
/// enters a worktree changes where a tool should point without changing what it is bound to.
struct AgentLocation: Equatable, Sendable {
    let workingDirectory: String
    let binding: AgentBinding
}
```

- [ ] **Step 4: Add the protocol requirement and its default**

In `Sources/FlightDeck/Agents/AgentAdapter.swift`, add to the `AgentAdapter` protocol body (after `binding(for:)`):

```swift
    /// Where this session's agent is working right now, paired with its binding.
    ///
    /// The one accessor the tools subsystem is allowed to use: `Session.transcriptDirectory`
    /// reads as claude-specific and is not, so a caller reading it directly would be
    /// hardcoding a coincidence rather than asking the agent.
    func location(for session: Session) -> AgentLocation
```

and to the existing `extension AgentAdapter`:

```swift
    /// Both shipped agents agree that `transcriptDirectory` is where they are working —
    /// `CodexAdapter.prepare` passes it as codex's own thread cwd, and its `launchCommand`
    /// requires the pty to be spawned there. Stating that once here, rather than in every
    /// adapter, is the same trade `rebind`'s default makes: an agent opts *in* to a different
    /// answer instead of every adapter restating the common one.
    func location(for session: Session) -> AgentLocation {
        AgentLocation(workingDirectory: session.transcriptDirectory, binding: binding(for: session))
    }
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS, including the pre-existing `ClaudeAdapterTests` and `CodexAdapterTests` (the default is additive; no adapter changes behaviour).

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Agents/AgentKind.swift Sources/FlightDeck/Agents/AgentAdapter.swift Tests/FlightDeckTests/AgentLocationTests.swift
git commit -m "$(cat <<'EOF'
feat: let an adapter say where its agent is working

AgentBinding settles identity at prepare time, but the working directory
moves for the life of a tab: an agent entering a worktree changes where a
tool should point without changing what it is bound to. There was no
normalized accessor for that, only Session.transcriptDirectory — which
reads as claude-specific and is not. CodexAdapter.prepare passes it as
codex's own thread cwd, and its launchCommand requires the pty to spawn
there.

Reading that field from a caller would hardcode today's agreement between
two adapters. AgentLocation plus location(for:) states it once in the
adapter layer with an override point, shaped like rebind's default so an
agent opts in to a different answer rather than every adapter restating the
common one.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: `ToolContext` and `ToolTemplate` — pure expansion

The heart of the feature, and the place its worst bug would live. Shell quoting is why this is a tested pure function rather than string interpolation at a call site.

**Files:**
- Create: `Sources/FlightDeck/Tools/ToolContext.swift`
- Create: `Sources/FlightDeck/Tools/ToolTemplate.swift`
- Test: `Tests/FlightDeckTests/ToolTemplateTests.swift`

**Interfaces:**
- Consumes: `AgentID` (existing).
- Produces: `ToolContext` (memberwise init, all properties `var`), `ToolTemplate.expand(_ template: String, in context: ToolContext) -> String`, `ToolTemplate.quote(_ value: String) -> String`, `ToolTemplate.knownNames: Set<String>`. Tasks 5, 6, 7, 9 and 10 consume these.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/ToolTemplateTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class ToolTemplateTests: XCTestCase {
    private func context(
        cwd: String = "/w/a",
        transcript: String? = "/t/x.jsonl"
    ) -> ToolContext {
        ToolContext(
            workingDirectory: cwd,
            projectPath: "/w",
            projectName: "w",
            sessionTitle: "tools",
            agent: .claude,
            conversationID: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            transcriptPath: transcript,
            home: "/Users/nate"
        )
    }

    func testEveryKnownVariableExpands() {
        let c = context()
        XCTAssertEqual(ToolTemplate.expand("${cwd}", in: c), "'/w/a'")
        XCTAssertEqual(ToolTemplate.expand("${project}", in: c), "'/w'")
        XCTAssertEqual(ToolTemplate.expand("${root}", in: c), "'/w'")
        XCTAssertEqual(ToolTemplate.expand("${projectName}", in: c), "'w'")
        XCTAssertEqual(ToolTemplate.expand("${session}", in: c), "'tools'")
        XCTAssertEqual(ToolTemplate.expand("${agent}", in: c), "'claude'")
        XCTAssertEqual(ToolTemplate.expand("${transcript}", in: c), "'/t/x.jsonl'")
        XCTAssertEqual(ToolTemplate.expand("${home}", in: c), "'/Users/nate'")
        XCTAssertEqual(
            ToolTemplate.expand("${conversationID}", in: c),
            "'11111111-2222-3333-4444-555555555555'"
        )
    }

    func testAPathWithSpacesStaysOneArgument() {
        // The bug this whole type exists to prevent: `$EDITOR /Users/nate/My Projects/foo`
        // opens two files, neither of them the one you wanted.
        let expanded = ToolTemplate.expand("$EDITOR ${cwd}", in: context(cwd: "/Users/nate/My Projects/foo"))
        XCTAssertEqual(expanded, "$EDITOR '/Users/nate/My Projects/foo'")
    }

    func testASingleQuoteInAPathIsEscaped() {
        let expanded = ToolTemplate.expand("${cwd}", in: context(cwd: "/w/nate's code"))
        XCTAssertEqual(expanded, #"'/w/nate'\''s code'"#)
    }

    func testDollarEditorIsLeftForTheLoginShell() {
        // Unbraced shell variables are not ours to expand — resolving $EDITOR is exactly what
        // the login shell is for, and rewriting it here would break every user whose editor
        // is set in their profile.
        XCTAssertEqual(ToolTemplate.expand("$EDITOR", in: context()), "$EDITOR")
    }

    func testUnknownBracedNamesAreLeftLiteralForTheShell() {
        XCTAssertEqual(ToolTemplate.expand("${HOME}/x", in: context()), "${HOME}/x")
        XCTAssertEqual(ToolTemplate.expand("${nope}", in: context()), "${nope}")
    }

    func testAKnownNameWithNoValueExpandsToAnEmptyQuotedString() {
        // NOT to nothing. `code ${transcript} ${cwd}` with an absent transcript must not
        // silently slide the cwd into the transcript's argument position.
        XCTAssertEqual(
            ToolTemplate.expand("code ${transcript} ${cwd}", in: context(transcript: nil)),
            "code '' '/w/a'"
        )
    }

    func testSurroundingTextAndRepeatsSurvive() {
        XCTAssertEqual(
            ToolTemplate.expand("cd ${cwd} && git -C ${cwd} status", in: context()),
            "cd '/w/a' && git -C '/w/a' status"
        )
    }

    func testAnUnterminatedBraceIsLeftAlone() {
        XCTAssertEqual(ToolTemplate.expand("echo ${cwd", in: context()), "echo ${cwd")
    }

    func testEmptyTemplateIsEmpty() {
        XCTAssertEqual(ToolTemplate.expand("", in: context()), "")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `cannot find 'ToolContext' in scope`.

- [ ] **Step 3: Write `ToolContext`**

Create `Sources/FlightDeck/Tools/ToolContext.swift`:

```swift
import Foundation

/// The values a tool's command template can interpolate, for one selected session.
///
/// A plain value type on purpose: it holds no adapter, no store and no view, which is what
/// lets `ToolTemplate` be a pure function and lets these tests run without a window.
///
/// The first three fields come from `AgentAdapter.location(for:)` — never from `Session`
/// directly, see `SessionStore.toolContext()`. The rest are Flight Deck's own facts about the
/// tab and the project it is filed under, which no agent has an opinion about.
struct ToolContext: Equatable {
    /// Where the agent is working right now, worktree included.
    var workingDirectory: String
    /// The project root the tab is filed under. Differs from `workingDirectory` in a worktree.
    var projectPath: String
    var projectName: String
    var sessionTitle: String
    var agent: AgentID
    var conversationID: UUID
    /// Optional because `AgentBinding.transcriptURL` is: an agent that reports no transcript
    /// is still usable. See `ToolTemplate.expand` for why this expands to `''`, not to "".
    var transcriptPath: String?
    var home: String = NSHomeDirectory()
}
```

- [ ] **Step 4: Write `ToolTemplate`**

Create `Sources/FlightDeck/Tools/ToolTemplate.swift`:

```swift
import Foundation

/// Expands a tool's command template against one session's context.
///
/// Pure — no `Process`, no SwiftUI, no adapter — so the quoting rules below are assertable
/// without a window, which matters because they are the likeliest place for this feature to be
/// quietly wrong.
enum ToolTemplate {
    static let knownNames: Set<String> = [
        "cwd", "project", "root", "projectName",
        "session", "agent", "conversationID", "transcript", "home",
    ]

    /// Wraps a value so the shell sees exactly one argument.
    ///
    /// Single quotes rather than backslash escaping because inside single quotes the shell
    /// interprets nothing at all — no `$`, no backtick, no glob. The one character that cannot
    /// appear is `'` itself, which is closed, escaped, and reopened.
    static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }

    /// Substitutes `${name}` for every name in `knownNames`; leaves everything else alone.
    ///
    /// Three behaviours, and they are deliberately different from one another:
    ///
    /// - **A known name with a value** becomes that value, shell-quoted. `$EDITOR ${cwd}` over
    ///   a path containing a space must open one file, not two.
    /// - **A known name with no value** becomes `''`. Emitting nothing would let the command
    ///   silently absorb its *next* argument into the empty position — `code ${transcript}
    ///   ${cwd}` would open the cwd as the transcript. An empty quoted string keeps the
    ///   argument count intact and fails visibly instead.
    /// - **An unknown name** is left literal, braces and all, and reaches the login shell
    ///   unchanged. That is not an oversight: it is what makes `$EDITOR`, `${HOME}` and command
    ///   substitution behave exactly as they would if typed. The cost is that `${cwd}` shadows
    ///   a shell variable of that name, which the preferences pane states.
    static func expand(_ template: String, in context: ToolContext) -> String {
        var out = ""
        var rest = Substring(template)

        while let open = rest.range(of: "${") {
            out += rest[rest.startIndex..<open.lowerBound]

            // An unterminated `${` is a typo, not a variable. Emit it verbatim rather than
            // swallowing the remainder of the command.
            guard let close = rest[open.upperBound...].firstIndex(of: "}") else {
                out += rest[open.lowerBound...]
                return out
            }

            let name = String(rest[open.upperBound..<close])
            if let value = value(for: name, in: context) {
                out += quote(value)
            } else if knownNames.contains(name) {
                out += "''"
            } else {
                out += rest[open.lowerBound...close]
            }
            rest = rest[rest.index(after: close)...]
        }

        return out + rest
    }

    /// nil means either "not a known name" or "known but absent"; `expand` tells them apart
    /// with `knownNames`, because they must produce different output.
    private static func value(for name: String, in context: ToolContext) -> String? {
        switch name {
        case "cwd": return context.workingDirectory
        case "project", "root": return context.projectPath
        case "projectName": return context.projectName
        case "session": return context.sessionTitle
        case "agent": return context.agent.rawValue
        case "conversationID": return context.conversationID.uuidString
        case "transcript": return context.transcriptPath
        case "home": return context.home
        default: return nil
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS, all 9 `ToolTemplateTests` cases.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Tools/ToolContext.swift Sources/FlightDeck/Tools/ToolTemplate.swift Tests/FlightDeckTests/ToolTemplateTests.swift
git commit -m "$(cat <<'EOF'
feat: expand tool command templates without breaking on spaces

Substituted values are single-quoted, because a path with a space in it
would otherwise word-split and `$EDITOR ${cwd}` would open two files,
neither of them the right one. Single quotes rather than backslashes: the
shell interprets nothing inside them, so a path containing $, a backtick or
a glob character survives untouched.

Three cases that had to differ. A known name with a value is quoted. A
known name with no value — transcriptURL is Optional by design — becomes ''
rather than nothing, so the command cannot slide its next argument into the
empty position. An unknown name is left literal and reaches the login
shell, which is what makes $EDITOR and ${HOME} behave as typed.

Pure, so all of that is assertable without a window. This is the likeliest
place for the feature to be quietly wrong.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: `ToolDefinition` and `ToolShortcut`

**Files:**
- Create: `Sources/FlightDeck/Tools/ToolDefinition.swift`
- Create: `Sources/FlightDeck/Tools/ToolShortcut.swift`
- Test: `Tests/FlightDeckTests/ToolShortcutTests.swift`

**Interfaces:**
- Produces: `ToolDefinition(id:name:symbol:command:shortcut:showsInOverlay:)` with `let id: UUID` and all else `var`; `ToolShortcut(key:modifiers:)` taking `NSEvent.ModifierFlags`, with `var modifierFlags: NSEvent.ModifierFlags` and `var displayString: String`. Tasks 4, 7, 9, 10 consume these.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/ToolShortcutTests.swift`:

```swift
import AppKit
import XCTest
@testable import FlightDeck

@MainActor
final class ToolShortcutTests: XCTestCase {
    func testKeyIsLowercasedSoItMatchesAMenuKeyEquivalent() {
        // `NSMenuItem.keyEquivalent` is case-sensitive, and an uppercase letter there means
        // "shift is part of the equivalent" — recording "O" would produce a chord that needs
        // shift held on top of whatever modifiers were captured.
        XCTAssertEqual(ToolShortcut(key: "O", modifiers: [.command]).key, "o")
    }

    func testOnlyDeviceIndependentModifiersAreStored() {
        // A raw `NSEvent.modifierFlags` carries device-dependent bits and caps lock; storing
        // them would make an otherwise-identical chord fail to compare equal across launches.
        let recorded = ToolShortcut(key: "o", modifiers: [.command, .capsLock])
        XCTAssertFalse(recorded.modifierFlags.contains(.capsLock))
        XCTAssertTrue(recorded.modifierFlags.contains(.command))
    }

    func testRoundTripsThroughAMenuItem() {
        let shortcut = ToolShortcut(key: "o", modifiers: [.command, .shift])
        let item = NSMenuItem(title: "Editor", action: nil, keyEquivalent: shortcut.key)
        item.keyEquivalentModifierMask = shortcut.modifierFlags
        XCTAssertEqual(item.keyEquivalent, "o")
        XCTAssertEqual(item.keyEquivalentModifierMask, [.command, .shift])
    }

    func testDisplayStringUsesTheConventionalModifierOrder() {
        // Same order `NewSessionAffordance.display` uses, which is the order macOS renders.
        XCTAssertEqual(ToolShortcut(key: "o", modifiers: [.command]).displayString, "⌘O")
        XCTAssertEqual(ToolShortcut(key: "g", modifiers: [.command, .shift]).displayString, "⇧⌘G")
        XCTAssertEqual(
            ToolShortcut(key: "t", modifiers: [.command, .shift, .option, .control]).displayString,
            "⌃⌥⇧⌘T"
        )
    }

    func testCodableRoundTrip() throws {
        let tool = ToolDefinition(
            name: "Editor",
            symbol: "chevron.left.forwardslash.chevron.right",
            command: "$EDITOR ${cwd}",
            shortcut: ToolShortcut(key: "o", modifiers: [.command])
        )
        let data = try JSONEncoder().encode(tool)
        XCTAssertEqual(try JSONDecoder().decode(ToolDefinition.self, from: data), tool)
    }

    func testAToolDefaultsToShowingInTheOverlay() {
        XCTAssertTrue(ToolDefinition(name: "x", symbol: "gear", command: "true").showsInOverlay)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `cannot find 'ToolShortcut' in scope`.

- [ ] **Step 3: Write `ToolShortcut`**

Create `Sources/FlightDeck/Tools/ToolShortcut.swift`:

```swift
import AppKit

/// A recorded chord, stored in `NSEvent`'s vocabulary rather than SwiftUI's `EventModifiers`.
///
/// That choice is what makes the Tools menu possible at all: these values are assigned
/// straight onto `NSMenuItem.keyEquivalent` / `keyEquivalentModifierMask`, and the menu has to
/// be AppKit because SwiftUI cannot vary a `.keyboardShortcut` at runtime (see
/// `SessionCommands`) while a user-recorded chord is dynamic by definition.
struct ToolShortcut: Codable, Equatable {
    /// Always lowercase. `NSMenuItem.keyEquivalent` is case-sensitive, and an uppercase letter
    /// there means "shift is part of the equivalent" — so storing "O" would silently demand
    /// shift on top of whatever modifiers were recorded.
    var key: String
    /// `NSEvent.ModifierFlags` raw value, masked to the device-independent bits. Unmasked
    /// flags carry device-dependent bits and caps lock, which would make two otherwise
    /// identical chords compare unequal across launches.
    var modifiers: UInt

    init(key: String, modifiers: NSEvent.ModifierFlags) {
        self.key = key.lowercased()
        self.modifiers = modifiers
            .intersection(.deviceIndependentFlagsMask)
            .intersection([.command, .control, .option, .shift])
            .rawValue
    }

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// The order macOS renders modifiers in, matching `NewSessionAffordance.display`.
    var displayString: String {
        var s = ""
        if modifierFlags.contains(.control) { s += "⌃" }
        if modifierFlags.contains(.option) { s += "⌥" }
        if modifierFlags.contains(.shift) { s += "⇧" }
        if modifierFlags.contains(.command) { s += "⌘" }
        return s + key.uppercased()
    }
}
```

- [ ] **Step 4: Write `ToolDefinition`**

Create `Sources/FlightDeck/Tools/ToolDefinition.swift`:

```swift
import Foundation

/// One external tool: a shell command template, an icon, and an optional chord.
///
/// The array's ORDER is semantic, like `AgentSettings`': it is the overlay's left-to-right
/// order, which is why the preferences list is drag-reorderable.
struct ToolDefinition: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    /// An SF Symbol name. Symbols rather than app icons because they are monochrome templates
    /// that tint cleanly against `.regularMaterial` at any opacity, and cost one string rather
    /// than a stored bundle path that can go stale.
    var symbol: String
    /// A `ToolTemplate` template, e.g. `$EDITOR ${cwd}`.
    var command: String
    /// nil means the tool is still reachable from the menu and the overlay, just unbound.
    var shortcut: ToolShortcut?
    var showsInOverlay: Bool

    init(
        id: UUID = UUID(),
        name: String,
        symbol: String,
        command: String,
        shortcut: ToolShortcut? = nil,
        showsInOverlay: Bool = true
    ) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.command = command
        self.shortcut = shortcut
        self.showsInOverlay = showsInOverlay
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS, all 6 `ToolShortcutTests` cases.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Tools/ToolShortcut.swift Sources/FlightDeck/Tools/ToolDefinition.swift Tests/FlightDeckTests/ToolShortcutTests.swift
git commit -m "$(cat <<'EOF'
feat: model an external tool and its recorded chord

Shortcuts are stored in NSEvent's vocabulary, not SwiftUI's EventModifiers,
because the Tools menu has to be AppKit: SessionCommands already documents
that .keyboardShortcut cannot vary at runtime, and a user-recorded chord is
dynamic by definition. These values assign straight onto NSMenuItem.

Two normalizations that are bugs if skipped. The key is lowercased, since
NSMenuItem.keyEquivalent is case-sensitive and an uppercase letter there
means shift is part of the equivalent — "O" would demand shift on top of
the recorded modifiers. Modifiers are masked to the device-independent set,
since raw flags carry caps lock and device-dependent bits that make two
identical chords compare unequal across launches.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Storage, defaults, and the terminal probe

**Files:**
- Create: `Sources/FlightDeck/Tools/DefaultTerminalResolver.swift`
- Modify: `Sources/FlightDeck/Preferences/Preferences.swift` (add `storedTools`, `tools`, `defaultTools`, `migrateToolsIfNeeded`; extend `init`)
- Modify: `Sources/FlightDeck/Preferences/PreferencesStore.swift` (call the migration in `init`; expose `tools`)
- Test: `Tests/FlightDeckTests/ToolPreferencesTests.swift`

**Interfaces:**
- Consumes: `ToolDefinition`, `ToolShortcut` (Task 3).
- Produces: `Preferences.storedTools: [ToolDefinition]?`, `Preferences.tools: [ToolDefinition]`, `static Preferences.defaultTools(terminalCommand:) -> [ToolDefinition]`, `Preferences.migrateToolsIfNeeded(terminalCommand:)`, `DefaultTerminalResolver.command(isInstalled:) -> String`, `PreferencesStore.tools` (get/set). Tasks 7, 9, 10 consume `PreferencesStore.tools`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/ToolPreferencesTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class ToolPreferencesTests: XCTestCase {
    /// Same in-memory stand-in `PreferencesStoreTests` uses, so no test touches the real
    /// defaults domain.
    private final class MemoryPersistence: PreferencesPersisting {
        var stored: Preferences?
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences }
    }

    // MARK: DefaultTerminalResolver

    func testResolverPrefersTheFirstInstalledCandidate() {
        let command = DefaultTerminalResolver.command { $0 == "com.googlecode.iterm2" }
        XCTAssertEqual(command, "open -b com.googlecode.iterm2 ${cwd}")
    }

    func testResolverFallsBackToAppleTerminalWhenNothingIsFound() {
        // Terminal.app cannot be absent from macOS, so this is the honest floor rather than
        // an empty command the user would have to debug.
        XCTAssertEqual(
            DefaultTerminalResolver.command { _ in false },
            "open -b com.apple.Terminal ${cwd}"
        )
    }

    func testResolverRespectsCandidateOrderNotInstallOrder() {
        let command = DefaultTerminalResolver.command { $0 != "com.googlecode.iterm2" }
        XCTAssertEqual(command, "open -b com.mitchellh.ghostty ${cwd}")
    }

    // MARK: Migration

    func testAPreferencesBlobWithNoToolsKeyStillDecodes() throws {
        // The reason `storedTools` is Optional. `load()` decodes with `try?`, so a
        // non-optional field would fail every existing preferences.v1 blob and silently reset
        // the user's flags, overrides and shell settings.
        let legacy = #"{"globalFlags":{"values":{}},"projectFlags":{},"shell":{"environment":{},"clearChildSessionMarker":true}}"#
        let decoded = try JSONDecoder().decode(Preferences.self, from: Data(legacy.utf8))
        XCTAssertNil(decoded.storedTools)
    }

    func testMigrationMaterialisesEditorAndTerminal() {
        var prefs = Preferences()
        prefs.migrateToolsIfNeeded(terminalCommand: "open -b com.apple.Terminal ${cwd}")
        XCTAssertEqual(prefs.tools.map(\.name), ["Editor", "Terminal"])
        XCTAssertEqual(prefs.tools[0].command, "$EDITOR ${cwd}")
        XCTAssertEqual(prefs.tools[0].shortcut, ToolShortcut(key: "o", modifiers: [.command]))
        XCTAssertEqual(prefs.tools[1].command, "open -b com.apple.Terminal ${cwd}")
        XCTAssertEqual(prefs.tools[1].shortcut, ToolShortcut(key: "t", modifiers: [.command]))
    }

    func testMigrationIsIdempotentAndNeverOverwritesTheUsersList() {
        var prefs = Preferences()
        prefs.tools = [ToolDefinition(name: "Mine", symbol: "gear", command: "true")]
        prefs.migrateToolsIfNeeded(terminalCommand: "open -b com.apple.Terminal ${cwd}")
        XCTAssertEqual(prefs.tools.map(\.name), ["Mine"])
    }

    func testDeletingEveryToolStaysDeletedAcrossASaveAndLoad() {
        // The property a bare `?? defaults` getter would break: an empty list must persist as
        // empty, not resurrect Editor and Terminal on the next launch.
        let persistence = MemoryPersistence()
        let store = PreferencesStore(persistence: persistence)
        store.tools = []
        XCTAssertEqual(persistence.stored?.storedTools, [])

        let reopened = PreferencesStore(persistence: persistence)
        XCTAssertTrue(reopened.tools.isEmpty, "an emptied tool list must stay empty")
    }

    func testAFreshStoreMaterialisesTheDefaults() {
        let store = PreferencesStore(persistence: MemoryPersistence())
        XCTAssertEqual(store.tools.map(\.name), ["Editor", "Terminal"])
    }

    func testToolsRoundTripThroughStorage() {
        let persistence = MemoryPersistence()
        let store = PreferencesStore(persistence: persistence)
        store.tools = [
            ToolDefinition(
                name: "Tower", symbol: "arrow.triangle.branch", command: "open -a Tower ${project}",
                shortcut: ToolShortcut(key: "g", modifiers: [.command, .shift]),
                showsInOverlay: false
            )
        ]
        let reopened = PreferencesStore(persistence: persistence)
        XCTAssertEqual(reopened.tools.count, 1)
        XCTAssertEqual(reopened.tools[0].name, "Tower")
        XCTAssertEqual(reopened.tools[0].shortcut?.displayString, "⇧⌘G")
        XCTAssertFalse(reopened.tools[0].showsInOverlay)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `cannot find 'DefaultTerminalResolver' in scope`.

- [ ] **Step 3: Write `DefaultTerminalResolver`**

Create `Sources/FlightDeck/Tools/DefaultTerminalResolver.swift`:

```swift
import AppKit

/// Picks a terminal emulator for the default Terminal tool.
///
/// macOS exposes no "default terminal" setting to read, so this probes for installed apps in
/// preference order. The result is baked into a **literal, editable command string** at
/// materialisation rather than resolved at launch: the user sees
/// `open -b com.googlecode.iterm2 ${cwd}` in the preferences pane and can change it, instead of
/// a tool whose behaviour depends on a probe they cannot see.
enum DefaultTerminalResolver {
    /// Preference order, not install order. Terminal.app is last because it is the one that
    /// cannot be absent — it is the floor, not a choice.
    static let candidates = [
        "com.googlecode.iterm2",
        "com.mitchellh.ghostty",
        "com.github.wez.wezterm",
        "net.kovidgoyal.kitty",
        "io.alacritty",
        "com.apple.Terminal",
    ]

    /// Injectable so the resolution order is assertable without installing six terminals.
    static func command(
        isInstalled: (String) -> Bool = { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) != nil }
    ) -> String {
        let bundleID = candidates.first(where: isInstalled) ?? "com.apple.Terminal"
        return "open -b \(bundleID) ${cwd}"
    }
}
```

- [ ] **Step 4: Extend `Preferences`**

In `Sources/FlightDeck/Preferences/Preferences.swift`, add the property to `Preferences` (after `storedAgents`):

```swift
    /// Ordered; position is the overlay's left-to-right order.
    ///
    /// Optional in storage for exactly the reason `confirmations` is — see that property's
    /// comment. `nil` means "never materialised", which `migrateToolsIfNeeded` fills in.
    /// An *empty* array is a different thing entirely: it means the user deleted every tool,
    /// and it must stay empty.
    var storedTools: [ToolDefinition]?
```

Add `storedTools: [ToolDefinition]? = nil` as the last parameter of `init`, and `self.storedTools = storedTools` as the last assignment.

Then add, after the existing `agents` accessor and `defaultAgents`:

```swift
    /// Reads through the optional so a `Preferences` that predates materialisation still has
    /// tools. Writes go straight to `storedTools`, which is what lets an emptied list persist
    /// as empty rather than falling back to the defaults on the next read.
    var tools: [ToolDefinition] {
        get { storedTools ?? Self.defaultTools(terminalCommand: Self.fallbackTerminalCommand) }
        set { storedTools = newValue }
    }

    /// Used only by the getter above, for a blob that somehow reaches a reader before
    /// `migrateToolsIfNeeded` has run. Deliberately does not probe: a getter is not a place to
    /// touch `NSWorkspace`.
    static let fallbackTerminalCommand = "open -b com.apple.Terminal ${cwd}"

    static func defaultTools(terminalCommand: String) -> [ToolDefinition] {
        [
            ToolDefinition(
                name: "Editor",
                symbol: "chevron.left.forwardslash.chevron.right",
                // `$EDITOR` is left for the login shell to resolve — see `ToolTemplate.expand`
                // and `ShellToolLauncher`. Flight Deck's own process has no `$EDITOR` at all
                // when it is launched from Finder.
                command: "$EDITOR ${cwd}",
                shortcut: ToolShortcut(key: "o", modifiers: [.command])
            ),
            ToolDefinition(
                name: "Terminal",
                symbol: "terminal",
                command: terminalCommand,
                shortcut: ToolShortcut(key: "t", modifiers: [.command])
            ),
        ]
    }

    /// Fills in the starting tools once. Idempotent — safe on every load — so it never
    /// overwrites a list the user has edited, reordered, or emptied.
    mutating func migrateToolsIfNeeded(terminalCommand: String) {
        guard storedTools == nil else { return }
        storedTools = Self.defaultTools(terminalCommand: terminalCommand)
    }
```

- [ ] **Step 5: Wire the migration into `PreferencesStore`**

In `Sources/FlightDeck/Preferences/PreferencesStore.swift`, in `init(persistence:)`, add the tools migration next to the agents one:

```swift
        var loaded = persistence?.load() ?? Preferences()
        loaded.migrateAgentsIfNeeded()
        // Probes for an installed terminal, so it is done here rather than in the `tools`
        // getter: a computed property is not a place to touch `NSWorkspace`. The probe is
        // idempotent and only runs while `storedTools` is nil, so at worst it repeats once per
        // launch until the user's first edit persists the list.
        loaded.migrateToolsIfNeeded(terminalCommand: DefaultTerminalResolver.command())
        self.preferences = loaded
```

Add a `// MARK: Tools` section at the end of the class:

```swift
    /// The configured tools, in overlay order. The single accessor the menu, the overlay and
    /// the preferences pane all read and write through.
    var tools: [ToolDefinition] {
        get { preferences.tools }
        set { preferences.tools = newValue }
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS, all 9 `ToolPreferencesTests` cases, plus the pre-existing `PreferencesStoreTests` and `AgentPersistenceTests` unchanged.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/Tools/DefaultTerminalResolver.swift Sources/FlightDeck/Preferences/Preferences.swift Sources/FlightDeck/Preferences/PreferencesStore.swift Tests/FlightDeckTests/ToolPreferencesTests.swift
git commit -m "$(cat <<'EOF'
store the configured tools, and pick a terminal for the default one

storedTools is Optional for the reason the other optional Preferences
fields are: load() decodes with try?, and synthesized Codable throws on a
missing key rather than defaulting, so a non-optional field would fail
every existing preferences.v1 blob and silently reset the user's flags,
overrides and shell settings.

nil and [] mean different things here, and the distinction is the feature.
nil is "never materialised" and migrateToolsIfNeeded fills it in; [] is
"the user deleted every tool" and must stay empty. Writing through the
setter unconditionally is what keeps an emptied list from resurrecting the
defaults on the next read.

macOS exposes no default-terminal setting, so DefaultTerminalResolver
probes installed bundle ids in preference order and bakes the winner into a
literal, editable command. The user sees `open -b com.googlecode.iterm2
${cwd}` and can change it, rather than a tool whose behaviour depends on a
probe they cannot see. It runs from the store's init, not the tools getter,
because a computed property is not a place to touch NSWorkspace.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: `SessionStore.toolContext()`

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (add `toolContext()` near the other selection-derived accessors)
- Test: `Tests/FlightDeckTests/ToolContextTests.swift`

**Interfaces:**
- Consumes: `AgentLocation` (Task 1), `ToolContext` (Task 2), existing `SessionStore.adapter(for:)`, `overrideAdapter(_:for:)`, private `locate(_:)`, `repos`, `selectedSessionID`.
- Produces: `SessionStore.toolContext() -> ToolContext?`. Tasks 7, 9, 10 consume it.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/ToolContextTests.swift`:

```swift
import XCTest
@testable import FlightDeck

/// That a tool's view of a session is assembled from the ADAPTER, not from `Session` fields.
/// These tests assert the routing, not the values — the values are `ClaudeAdapterTests`' job.
@MainActor
final class ToolContextTests: XCTestCase {
    private var projectsRoot: URL!

    override func setUpWithError() throws {
        // Same isolation `AgentRoutingTests` uses: creating a session derives a transcript
        // path and starts a watcher, and pointed at the real root these tests would poll the
        // developer's own transcripts.
        projectsRoot = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectsRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: projectsRoot)
    }

    private func makeStore() -> SessionStore {
        let store = SessionStore(provider: nil, persistence: nil)
        store.projectsRoot = projectsRoot
        return store
    }

    func testThereIsNoContextWithoutASelection() {
        let store = makeStore()
        store.selectedSessionID = nil
        XCTAssertNil(store.toolContext(), "no selection means no cwd, so no tool may run")
    }

    func testTheWorkingDirectoryComesFromTheAdapterNotFromTheSession() {
        // The point of the whole boundary: swap the adapter and the context follows. If this
        // ever passes with a field read, the seam is decorative.
        let store = makeStore()
        store.newSession(in: URL(fileURLWithPath: "/tmp/repo", isDirectory: true))
        store.overrideAdapter(RelocatingAdapter(), for: .claude)
        XCTAssertEqual(store.toolContext()?.workingDirectory, "/elsewhere")
    }

    func testIdentityAndTranscriptComeFromTheAdaptersBinding() {
        let store = makeStore()
        store.newSession(in: URL(fileURLWithPath: "/tmp/repo", isDirectory: true))
        store.overrideAdapter(RelocatingAdapter(), for: .claude)
        let context = store.toolContext()
        XCTAssertEqual(context?.conversationID, RelocatingAdapter.pinned)
        XCTAssertEqual(context?.transcriptPath, "/t/fixed.jsonl")
    }

    func testProjectFactsComeFromTheRepoNotFromTheAgent() {
        let store = makeStore()
        store.newSession(in: URL(fileURLWithPath: "/tmp/repo", isDirectory: true))
        store.overrideAdapter(RelocatingAdapter(), for: .claude)
        let context = store.toolContext()
        XCTAssertEqual(context?.projectPath, "/tmp/repo")
        XCTAssertEqual(context?.projectName, "repo")
        XCTAssertEqual(context?.agent, .claude)
    }

    /// Reports a location nothing on `Session` could produce, so a passing assertion can only
    /// mean the store asked the adapter.
    private struct RelocatingAdapter: AgentAdapter {
        static let id: AgentID = .claude
        static let pinned = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!

        func prepare(for session: Session, options: AgentOptions) async throws -> AgentBinding {
            binding(for: session)
        }
        func binding(for session: Session) -> AgentBinding {
            AgentBinding(
                conversationID: Self.pinned,
                transcriptURL: URL(fileURLWithPath: "/t/fixed.jsonl")
            )
        }
        func location(for session: Session) -> AgentLocation {
            AgentLocation(workingDirectory: "/elsewhere", binding: binding(for: session))
        }
        func launchCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "" }
        func resumeCommand(_: AgentBinding, _: Session, _: AgentOptions) -> String { "" }
        func rename(_: AgentBinding, to: String) async throws {}
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `value of type 'SessionStore' has no member 'toolContext'`.

- [ ] **Step 3: Add `toolContext()` to `SessionStore`**

In `Sources/FlightDeck/SessionStore.swift`, add near the other selection-derived accessors (anywhere in the main class body; put it directly above the private `session(for:)` helper so it reads next to the lookup it uses):

```swift
    /// What a tool's command template is expanded against, for the current selection.
    ///
    /// Assembled here rather than in the tools subsystem because this type owns both halves:
    /// `adapter(for:)` resolves the agent, and `repos` knows which project the tab is filed
    /// under. Tools code never holds an adapter.
    ///
    /// Everything agent-shaped goes through `AgentAdapter.location(for:)` — never through
    /// `Session.transcriptDirectory` or `ClaudeSession` — so that claude deriving its
    /// transcript path from the cwd does not become a rule every future agent inherits. See
    /// `ClaudeAdapter`'s doc comment, which keeps `encodedProjectDirName` off the protocol for
    /// the same reason.
    ///
    /// nil when nothing is selected: there is no working directory then, and a tool expanded
    /// against blanks would run somewhere arbitrary. Callers disable themselves instead.
    func toolContext() -> ToolContext? {
        guard let id = selectedSessionID, let at = locate(id) else { return nil }
        let repo = repos[at.repo]
        let session = repo.sessions[at.session]
        let location = adapter(for: session.agent).location(for: session)
        return ToolContext(
            workingDirectory: location.workingDirectory,
            projectPath: repo.url.path,
            projectName: repo.displayName,
            sessionTitle: session.title,
            agent: session.agent,
            conversationID: location.binding.conversationID,
            transcriptPath: location.binding.transcriptURL?.path
        )
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS, all 4 `ToolContextTests` cases.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/ToolContextTests.swift
git commit -m "$(cat <<'EOF'
assemble a tool's session context through the adapter

The store owns both halves this needs — adapter(for:) resolves the agent,
repos knows which project a tab is filed under — so the context is built
here and tools code never holds an adapter.

Everything agent-shaped routes through AgentAdapter.location(for:) rather
than through Session.transcriptDirectory or ClaudeSession, so that claude
deriving its transcript path from the cwd does not become a rule every
future agent inherits. The tests assert that routing rather than the
values: they override the adapter and check the context follows, which
fails if this is ever quietly rewritten as a field read.

nil with no selection, because a tool expanded against blanks would run in
an arbitrary directory. Callers disable themselves instead.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: Launching, and reporting a launch that fails

**Files:**
- Create: `Sources/FlightDeck/Tools/ToolLauncher.swift`
- Create: `Sources/FlightDeck/Tools/ToolLaunchFailureReporter.swift`
- Test: `Tests/FlightDeckTests/ToolLauncherTests.swift`

**Interfaces:**
- Consumes: existing `ShellResolver.resolve()`.
- Produces: `protocol ToolLaunching { func launch(command: String, in directory: String, named: String) }`, `struct ShellToolLauncher: ToolLaunching` with settable `shell`, `environment`, `reporter`, `grace`; `protocol ToolLaunchFailureReporting { func report(tool: String, message: String) }`, `struct NSAlertToolLaunchFailureReporter`. Tasks 7, 9 consume `ToolLaunching`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/ToolLauncherTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class ToolLauncherTests: XCTestCase {
    private final class RecordingReporter: ToolLaunchFailureReporting {
        var reports: [(tool: String, message: String)] = []
        var onReport: (() -> Void)?
        func report(tool: String, message: String) {
            reports.append((tool, message))
            onReport?()
        }
    }

    private func makeLauncher(_ reporter: RecordingReporter) -> ShellToolLauncher {
        var launcher = ShellToolLauncher()
        launcher.shell = { "/bin/sh" }
        launcher.environment = { ["PATH": "/usr/bin:/bin"] }
        launcher.reporter = reporter
        launcher.grace = .milliseconds(1500)
        return launcher
    }

    func testANonZeroExitIsReportedWithItsStderr() {
        // The failure this exists for: $EDITOR unset means the shell runs a bare path, gets
        // "permission denied", and — with stderr discarded — ⌘O does nothing at all.
        let reporter = RecordingReporter()
        let expectation = expectation(description: "reported")
        reporter.onReport = { expectation.fulfill() }

        makeLauncher(reporter).launch(
            command: "echo 'no such editor' >&2; exit 3", in: "/tmp", named: "Editor"
        )

        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(reporter.reports.first?.tool, "Editor")
        XCTAssertTrue(
            reporter.reports.first?.message.contains("no such editor") ?? false,
            "the report must carry what the shell actually said"
        )
    }

    func testACleanExitIsNotReported() {
        let reporter = RecordingReporter()
        makeLauncher(reporter).launch(command: "exit 0", in: "/tmp", named: "Terminal")

        // Outlive the grace window before asserting silence.
        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertTrue(reporter.reports.isEmpty)
    }

    func testAToolStillRunningAfterTheGraceWindowIsNotReported() {
        // A GUI editor stays alive. Waiting for it would mean never reporting anything, and
        // treating "still running" as failure would mean reporting everything.
        let reporter = RecordingReporter()
        makeLauncher(reporter).launch(command: "sleep 30", in: "/tmp", named: "Editor")

        let settled = expectation(description: "settled")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { settled.fulfill() }
        wait(for: [settled], timeout: 5)
        XCTAssertTrue(reporter.reports.isEmpty)
    }

    func testAnUnlaunchableShellIsReportedImmediately() {
        let reporter = RecordingReporter()
        var launcher = makeLauncher(reporter)
        launcher.shell = { "/nonexistent/shell" }
        let expectation = expectation(description: "reported")
        reporter.onReport = { expectation.fulfill() }

        launcher.launch(command: "true", in: "/tmp", named: "Editor")

        wait(for: [expectation], timeout: 5)
        XCTAssertEqual(reporter.reports.first?.tool, "Editor")
    }

    func testTheCommandRunsInTheGivenDirectory() {
        let reporter = RecordingReporter()
        let expectation = expectation(description: "reported")
        reporter.onReport = { expectation.fulfill() }

        // `pwd` to stderr, then fail, so the assertion can read it back through the reporter.
        makeLauncher(reporter).launch(command: "pwd >&2; exit 1", in: "/tmp", named: "Probe")

        wait(for: [expectation], timeout: 5)
        XCTAssertTrue(
            reporter.reports.first?.message.contains("tmp") ?? false,
            "currentDirectoryURL is what makes relative paths in a template resolve"
        )
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `cannot find 'ToolLaunchFailureReporting' in scope`.

- [ ] **Step 3: Write the failure reporter**

Create `Sources/FlightDeck/Tools/ToolLaunchFailureReporter.swift`:

```swift
import AppKit

/// Seam over "tell the user this tool did not start", the same shape and for the same reason
/// as `AgentLaunchFailureReporting`: the launcher can then be tested without a panel on screen.
@MainActor
protocol ToolLaunchFailureReporting {
    func report(tool: String, message: String)
}

/// The real thing.
///
/// A tool that fails leaves nothing behind — no window, no tab, no output — so there is no
/// surface on which the failure could otherwise be noticed. The likeliest case by far is
/// `$EDITOR` unset: the login shell then runs a bare path, gets "permission denied", and
/// without this the user presses ⌘O and nothing whatsoever happens.
@MainActor
struct NSAlertToolLaunchFailureReporter: ToolLaunchFailureReporting {
    /// Injectable so the no-window case is reachable without one, matching
    /// `NSAlertAgentLaunchFailureReporter`.
    var window: () -> NSWindow? = { NSApp.keyWindow ?? NSApp.mainWindow }

    func report(tool: String, message: String) {
        guard let window = window() else {
            NSLog("Flight Deck could not run %@: %@", tool, message)
            return
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Could not run \(tool)."
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        // A sheet rather than `runModal()`, for the reason `NSAlertAgentLaunchFailureReporter`
        // gives: nothing about a failed tool needs to stop the rest of the app.
        alert.beginSheetModal(for: window)
    }
}
```

- [ ] **Step 4: Write the launcher**

Create `Sources/FlightDeck/Tools/ToolLauncher.swift`:

```swift
import Foundation

@MainActor
protocol ToolLaunching {
    func launch(command: String, in directory: String, named: String)
}

/// Runs an expanded tool command through the user's login shell, detached.
///
/// **Why the login shell.** Flight Deck launched from Finder has a minimal environment: no
/// `$EDITOR`, and a `PATH` without `/opt/homebrew/bin`. `$SHELL -lc` sources the profile, so a
/// template behaves exactly as it would typed into a terminal — which also means shell syntax
/// in a template (pipes, `&&`, quoting) works as written.
@MainActor
struct ShellToolLauncher: ToolLaunching {
    /// Honours the Shell & Environment pane's override, like session creation does.
    var shell: () -> String = { ShellResolver.resolve() }
    var environment: () -> [String: String] = { ProcessInfo.processInfo.environment }
    var reporter: ToolLaunchFailureReporting = NSAlertToolLaunchFailureReporter()
    /// How long a child has to fail before it is assumed to have started fine. Long enough for
    /// a bad command to die, short enough that a real failure is reported while the user still
    /// remembers pressing the key.
    var grace: Duration = .seconds(2)

    func launch(command: String, in directory: String, named name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: shell())
        process.arguments = ["-lc", command]
        // Relative paths in a template resolve where the user expects, and a tool that reads
        // its cwd rather than argv still lands in the right place.
        process.currentDirectoryURL = URL(fileURLWithPath: directory, isDirectory: true)
        process.environment = environment()

        let errors = Pipe()
        process.standardError = errors
        // Null rather than inherited: a detached tool must not hold Flight Deck's descriptors,
        // and nothing reads its stdout.
        process.standardOutput = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            reporter.report(tool: name, message: error.localizedDescription)
            return
        }

        Task { @MainActor in
            let deadline = ContinuousClock.now.advanced(by: grace)
            while process.isRunning, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(50))
            }

            guard !process.isRunning else {
                // A GUI editor stays alive, and that is success. Stop holding the read end
                // first: a chatty long-running child would otherwise fill the pipe's buffer
                // and block forever on its next write to stderr.
                errors.fileHandleForReading.readabilityHandler = { _ = $0.availableData }
                return
            }

            guard process.terminationStatus != 0 else { return }

            let data = errors.fileHandleForReading.readDataToEndOfFile()
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let message = text.split(separator: "\n").last.map(String.init)
                ?? "exited with status \(process.terminationStatus)"
            reporter.report(tool: name, message: message)
        }
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS, all 5 `ToolLauncherTests` cases. They take ~8s total because three of them deliberately outlive the grace window.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/Tools/ToolLauncher.swift Sources/FlightDeck/Tools/ToolLaunchFailureReporter.swift Tests/FlightDeckTests/ToolLauncherTests.swift
git commit -m "$(cat <<'EOF'
run a tool through the login shell, and say so when it fails

$SHELL -lc, because Flight Deck launched from Finder has no $EDITOR and a
PATH without /opt/homebrew/bin. Sourcing the profile is what makes a
template behave as it would typed into a terminal, and it means shell
syntax in a template works as written.

stderr goes to a pipe rather than /dev/null. The likeliest first-run
failure is $EDITOR unset: the shell runs a bare path, gets permission
denied, and with stderr discarded the user presses ⌘O and nothing
whatsoever happens — on a feature whose whole contract is that something
does. A non-zero exit inside a 2s grace window is reported through a seam
shaped like AgentLaunchFailureReporting.

A child still alive past the grace window is success, not pending: a GUI
editor stays running. Its read end gets a draining handler at that point,
because a chatty long-running child would otherwise fill the pipe buffer
and block on its next write to stderr.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: The Tools menu

**Files:**
- Create: `Sources/FlightDeck/Tools/ToolsMenuController.swift`
- Test: `Tests/FlightDeckTests/ToolsMenuControllerTests.swift`

**Interfaces:**
- Consumes: `ToolDefinition`, `ToolShortcut` (Task 3).
- Produces: `@MainActor final class ToolsMenuController: NSObject` with `private(set) var menu: NSMenu`, `var tools: [ToolDefinition]`, `var isEnabled: () -> Bool`, `var run: (ToolDefinition) -> Void`, `var openPreferences: () -> Void`, and `func install(in mainMenu: NSMenu)`. Task 9 installs it from `AppDelegate`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/ToolsMenuControllerTests.swift`:

```swift
import AppKit
import XCTest
@testable import FlightDeck

@MainActor
final class ToolsMenuControllerTests: XCTestCase {
    private func tool(_ name: String, _ key: String?) -> ToolDefinition {
        ToolDefinition(
            name: name, symbol: "gear", command: "true",
            shortcut: key.map { ToolShortcut(key: $0, modifiers: [.command]) }
        )
    }

    func testItemsCarryTheirNamesAndKeyEquivalents() {
        let controller = ToolsMenuController()
        controller.tools = [tool("Editor", "o"), tool("Terminal", "t")]
        let items = controller.menu.items
        XCTAssertEqual(items[0].title, "Editor")
        XCTAssertEqual(items[0].keyEquivalent, "o")
        XCTAssertEqual(items[0].keyEquivalentModifierMask, [.command])
        XCTAssertEqual(items[1].title, "Terminal")
        XCTAssertEqual(items[1].keyEquivalent, "t")
    }

    func testAToolWithNoShortcutStillGetsAnItem() {
        let controller = ToolsMenuController()
        controller.tools = [tool("Tower", nil)]
        XCTAssertEqual(controller.menu.items.first?.title, "Tower")
        XCTAssertEqual(controller.menu.items.first?.keyEquivalent, "")
    }

    func testTheMenuAlwaysEndsWithASeparatorAndConfigure() {
        let controller = ToolsMenuController()
        controller.tools = [tool("Editor", "o")]
        let items = controller.menu.items
        XCTAssertTrue(items[items.count - 2].isSeparatorItem)
        XCTAssertEqual(items.last?.title, "Configure Tools…")
    }

    func testAnEmptyToolListStillOffersConfigure() {
        // Deleting every tool must not leave a dead menu with no way back to the pane.
        let controller = ToolsMenuController()
        controller.tools = []
        XCTAssertEqual(controller.menu.items.last?.title, "Configure Tools…")
    }

    func testChangingTheToolsRebuildsTheMenu() {
        let controller = ToolsMenuController()
        controller.tools = [tool("Editor", "o")]
        controller.tools = [tool("Tower", "g"), tool("Editor", "o")]
        XCTAssertEqual(controller.menu.items.prefix(2).map(\.title), ["Tower", "Editor"])
    }

    func testItemsAreDisabledWithoutASelectedSession() {
        // No selection means no working directory, so the chord must be inert rather than
        // launching a tool somewhere arbitrary. A disabled NSMenuItem does not fire its key
        // equivalent, which is exactly what is wanted here.
        let controller = ToolsMenuController()
        controller.isEnabled = { false }
        controller.tools = [tool("Editor", "o")]
        XCTAssertFalse(controller.validateMenuItem(controller.menu.items[0]))
    }

    func testConfigureStaysEnabledWithoutASelectedSession() {
        let controller = ToolsMenuController()
        controller.isEnabled = { false }
        controller.tools = [tool("Editor", "o")]
        XCTAssertTrue(controller.validateMenuItem(controller.menu.items.last!))
    }

    func testActivatingAnItemRunsThatTool() {
        let controller = ToolsMenuController()
        var ran: [String] = []
        controller.run = { ran.append($0.name) }
        controller.tools = [tool("Editor", "o"), tool("Terminal", "t")]
        let item = controller.menu.items[1]
        _ = item.target?.perform(item.action, with: item)
        XCTAssertEqual(ran, ["Terminal"])
    }

    func testInstallingTwiceLeavesOneToolsMenu() {
        // `install` runs whenever the main menu is rebuilt, so it has to be idempotent.
        let main = NSMenu()
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = NSMenu(title: "View")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = NSMenu(title: "Window")
        let controller = ToolsMenuController()
        controller.install(in: main)
        controller.install(in: main)
        XCTAssertEqual(main.items.filter { $0.submenu?.title == "Tools" }.count, 1)
    }

    func testTheMenuLandsAfterViewWhenViewExists() {
        let main = NSMenu()
        main.addItem(withTitle: "View", action: nil, keyEquivalent: "").submenu = NSMenu(title: "View")
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = NSMenu(title: "Window")
        ToolsMenuController().install(in: main)
        XCTAssertEqual(main.items.map { $0.submenu?.title }, ["View", "Tools", "Window"])
    }

    func testTheMenuLandsBeforeWindowWhenViewIsAbsent() {
        // SwiftUI builds the main menu asynchronously, so installing before View exists is a
        // real ordering, not a hypothetical one.
        let main = NSMenu()
        main.addItem(withTitle: "Window", action: nil, keyEquivalent: "").submenu = NSMenu(title: "Window")
        ToolsMenuController().install(in: main)
        XCTAssertEqual(main.items.map { $0.submenu?.title }, ["Tools", "Window"])
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `cannot find 'ToolsMenuController' in scope`.

- [ ] **Step 3: Write the controller**

Create `Sources/FlightDeck/Tools/ToolsMenuController.swift`:

```swift
import AppKit

/// Builds and maintains the Tools menu.
///
/// **Why AppKit rather than a SwiftUI `Commands` group.** `SessionCommands` documents that
/// SwiftUI cannot vary a `.keyboardShortcut` at runtime, and works around it by giving each
/// agent position a statically chorded item. A user-recorded chord is dynamic by definition, so
/// that workaround does not extend here. `NSMenuItem.keyEquivalent` is a plain property.
///
/// **Why a menu at all, rather than a bare key monitor.** Three things come free: the chord
/// renders beside the tool's name, so the feature is discoverable; `MenuKeyEquivalents` routes
/// Ghostty's swallowed ⌘-combinations here with no change, because it walks the whole main menu
/// and names no specific shortcut; and validation gives the disabled state.
@MainActor
final class ToolsMenuController: NSObject, NSMenuItemValidation {
    private(set) var menu = NSMenu(title: "Tools")

    var tools: [ToolDefinition] = [] { didSet { rebuild() } }
    /// Whether a session is selected. A tool with no working directory must not run.
    var isEnabled: () -> Bool = { false }
    var run: (ToolDefinition) -> Void = { _ in }
    var openPreferences: () -> Void = {}

    override init() {
        super.init()
        // `autoenablesItems` off so `validateMenuItem` is the single authority. Left on,
        // AppKit would also disable items whose action nothing in the responder chain
        // implements, which is every item here — they are targeted directly at this object.
        menu.autoenablesItems = false
        rebuild()
    }

    /// Inserts the menu, replacing any copy already there.
    ///
    /// Idempotent because SwiftUI owns `NSApp.mainMenu` and may rebuild it, so this can run
    /// more than once. Placement is by title lookup rather than a fixed index for the same
    /// reason: the menu is populated asynchronously, so View may not exist yet.
    func install(in mainMenu: NSMenu) {
        for item in mainMenu.items where item.submenu?.title == "Tools" {
            mainMenu.removeItem(item)
        }
        let host = NSMenuItem()
        host.submenu = menu

        let afterView = mainMenu.items.firstIndex { $0.submenu?.title == "View" }.map { $0 + 1 }
        let beforeWindow = mainMenu.items.firstIndex { $0.submenu?.title == "Window" }
        mainMenu.insertItem(host, at: afterView ?? beforeWindow ?? mainMenu.items.count)
    }

    private func rebuild() {
        menu.removeAllItems()

        for tool in tools {
            let item = NSMenuItem(
                title: tool.name,
                action: #selector(runTool(_:)),
                keyEquivalent: tool.shortcut?.key ?? ""
            )
            item.keyEquivalentModifierMask = tool.shortcut?.modifierFlags ?? []
            item.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)
            item.representedObject = tool
            item.target = self
            menu.addItem(item)
        }

        // Always present, even with no tools: deleting every tool must not leave a dead menu
        // with no route back to the pane that would restore one.
        menu.addItem(.separator())
        let configure = NSMenuItem(
            title: "Configure Tools…", action: #selector(configure(_:)), keyEquivalent: ""
        )
        configure.target = self
        menu.addItem(configure)
    }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard item.action == #selector(runTool(_:)) else { return true }
        return isEnabled()
    }

    @objc private func runTool(_ sender: NSMenuItem) {
        guard let tool = sender.representedObject as? ToolDefinition else { return }
        run(tool)
    }

    @objc private func configure(_ sender: NSMenuItem) {
        openPreferences()
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS, all 11 `ToolsMenuControllerTests` cases.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Tools/ToolsMenuController.swift Tests/FlightDeckTests/ToolsMenuControllerTests.swift
git commit -m "$(cat <<'EOF'
build the Tools menu in AppKit so its chords can change

SessionCommands already documents that SwiftUI cannot vary a
.keyboardShortcut at runtime, and works around it with statically chorded
items per agent position. A user-recorded chord is dynamic by definition,
so that workaround does not extend here. NSMenuItem.keyEquivalent is a
plain property.

A menu rather than a bare key monitor buys three things: the chord renders
beside the tool's name, so the feature is discoverable; MenuKeyEquivalents
routes Ghostty's swallowed ⌘-combinations here with no change, since it
walks the whole main menu and names no specific shortcut; and validation
gives the disabled state, where a disabled item not firing its key
equivalent is exactly what is wanted — no selection means no working
directory, so the chord must be inert.

autoenablesItems is off so validateMenuItem is the only authority; left on,
AppKit would disable every item, since they are targeted at this object
rather than reachable through the responder chain. install() is idempotent
and places by title lookup because SwiftUI owns the main menu and builds it
asynchronously, so View may not exist yet.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 8: The overlay's visibility state machine

**Files:**
- Create: `Sources/FlightDeck/Tools/ToolOverlayVisibility.swift`
- Test: `Tests/FlightDeckTests/ToolOverlayVisibilityTests.swift`

**Interfaces:**
- Produces: `struct ToolOverlayVisibility` with `static let idleTimeout: Duration`, `mutating func mouseMoved(at: ContinuousClock.Instant)`, `mutating func keyPressed()`, `mutating func hoverChanged(_ inside: Bool)`, `func isVisible(at: ContinuousClock.Instant) -> Bool`, `func idleDeadline() -> ContinuousClock.Instant?`. Task 9 consumes it.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/ToolOverlayVisibilityTests.swift`:

```swift
import XCTest
@testable import FlightDeck

/// No clock inside the type, so every transition is assertable without waiting five seconds
/// or standing up a window.
@MainActor
final class ToolOverlayVisibilityTests: XCTestCase {
    private let t0 = ContinuousClock.now

    private func at(_ seconds: Double) -> ContinuousClock.Instant {
        t0.advanced(by: .milliseconds(Int(seconds * 1000)))
    }

    func testHiddenBeforeAnythingHappens() {
        XCTAssertFalse(ToolOverlayVisibility().isVisible(at: t0))
    }

    func testMouseMovementShowsIt() {
        var v = ToolOverlayVisibility()
        v.mouseMoved(at: t0)
        XCTAssertTrue(v.isVisible(at: t0))
    }

    func testItStaysVisibleJustInsideTheIdleTimeout() {
        var v = ToolOverlayVisibility()
        v.mouseMoved(at: t0)
        XCTAssertTrue(v.isVisible(at: at(4.9)))
    }

    func testItFadesAfterFiveIdleSeconds() {
        var v = ToolOverlayVisibility()
        v.mouseMoved(at: t0)
        XCTAssertFalse(v.isVisible(at: at(5.1)))
    }

    func testTypingHidesItImmediately() {
        var v = ToolOverlayVisibility()
        v.mouseMoved(at: t0)
        v.keyPressed()
        XCTAssertFalse(v.isVisible(at: at(0.1)))
    }

    func testTypingKeepsItHiddenUntilTheMouseMovesAgain() {
        // Not merely "hidden now": without the suppression flag, the stamp from the earlier
        // move would bring the buttons back on the next redraw while the user is still typing.
        var v = ToolOverlayVisibility()
        v.mouseMoved(at: t0)
        v.keyPressed()
        XCTAssertFalse(v.isVisible(at: at(1.0)))
        v.mouseMoved(at: at(2.0))
        XCTAssertTrue(v.isVisible(at: at(2.0)))
    }

    func testHoveringPinsItPastTheIdleTimeout() {
        // Without this you cannot aim at a button: the cluster would fade while the pointer
        // travelled to it.
        var v = ToolOverlayVisibility()
        v.mouseMoved(at: t0)
        v.hoverChanged(true)
        XCTAssertTrue(v.isVisible(at: at(60)))
    }

    func testLeavingTheClusterUnpinsIt() {
        var v = ToolOverlayVisibility()
        v.mouseMoved(at: t0)
        v.hoverChanged(true)
        v.hoverChanged(false)
        XCTAssertFalse(v.isVisible(at: at(60)))
    }

    func testTheDeadlineIsFiveSecondsAfterTheLastMove() {
        var v = ToolOverlayVisibility()
        v.mouseMoved(at: t0)
        XCTAssertEqual(v.idleDeadline(), t0.advanced(by: .seconds(5)))
    }

    func testThereIsNoDeadlineWhenNothingIsPending() {
        XCTAssertNil(ToolOverlayVisibility().idleDeadline())
        var typed = ToolOverlayVisibility()
        typed.mouseMoved(at: t0)
        typed.keyPressed()
        XCTAssertNil(typed.idleDeadline(), "a suppressed overlay has nothing left to time out")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `cannot find 'ToolOverlayVisibility' in scope`.

- [ ] **Step 3: Write the state machine**

Create `Sources/FlightDeck/Tools/ToolOverlayVisibility.swift`:

```swift
import Foundation

/// Whether the floating tool buttons are showing.
///
/// A value type with no clock, no timer and no view: the caller supplies "now". That is what
/// makes "fades after five idle seconds" a test that runs instantly rather than one that sleeps.
///
/// The rules: mouse movement over the terminal shows the buttons; the first keystroke hides
/// them and keeps them hidden until the mouse moves again; five seconds without movement hides
/// them on their own; hovering the cluster pins it so a button can be aimed at.
struct ToolOverlayVisibility: Equatable {
    static let idleTimeout: Duration = .seconds(5)

    private var lastMove: ContinuousClock.Instant?
    private var isHovering = false
    /// Separate from clearing `lastMove`, and the difference matters: without a flag, the
    /// stamp from the last mouse move would bring the buttons straight back on the next
    /// redraw while the user is still typing.
    private var suppressedByTyping = false

    mutating func mouseMoved(at now: ContinuousClock.Instant) {
        suppressedByTyping = false
        lastMove = now
    }

    mutating func keyPressed() {
        suppressedByTyping = true
    }

    mutating func hoverChanged(_ inside: Bool) {
        isHovering = inside
    }

    func isVisible(at now: ContinuousClock.Instant) -> Bool {
        // Hover wins outright. You cannot type while deliberately hovering the cluster, and
        // the alternative — letting a stray keystroke yank the buttons out from under a
        // pointer already on its way to one — is worse.
        if isHovering { return true }
        guard !suppressedByTyping, let lastMove else { return false }
        return now - lastMove < Self.idleTimeout
    }

    /// When the overlay would next change state on its own, so the caller can schedule exactly
    /// one wake instead of polling. nil means nothing is pending.
    func idleDeadline() -> ContinuousClock.Instant? {
        guard !isHovering, !suppressedByTyping, let lastMove else { return nil }
        return lastMove.advanced(by: Self.idleTimeout)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS, all 10 `ToolOverlayVisibilityTests` cases.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Tools/ToolOverlayVisibility.swift Tests/FlightDeckTests/ToolOverlayVisibilityTests.swift
git commit -m "$(cat <<'EOF'
decide overlay visibility without owning a clock

The caller supplies "now", so "fades after five idle seconds" is a test
that runs instantly instead of one that sleeps, and the whole rule set is
assertable with no window.

Typing sets a suppression flag rather than clearing the last-move stamp.
Clearing would look equivalent and is not: the next mouse-move event —
or any redraw reading a stale stamp — would bring the buttons back while
the user is still typing. Suppression is only lifted by real movement.

Hover wins outright over the idle timeout, because a cluster that fades
while the pointer is travelling to it is a cluster you cannot click.

idleDeadline() lets the caller schedule exactly one wake rather than
polling, which is why this does not join WatchClock — that clock exists to
collapse recurring polls, and this needs a timer that usually gets
cancelled before it fires.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 9: The overlay, its input monitor, and app wiring

The first task with a visible result. It has no unit tests of its own — the monitor needs a live window and the view is SwiftUI — so it leans on Task 8's state machine for logic and on a build for correctness. **Verification is a successful build and a green unit suite; do not launch the app.**

**Files:**
- Create: `Sources/FlightDeck/Tools/ToolOverlayModel.swift`
- Create: `Sources/FlightDeck/Tools/ToolOverlayInputMonitor.swift`
- Create: `Sources/FlightDeck/Tools/ToolOverlay.swift`
- Modify: `Sources/FlightDeck/RootView.swift` (stack the overlay with `SearchOverlay`)
- Modify: `Sources/FlightDeck/AppDelegate.swift` (install `ToolsMenuController`)

**Interfaces:**
- Consumes: `ToolOverlayVisibility` (Task 8), `ToolsMenuController` (Task 7), `ToolLaunching` / `ShellToolLauncher` (Task 6), `SessionStore.toolContext()` (Task 5), `PreferencesStore.tools` (Task 4), `ToolTemplate.expand` (Task 2).
- Produces: `ToolRunner.run(_:store:preferences:launcher:)`, `ToolOverlayModel`, `ToolOverlayInputMonitor`, `ToolOverlay`.

- [ ] **Step 1: Write the shared runner**

Both the menu and the overlay need the same "expand and launch" path, so it lives in one place. Create `Sources/FlightDeck/Tools/ToolRunner.swift`:

```swift
import Foundation

/// Expands a tool against the current selection and launches it. The single path both the
/// Tools menu and the floating overlay go through, so the two cannot drift.
@MainActor
enum ToolRunner {
    static func run(
        _ tool: ToolDefinition,
        store: SessionStore,
        launcher: ToolLaunching
    ) {
        // No selection means no working directory. The menu item and the overlay button are
        // both disabled in that state, so this is a backstop rather than the usual route.
        guard let context = store.toolContext() else { return }
        launcher.launch(
            command: ToolTemplate.expand(tool.command, in: context),
            in: context.workingDirectory,
            named: tool.name
        )
    }
}
```

- [ ] **Step 2: Write the observable wrapper**

Create `Sources/FlightDeck/Tools/ToolOverlayModel.swift`:

```swift
import Foundation
import SwiftUI

/// Publishes `ToolOverlayVisibility` to SwiftUI, and schedules the one wake it needs.
///
/// Deliberately not a `WatchClock` subscriber: that clock exists to collapse *recurring* polls
/// into a single wakeup, while this wants one timer that fires once and is usually cancelled
/// before it does.
@MainActor
final class ToolOverlayModel: ObservableObject {
    @Published private(set) var isVisible = false

    private var state = ToolOverlayVisibility()
    private var idleTask: Task<Void, Never>?

    func mouseMoved() {
        state.mouseMoved(at: .now)
        refresh()
    }

    func keyPressed() {
        state.keyPressed()
        refresh()
    }

    func hoverChanged(_ inside: Bool) {
        state.hoverChanged(inside)
        refresh()
    }

    private func refresh() {
        isVisible = state.isVisible(at: .now)

        idleTask?.cancel()
        guard let deadline = state.idleDeadline() else { return }
        idleTask = Task { @MainActor [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard !Task.isCancelled, let self else { return }
            self.isVisible = self.state.isVisible(at: .now)
        }
    }

    deinit { idleTask?.cancel() }
}
```

- [ ] **Step 3: Write the input monitor**

Create `Sources/FlightDeck/Tools/ToolOverlayInputMonitor.swift`:

```swift
import AppKit

/// Feeds mouse movement and keystrokes to `ToolOverlayModel`.
///
/// **Shaped after `SidebarInputMonitor`, including its scoping discipline.** One passive local
/// monitor that never consumes an event, so terminal input, hit-testing and list dragging
/// cannot change. `NSEvent.addLocalMonitorForEvents` sees every event in the process, so it
/// must prove what it is looking at before acting.
///
/// **Why mouse movement is available at all.** macOS only generates `mouseMoved` when
/// something asks for it. `Ghostty.SurfaceView.updateTrackingAreas` installs an
/// `NSTrackingArea` with `.mouseMoved`, so those events flow over the terminal. If a future
/// re-pull of the adapt-copied Ghostty drops that flag, fade-in stops working and nothing here
/// will say so — see the design doc's risk list.
///
/// **Why the qualification is a hit-test walk rather than a frame check.** It needs no geometry
/// plumbed out of SwiftUI, and it naturally excludes the sidebar: crossing it must not fade the
/// buttons in. Hovering the cluster itself hit-tests to the SwiftUI host rather than
/// `TerminalHostView`, which is why pinning goes through `.onHover` on the view instead.
@MainActor
final class ToolOverlayInputMonitor {
    private var mouseToken: Any?
    private var keyToken: Any?
    private weak var host: NSWindow?

    var onMouseMovedOverTerminal: (() -> Void)?
    var onKeyPressed: (() -> Void)?

    func start() {
        captureHostWindow()

        if mouseToken == nil {
            mouseToken = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                self?.handleMouseMoved(event)
                return event   // never consumed
            }
        }
        if keyToken == nil {
            keyToken = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, let window = event.window, window === self.host else { return event }
                self.onKeyPressed?()
                return event   // never consumed
            }
        }
    }

    func stop() {
        if let mouseToken { NSEvent.removeMonitor(mouseToken) }
        if let keyToken { NSEvent.removeMonitor(keyToken) }
        mouseToken = nil
        keyToken = nil
        host = nil
    }

    deinit {
        // Hop to the main actor rather than removing inline, matching `SidebarInputMonitor`:
        // `removeMonitor` is an AppKit call and belongs on the main thread.
        let (mouse, key) = (mouseToken, keyToken)
        if mouse != nil || key != nil {
            DispatchQueue.main.async {
                if let mouse { NSEvent.removeMonitor(mouse) }
                if let key { NSEvent.removeMonitor(key) }
            }
        }
    }

    /// SwiftUI's `onAppear` can run before the view is in a window, so this retries briefly.
    private func captureHostWindow(attempt: Int = 0) {
        guard host == nil else { return }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            host = window
            return
        }
        guard attempt < 40 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.captureHostWindow(attempt: attempt + 1)
        }
    }

    private func handleMouseMoved(_ event: NSEvent) {
        guard let window = event.window, window === host, let content = window.contentView else { return }
        // `NSView.hitTest(_:)` takes a point in the receiver's SUPERVIEW coordinates; for a
        // window's `contentView` that is already `locationInWindow`, so no conversion.
        guard let hit = content.hitTest(event.locationInWindow) else { return }
        guard Self.isOverTerminal(hit) else { return }
        onMouseMovedOverTerminal?()
    }

    /// Read-only walk: nothing is attached, replaced or reconfigured.
    private static func isOverTerminal(_ view: NSView) -> Bool {
        var candidate: NSView? = view
        while let current = candidate {
            if current is TerminalHostView { return true }
            candidate = current.superview
        }
        return false
    }
}
```

- [ ] **Step 4: Write the overlay view**

Create `Sources/FlightDeck/Tools/ToolOverlay.swift`:

```swift
import SwiftUI

/// Translucent tool buttons floating over the terminal's top-right corner.
///
/// Chrome matches `TerminalSearchBar` deliberately: the two stack in the same corner, and two
/// different treatments there would read as two unrelated pieces of UI.
struct ToolOverlay: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var model: ToolOverlayModel

    let monitor: ToolOverlayInputMonitor
    var launcher: ToolLaunching = ShellToolLauncher()

    private var visibleTools: [ToolDefinition] {
        preferences.tools.filter(\.showsInOverlay)
    }

    private var hasSelection: Bool { store.selectedSessionID != nil }

    var body: some View {
        Group {
            if visibleTools.isEmpty {
                EmptyView()
            } else {
                HStack(spacing: 6) {
                    ForEach(visibleTools) { tool in
                        Button {
                            ToolRunner.run(tool, store: store, launcher: launcher)
                        } label: {
                            Image(systemName: tool.symbol)
                                .frame(width: 22, height: 22)
                        }
                        .buttonStyle(.borderless)
                        .disabled(!hasSelection)
                        .help(helpText(for: tool))
                        .accessibilityIdentifier("tool-button-\(tool.name)")
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
                .shadow(radius: 4, y: 2)
                .padding(8)
                .opacity(model.isVisible ? 1 : 0)
                // Asymmetric on purpose: appearing has to feel immediate when you reach for
                // the corner, while vanishing should not snap away under the pointer.
                .animation(
                    model.isVisible ? .easeOut(duration: 0.15) : .easeIn(duration: 0.4),
                    value: model.isVisible
                )
                // Invisible buttons must not be clickable, or the corner would swallow clicks
                // meant for the terminal underneath.
                .allowsHitTesting(model.isVisible)
                .onHover { model.hoverChanged($0) }
            }
        }
        .onAppear {
            monitor.onMouseMovedOverTerminal = { model.mouseMoved() }
            monitor.onKeyPressed = { model.keyPressed() }
            monitor.start()
        }
        .onDisappear { monitor.stop() }
    }

    private func helpText(for tool: ToolDefinition) -> String {
        guard let shortcut = tool.shortcut else { return tool.name }
        return "\(tool.name) \(shortcut.displayString)"
    }
}
```

- [ ] **Step 5: Stack the overlay in `RootView`**

In `Sources/FlightDeck/RootView.swift`, add the state objects and replace the `.overlay` block. The `RootView` struct gains:

```swift
    @StateObject private var overlayModel = ToolOverlayModel()
    @StateObject private var overlayMonitor = ToolOverlayInputMonitorBox()
```

`ToolOverlayInputMonitor` is not an `ObservableObject`, so hold it in a tiny box. Add this to the bottom of `ToolOverlayInputMonitor.swift`:

```swift
/// `@StateObject` needs an `ObservableObject`; the monitor publishes nothing, so it is held in
/// a box rather than made observable — an observable monitor would invalidate the view on
/// every mouse move, which is the opposite of what this feature wants.
@MainActor
final class ToolOverlayInputMonitorBox: ObservableObject {
    let monitor = ToolOverlayInputMonitor()
}
```

Then, in `RootView`'s detail branch, replace the existing single `.overlay(alignment: .topTrailing)` modifier with:

```swift
                    // Both float rather than shrinking the terminal: the grid would otherwise
                    // reflow every time either one appeared. Stacked so the find bar and the
                    // tool cluster never contend for the same corner.
                    .overlay(alignment: .topTrailing) {
                        VStack(alignment: .trailing, spacing: 0) {
                            SearchOverlay(surface: surface)
                            if let preferences {
                                ToolOverlay(
                                    store: store,
                                    preferences: preferences,
                                    model: overlayModel,
                                    monitor: overlayMonitor.monitor
                                )
                            }
                        }
                    }
```

- [ ] **Step 6: Install the menu from `AppDelegate`**

Read `Sources/FlightDeck/AppDelegate.swift` first to match how it already reaches the store (it observes `.flightDeckStoreReady` and falls back to `SessionStore.current`). Add a controller property and install it once the store and preferences are available:

```swift
    /// Owned here rather than by a SwiftUI scene: it inserts an AppKit menu into
    /// `NSApp.mainMenu`, which is app-level state with no SwiftUI owner.
    private let toolsMenu = ToolsMenuController()

    /// Wires the Tools menu to the live store. Safe to call more than once — `install` removes
    /// any previous copy — which matters because SwiftUI may rebuild the main menu.
    @MainActor
    private func installToolsMenu(store: SessionStore, preferences: PreferencesStore) {
        toolsMenu.isEnabled = { [weak store] in store?.selectedSessionID != nil }
        toolsMenu.run = { [weak store] tool in
            guard let store else { return }
            ToolRunner.run(tool, store: store, launcher: ShellToolLauncher())
        }
        toolsMenu.openPreferences = {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        toolsMenu.tools = preferences.tools
        preferencesObserver = preferences.objectWillChange.sink { [weak self, weak preferences] _ in
            // `objectWillChange` fires *before* the mutation lands, so read on the next turn.
            DispatchQueue.main.async {
                guard let self, let preferences else { return }
                if self.toolsMenu.tools != preferences.tools { self.toolsMenu.tools = preferences.tools }
            }
        }
        if let mainMenu = NSApp.mainMenu { toolsMenu.install(in: mainMenu) }
    }
```

Add `private var preferencesObserver: AnyCancellable?` and `import Combine` to the file. Call `installToolsMenu(store:preferences:)` from wherever the delegate already learns about the ready store; if the delegate has no reference to `PreferencesStore`, add one by extending the existing `.flightDeckStoreReady` notification handling to also read `store.preferences` — check `SessionStore` for how it exposes its preferences store, and if it does not, pass it through the notification's `userInfo` following the existing pattern in that file.

- [ ] **Step 7: Build and run the unit suite**

Run: `./scripts/build.sh && ./scripts/test-unit.sh`
Expected: build succeeds; the full unit suite is green. **Do not launch the built bundle** — Flight Deck has no argv parsing, and a second instance spawns duplicate `claude --resume` processes.

- [ ] **Step 8: Commit**

```bash
git add Sources/FlightDeck/Tools/ToolRunner.swift Sources/FlightDeck/Tools/ToolOverlayModel.swift Sources/FlightDeck/Tools/ToolOverlayInputMonitor.swift Sources/FlightDeck/Tools/ToolOverlay.swift Sources/FlightDeck/RootView.swift Sources/FlightDeck/AppDelegate.swift
git commit -m "$(cat <<'EOF'
float the tool buttons over the terminal, and hang the menu off the app

One passive local monitor on mouseMoved and keyDown, shaped after
SidebarInputMonitor and consuming nothing, so terminal input and
hit-testing cannot change. It qualifies a move by hit-testing and walking
up to TerminalHostView rather than checking a frame: no geometry has to be
plumbed out of SwiftUI, and crossing the sidebar correctly does not fade
the buttons in.

Mouse movement is only available because Ghostty's SurfaceView installs a
tracking area with .mouseMoved — macOS generates those events only when
something asks. That is a dependency on adapt-copied vendored code and is
recorded as a risk in the spec.

The cluster stacks under the find bar rather than sharing the corner, and
both float instead of shrinking the terminal, since the grid would reflow
every time either appeared. Fades are asymmetric: quick in so reaching for
the corner feels immediate, slow out so nothing snaps away under the
pointer. Hidden buttons stop hit-testing, or the corner would swallow
clicks meant for the terminal.

Menu and overlay both run through ToolRunner so the two cannot drift.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 10: The Tools preferences pane

**Files:**
- Create: `Sources/FlightDeck/Tools/SymbolCatalog.swift`
- Create: `Sources/FlightDeck/Preferences/UI/SymbolPicker.swift`
- Create: `Sources/FlightDeck/Preferences/UI/ShortcutRecorder.swift`
- Create: `Sources/FlightDeck/Preferences/UI/ToolsSettingsTab.swift`
- Modify: `Sources/FlightDeck/Preferences/UI/PreferencesView.swift` (fourth tab)
- Test: `Tests/FlightDeckTests/SymbolCatalogTests.swift`

**Interfaces:**
- Consumes: everything from Tasks 2–5.
- Produces: `SymbolCatalog.all: [SymbolCatalog.Entry]`, `SymbolCatalog.matching(_ query: String) -> [Entry]`, `SymbolPicker`, `ShortcutRecorder`, `ToolsSettingsTab`.

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/SymbolCatalogTests.swift`:

```swift
import XCTest
@testable import FlightDeck

@MainActor
final class SymbolCatalogTests: XCTestCase {
    func testAnEmptyQueryReturnsEverything() {
        XCTAssertEqual(SymbolCatalog.matching("").count, SymbolCatalog.all.count)
    }

    func testSearchMatchesKeywordsNotJustSymbolNames() {
        // "git" must find `arrow.triangle.branch`, whose name contains no such substring.
        // Without keywords the picker is only usable by people who already know SF Symbol
        // names, which is nobody.
        let names = SymbolCatalog.matching("git").map(\.name)
        XCTAssertTrue(names.contains("arrow.triangle.branch"), "got \(names)")
    }

    func testSearchIsCaseInsensitive() {
        XCTAssertEqual(SymbolCatalog.matching("TERMINAL").map(\.name),
                       SymbolCatalog.matching("terminal").map(\.name))
    }

    func testAQueryThatMatchesNothingReturnsNothing() {
        XCTAssertTrue(SymbolCatalog.matching("zzzznotasymbol").isEmpty)
    }

    func testTheDefaultToolSymbolsAreInTheCatalog() {
        // Otherwise the picker opens on a selection it cannot show.
        let names = Set(SymbolCatalog.all.map(\.name))
        XCTAssertTrue(names.contains("chevron.left.forwardslash.chevron.right"))
        XCTAssertTrue(names.contains("terminal"))
    }

    func testEverySymbolInTheCatalogResolvesOnThisSystem() {
        // A typo'd SF Symbol name renders as a blank button with no error anywhere.
        for entry in SymbolCatalog.all {
            XCTAssertNotNil(
                NSImage(systemSymbolName: entry.name, accessibilityDescription: nil),
                "\(entry.name) is not a real SF Symbol"
            )
        }
    }
}
```

Add `import AppKit` at the top of that test file.

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: compile failure — `cannot find 'SymbolCatalog' in scope`.

- [ ] **Step 3: Write the catalog**

Create `Sources/FlightDeck/Tools/SymbolCatalog.swift`:

```swift
import Foundation

/// The symbols offered by the icon picker.
///
/// Curated rather than exhaustive. There is no public API to enumerate SF Symbols, so a full
/// catalog would mean bundling a ~6000-name list of which almost none describe a developer
/// tool. Each entry carries keywords because the names are not guessable: nobody searching for
/// a git client types "arrow.triangle.branch".
enum SymbolCatalog {
    struct Entry: Identifiable, Equatable {
        var name: String
        var keywords: [String]
        var id: String { name }
    }

    static let all: [Entry] = [
        Entry(name: "chevron.left.forwardslash.chevron.right", keywords: ["editor", "code", "ide"]),
        Entry(name: "terminal", keywords: ["terminal", "shell", "console"]),
        Entry(name: "arrow.triangle.branch", keywords: ["git", "branch", "vcs", "fork"]),
        Entry(name: "arrow.triangle.pull", keywords: ["git", "pull request", "merge", "vcs"]),
        Entry(name: "folder", keywords: ["files", "finder", "directory"]),
        Entry(name: "doc.text", keywords: ["document", "file", "notes"]),
        Entry(name: "hammer", keywords: ["build", "compile", "make"]),
        Entry(name: "wrench.and.screwdriver", keywords: ["tools", "settings", "utility"]),
        Entry(name: "ladybug", keywords: ["debug", "bug", "debugger"]),
        Entry(name: "gearshape", keywords: ["settings", "config", "preferences"]),
        Entry(name: "globe", keywords: ["browser", "web", "internet"]),
        Entry(name: "cloud", keywords: ["deploy", "server", "remote"]),
        Entry(name: "server.rack", keywords: ["server", "database", "infra"]),
        Entry(name: "cylinder.split.1x2", keywords: ["database", "db", "sql"]),
        Entry(name: "chart.bar", keywords: ["metrics", "analytics", "dashboard"]),
        Entry(name: "magnifyingglass", keywords: ["search", "find", "grep"]),
        Entry(name: "paintbrush", keywords: ["design", "format", "style"]),
        Entry(name: "play.rectangle", keywords: ["run", "start", "execute"]),
        Entry(name: "checkmark.seal", keywords: ["test", "verify", "lint"]),
        Entry(name: "book", keywords: ["docs", "documentation", "manual"]),
        Entry(name: "envelope", keywords: ["mail", "message", "email"]),
        Entry(name: "bubble.left.and.bubble.right", keywords: ["chat", "slack", "message"]),
        Entry(name: "calendar", keywords: ["calendar", "schedule", "meeting"]),
        Entry(name: "list.bullet.rectangle", keywords: ["issues", "tasks", "tickets", "jira"]),
        Entry(name: "square.grid.2x2", keywords: ["apps", "launcher", "grid"]),
        Entry(name: "bolt", keywords: ["fast", "action", "run"]),
        Entry(name: "star", keywords: ["favorite", "bookmark"]),
        Entry(name: "tray.full", keywords: ["inbox", "queue", "logs"]),
    ]

    /// Matches the symbol name or any keyword, case-insensitively. An empty query is "show
    /// everything" rather than "show nothing", so opening the picker shows the grid.
    static func matching(_ query: String) -> [Entry] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return all }
        return all.filter { entry in
            entry.name.lowercased().contains(needle)
                || entry.keywords.contains { $0.lowercased().contains(needle) }
        }
    }
}
```

- [ ] **Step 4: Run the catalog tests to verify they pass**

Run: `./scripts/test-unit.sh`
Expected: PASS, all 6 `SymbolCatalogTests` cases. If `testEverySymbolInTheCatalogResolvesOnThisSystem` fails, the named symbol does not exist on macOS 14 — replace it, do not weaken the assertion.

- [ ] **Step 5: Write the symbol picker**

Create `Sources/FlightDeck/Preferences/UI/SymbolPicker.swift`:

```swift
import SwiftUI

/// A button showing the current symbol, opening a searchable grid.
struct SymbolPicker: View {
    @Binding var symbol: String
    @State private var isPresented = false
    @State private var query = ""

    private let columns = Array(repeating: GridItem(.fixed(32), spacing: 6), count: 7)

    var body: some View {
        Button {
            isPresented = true
        } label: {
            Image(systemName: symbol)
                .frame(width: 22, height: 22)
        }
        .accessibilityIdentifier("tool-symbol-picker")
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 8) {
                TextField("Search", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)

                ScrollView {
                    LazyVGrid(columns: columns, spacing: 6) {
                        ForEach(SymbolCatalog.matching(query)) { entry in
                            Button {
                                symbol = entry.name
                                isPresented = false
                            } label: {
                                Image(systemName: entry.name)
                                    .frame(width: 28, height: 28)
                                    .background(
                                        RoundedRectangle(cornerRadius: 5)
                                            .fill(entry.name == symbol ? Color.accentColor.opacity(0.25) : .clear)
                                    )
                            }
                            .buttonStyle(.borderless)
                            .help(entry.name)
                        }
                    }
                }
                .frame(width: 260, height: 180)
            }
            .padding(10)
        }
    }
}
```

- [ ] **Step 6: Write the shortcut recorder**

Create `Sources/FlightDeck/Preferences/UI/ShortcutRecorder.swift`:

```swift
import AppKit
import SwiftUI

/// Records a chord for a tool.
///
/// Arms a local `keyDown` monitor and **consumes** the next key event, which is what lets even
/// ⌘Q be recorded: local monitors run ahead of `NSApplication.sendEvent`, and therefore ahead
/// of `performKeyEquivalent`, so nothing else sees the key first.
struct ShortcutRecorder: View {
    @Binding var shortcut: ToolShortcut?

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(buttonTitle) {
                isRecording ? stop() : start()
            }
            .frame(minWidth: 110)
            .accessibilityIdentifier("tool-shortcut-recorder")

            if shortcut != nil, !isRecording {
                Button {
                    shortcut = nil
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .help("Remove this shortcut")
            }

            if let conflict {
                Text(conflict)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onDisappear { stop() }
    }

    private var buttonTitle: String {
        if isRecording { return "Press keys…" }
        return shortcut?.displayString ?? "Record Shortcut"
    }

    /// Non-blocking: a user may genuinely want to shadow an existing command, so this warns
    /// rather than refuses. Silence would be worse — a chord the menu already owns simply
    /// never reaches the tool, with nothing on screen to explain why.
    private var conflict: String? {
        guard let shortcut, let mainMenu = NSApp.mainMenu else { return nil }
        guard let existing = Self.findConflict(shortcut, in: mainMenu) else { return nil }
        return "\(shortcut.displayString) is already \(existing)"
    }

    private static func findConflict(_ shortcut: ToolShortcut, in menu: NSMenu) -> String? {
        for item in menu.items {
            if let submenu = item.submenu, submenu.title != "Tools",
               let found = findConflict(shortcut, in: submenu) {
                return found
            }
            guard item.submenu == nil else { continue }
            if item.keyEquivalent == shortcut.key,
               item.keyEquivalentModifierMask == shortcut.modifierFlags {
                return item.title
            }
        }
        return nil
    }

    private func start() {
        guard monitor == nil else { return }
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            handle(event)
            return nil   // consumed, so the chord being recorded cannot also fire
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
    }

    private func handle(_ event: NSEvent) {
        // Escape cancels, so a recorder can be dismissed without binding something.
        if event.keyCode == 53 { stop(); return }
        // Delete clears.
        if event.keyCode == 51 || event.keyCode == 117 { shortcut = nil; stop(); return }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // At least ⌘ or ⌃ is required. A bare letter or a ⇧/⌥ combination would be a valid
        // menu key equivalent that swallows ordinary typing everywhere in the app.
        guard modifiers.contains(.command) || modifiers.contains(.control) else { return }
        guard let characters = event.charactersIgnoringModifiers, !characters.isEmpty else { return }

        shortcut = ToolShortcut(key: characters, modifiers: modifiers)
        stop()
    }
}
```

- [ ] **Step 7: Write the tab**

Create `Sources/FlightDeck/Preferences/UI/ToolsSettingsTab.swift`:

```swift
import SwiftUI

/// External tools, their icons, and their shortcuts.
struct ToolsSettingsTab: View {
    @ObservedObject var preferences: PreferencesStore
    @ObservedObject var sessions: SessionStore

    @State private var selection: UUID?

    private var tools: [ToolDefinition] { preferences.tools }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 0) {
                toolList
                Divider()
                detail
            }
            Divider()
            variableReference
        }
    }

    private var toolList: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                // The list ORDER is semantic, like the Agents tab's: it is the overlay's
                // left-to-right order, which is why this is reorderable.
                ForEach(tools) { tool in
                    HStack(spacing: 6) {
                        Image(systemName: tool.symbol).frame(width: 18)
                        Text(tool.name)
                        Spacer()
                        if let shortcut = tool.shortcut {
                            Text(shortcut.displayString)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(tool.id)
                }
                .onMove { source, destination in
                    var list = tools
                    list.move(fromOffsets: source, toOffset: destination)
                    preferences.tools = list
                }
            }
            .accessibilityIdentifier("tools-list")

            HStack(spacing: 4) {
                Button {
                    let tool = ToolDefinition(name: "New Tool", symbol: "wrench.and.screwdriver", command: "")
                    preferences.tools.append(tool)
                    selection = tool.id
                } label: {
                    Image(systemName: "plus")
                }
                .accessibilityIdentifier("tools-add")

                Button {
                    guard let selection else { return }
                    preferences.tools.removeAll { $0.id == selection }
                    self.selection = nil
                } label: {
                    Image(systemName: "minus")
                }
                .disabled(selection == nil)
                .accessibilityIdentifier("tools-remove")

                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(6)
        }
        .frame(width: 220)
    }

    @ViewBuilder
    private var detail: some View {
        if let index = tools.firstIndex(where: { $0.id == selection }) {
            Form {
                LabeledContent("Name") {
                    TextField("", text: binding(index, \.name)).frame(width: 200)
                }
                LabeledContent("Icon") {
                    SymbolPicker(symbol: binding(index, \.symbol))
                }
                LabeledContent("Command") {
                    TextField("", text: binding(index, \.command))
                        .font(.system(.body, design: .monospaced))
                        .frame(width: 260)
                }
                LabeledContent("Runs") {
                    // The preview is what makes shell quoting visible up front, rather than
                    // something discovered the first time a path has a space in it. Free —
                    // expansion is already a pure function.
                    Text(preview(for: tools[index]))
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(width: 260, alignment: .leading)
                }
                LabeledContent("Shortcut") {
                    ShortcutRecorder(shortcut: binding(index, \.shortcut))
                }
                Toggle("Show in terminal overlay", isOn: binding(index, \.showsInOverlay))
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity)
        } else {
            ContentUnavailableView("No Tool Selected", systemImage: "wrench.and.screwdriver")
                .frame(maxWidth: .infinity)
        }
    }

    private var variableReference: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Available variables")
                .font(.caption.bold())
            Text("${cwd} · ${project} · ${root} · ${projectName} · ${session} · ${agent} · ${conversationID} · ${transcript} · ${home}")
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
            Text("Values are quoted, so paths with spaces stay one argument. Anything else — $EDITOR, ${HOME} — is left for your login shell, which runs the command with your profile loaded.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
    }

    /// Expanded against the real selection when there is one, so the preview shows the paths
    /// the user will actually get. The sample keeps the row from being blank otherwise.
    private func preview(for tool: ToolDefinition) -> String {
        let context = sessions.toolContext() ?? ToolContext(
            workingDirectory: "/Users/you/Projects/example",
            projectPath: "/Users/you/Projects/example",
            projectName: "example",
            sessionTitle: "session",
            agent: .claude,
            conversationID: UUID(),
            transcriptPath: nil
        )
        return ToolTemplate.expand(tool.command, in: context)
    }

    private func binding<V>(
        _ index: Int, _ keyPath: WritableKeyPath<ToolDefinition, V>
    ) -> Binding<V> {
        Binding(
            get: { preferences.tools[index][keyPath: keyPath] },
            set: { preferences.tools[index][keyPath: keyPath] = $0 }
        )
    }
}
```

- [ ] **Step 8: Add the tab to `PreferencesView`**

In `Sources/FlightDeck/Preferences/UI/PreferencesView.swift`, add after `ShellSettingsTab`:

```swift
            ToolsSettingsTab(preferences: preferences, sessions: sessions)
                .tabItem { Label("Tools", systemImage: "wrench.and.screwdriver") }
                .accessibilityIdentifier("prefs-tools")
```

- [ ] **Step 9: Build and run the unit suite**

Run: `./scripts/build.sh && ./scripts/test-unit.sh`
Expected: build succeeds; the full unit suite is green. Do not launch the bundle.

- [ ] **Step 10: Commit**

```bash
git add Sources/FlightDeck/Tools/SymbolCatalog.swift Sources/FlightDeck/Preferences/UI/SymbolPicker.swift Sources/FlightDeck/Preferences/UI/ShortcutRecorder.swift Sources/FlightDeck/Preferences/UI/ToolsSettingsTab.swift Sources/FlightDeck/Preferences/UI/PreferencesView.swift Tests/FlightDeckTests/SymbolCatalogTests.swift
git commit -m "$(cat <<'EOF'
add the Tools preferences pane

The symbol catalog is curated and keyword-searchable rather than
exhaustive. There is no public API to enumerate SF Symbols, so "all of
them" would mean bundling ~6000 names of which almost none describe a
developer tool — and the names are not guessable anyway: nobody searching
for a git client types arrow.triangle.branch. A test asserts every catalog
entry resolves on this system, because a typo'd symbol name renders as a
blank button with no error anywhere.

The command field carries a live expansion preview against the real
selection. Expansion is already a pure function, so it costs nothing, and
it is what makes shell quoting visible up front instead of something
discovered the first time a path contains a space.

The recorder consumes the key event it captures, which is what lets even ⌘Q
be recorded: local monitors run ahead of sendEvent and therefore ahead of
performKeyEquivalent. It requires ⌘ or ⌃, since a bare letter would be a
valid key equivalent that swallows ordinary typing app-wide, and it warns
on a conflict rather than refusing — shadowing may be deliberate, but
silence would mean a chord that simply never reaches the tool.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 11: Documentation

`AGENTS.md` requires the affected doc to change in the same branch as the behaviour.

**Files:**
- Modify: `docs/ARCHITECTURE.md`
- Modify: `README.md`

- [ ] **Step 1: Read the two docs**

Read `docs/ARCHITECTURE.md` fully and `README.md`'s "What it does" list, so the additions match the existing voice — behavioural, specific, no marketing.

- [ ] **Step 2: Add the tools spine to ARCHITECTURE.md**

Add a section following the file's existing structure and heading style. It must cover:
- the spine: `ToolsMenuController` / `ToolOverlay` → `ToolRunner` → `ToolTemplate` → `ShellToolLauncher`;
- that `SessionStore.toolContext()` is the only bridge, and that everything agent-shaped goes through `AgentAdapter.location(for:)` so claude's path derivation stays out of the tools subsystem;
- why the menu is AppKit (SwiftUI cannot vary a key equivalent at runtime) and that `MenuKeyEquivalents` therefore covers it unchanged;
- that the overlay's fade is a clock-free state machine fed by one passive local monitor, and that mouse movement is available only because Ghostty's `SurfaceView` installs a `.mouseMoved` tracking area.

- [ ] **Step 3: Add a README bullet**

Add one bullet to the "What it does" list, in the voice of its neighbours. For example:

```markdown
- Editors, terminals and git clients open on whatever the selected agent is working on —
  ⌘O, ⌘T, or the buttons that fade in over the terminal when you move the mouse. Each is a
  shell command you can edit, so `$EDITOR` and your own tools work the way they do in a
  terminal.
```

- [ ] **Step 4: Verify the build is untouched**

Run: `./scripts/test-unit.sh`
Expected: PASS. (Docs-only change; this confirms nothing was edited by accident.)

- [ ] **Step 5: Commit**

```bash
git add docs/ARCHITECTURE.md README.md
git commit -m "$(cat <<'EOF'
docs: describe the external tools spine

Records the four things a reader would otherwise have to reconstruct: that
SessionStore.toolContext() is the only bridge into the tools subsystem and
routes agent facts through AgentAdapter.location(for:); that the menu is
AppKit because SwiftUI cannot vary a key equivalent at runtime, and that
MenuKeyEquivalents therefore covers it with no change; and that the
overlay's fade-in depends on a tracking area owned by adapt-copied Ghostty.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-Review

**Spec coverage.** §3 model → Tasks 3, 4. §3.1 adapter boundary → Tasks 1, 5. §4 expansion → Task 2. §5 launching and failure reporting → Task 6. §6 menu → Tasks 7, 9. §7 overlay and input → Tasks 8, 9. §8 preferences pane, symbol picker, recorder → Task 10. §9 test table → Tasks 1–8, 10. §10 file list → matches Tasks 1–10, plus `ToolRunner.swift` and `SymbolCatalog.swift`, which the spec's list omitted; both are additive and noted here rather than left as a silent divergence. §11 risks → the vendored-tracking-area risk is a comment in Task 9; the menu-index risk is covered by Task 7's two placement tests; the `location(for:)` inherited-default risk is covered by Task 1's override test.

**Type consistency.** `AgentLocation.workingDirectory` / `.binding` are used identically in Tasks 1 and 5. `ToolContext`'s member order and labels match between its definition (Task 2), its construction in `SessionStore` (Task 5), and the preview fallback (Task 10). `ToolShortcut(key:modifiers:)` takes `NSEvent.ModifierFlags` at every call site. `ToolLaunching.launch(command:in:named:)` has one signature across Tasks 6, 9. `PreferencesStore.tools` is the single accessor in Tasks 4, 9, 10.

**Known soft spot.** Task 9 Step 6 is the one place the plan cannot be fully literal: `AppDelegate` has to reach a `PreferencesStore`, and how it does so depends on what that file already holds. The step says to read the file and follow its existing `.flightDeckStoreReady` pattern rather than inventing one. Expect that step to need judgement; everything else is copy-ready.
