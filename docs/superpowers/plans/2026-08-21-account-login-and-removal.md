# Account Sign-In and Removal Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make "Sign In Now" actually authenticate an account, and make the Accounts pane's `−` button removable-with-a-warning instead of permanently disabled.

**Architecture:** Three independent defects. (1) The sign-in command is typed into a pty that adds no Return — normalize at the one consumer. (2) The `/login` follow-up is misrouted through the *rename* channel — give the store a text-carrying deferred-prompt queue, generalized from the resume-prompt queue that already exists. (3) Removal is blocked by a guard protecting a real hazard — replace hard delete with a tombstone, which retires the hazard by construction because a tombstoned account still resolves by id.

**Tech Stack:** Swift 6 / SwiftUI / AppKit, XCTest, embedded libghostty. Build via `xcodegen` + `xcodebuild`.

**Spec:** `docs/superpowers/specs/2026-08-21-account-login-and-removal-design.md` (committed `6033678`)

## Global Constraints

- **Comments explain *why*, and name the failure they prevent** (`docs/CONVENTIONS.md`). A comment restating the code is noise here. When behavior changes, **rewrite the stale comments** rather than leaving them to outlive their code.
- **Commit format:** `<type>: <lowercase behavioral subject>` — subject says what changes for the user or system, not what code moved. Long subjects (70–90 chars) are normal. Body explains mechanism, evidence, alternatives rejected; wrap ~76.
- **Every commit carries the trailer:** `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`
- **Test command:** `./scripts/test-unit.sh` — runs the whole headless bundle; there is no filter flag. To watch one suite, pipe it: `./scripts/test-unit.sh 2>&1 | rg "<SuiteName>|Executed .* tests"`.
- **Never launch a build by swapping `/Applications`** — it kills every other Claude session on this machine. Debug builds run in place from `DerivedData/Build/Products/Debug/`.
- **This checkout is shared with other live sessions.** Never `git stash`, `git checkout --`, or revert files you did not write. Stage only the exact paths each task names.
- **`@MainActor` async tests must use `await fulfillment(of:)`**, never `wait(for:)` — the latter deadlocks.

---

### Task 1: A sign-in command the shell actually executes

`initial_input` reaches the pty as typed characters with no implicit Return (`SurfaceConfiguration.swift:99` passes it straight through). Every working producer appends `"\n"` itself — `ClaudeSession.launchCommand:130`, `resumeCommand:148` — but `LoginInvocation.command` is `"claude"` / `"codex login"`, so the sign-in tab sits at a prompt forever.

The newline goes at the one consumer, not in each adapter: an adapter is asked *what to run* and has no reason to know the answer is fed to a pty rather than to `Process`.

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (`openSignInSession`, ~line 1242)
- Test: `Tests/FlightDeckTests/AccountSignInTests.swift` (create)

**Interfaces:**
- Produces: `SessionStore.terminated(_ command: String) -> String` (`static`, internal — Task 3 reuses it)

- [ ] **Step 1: Write the failing test**

Create `Tests/FlightDeckTests/AccountSignInTests.swift`:

```swift
import XCTest
@testable import FlightDeck

/// The Accounts pane's Sign In path. Everything here is store-level: what gets typed at the
/// shell, and what gets queued to be typed at the agent once it is up.
@MainActor
final class AccountSignInTests: XCTestCase {
    /// Keeps every configuration it was handed — `initialInput` is the assertion.
    private final class RecordingProvider: SurfaceProvider {
        var configs: [Ghostty.SurfaceConfiguration] = []
        func makeSurface(_ config: Ghostty.SurfaceConfiguration) -> Ghostty.SurfaceView? {
            configs.append(config)
            return nil
        }
        func tick() {}
    }

    /// `SessionStore.provider` is weak, so a provider held only by the store deallocates
    /// before it is ever asked for a surface.
    private var retained: [RecordingProvider] = []
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        retained = []
    }

    /// A command with no trailing newline is typed and never run: `initial_input` reaches the
    /// pty verbatim, and nothing downstream presses Return.
    func testAnUnterminatedCommandGainsItsNewline() {
        XCTAssertEqual(SessionStore.terminated("claude"), "claude\n")
        XCTAssertEqual(SessionStore.terminated("codex login"), "codex login\n")
    }

    /// Not doubled: `ClaudeSession.launchCommand` already ends in one, and a blank line typed
    /// at a shell is a stray empty prompt.
    func testAnAlreadyTerminatedCommandIsLeftAlone() {
        XCTAssertEqual(SessionStore.terminated("claude\n"), "claude\n")
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | rg "AccountSignInTests|error:|Executed .* tests"`
Expected: a compile error — `type 'SessionStore' has no member 'terminated'`.

- [ ] **Step 3: Add the normalization**

In `Sources/FlightDeck/SessionStore.swift`, add next to `openSignInSession`:

```swift
    /// Terminates a command so the shell actually runs it.
    ///
    /// `initial_input` reaches the pty as typed characters and nothing downstream presses
    /// Return — which is why every other producer ends its own string with a newline
    /// (`ClaudeSession.launchCommand`, `resumeCommand`). `LoginInvocation` does not, and the
    /// symptom was a sign-in tab sitting at a prompt with `claude` typed into it forever.
    ///
    /// Normalized here rather than in each adapter's `LoginInvocation` deliberately: an
    /// adapter is asked *what to run*, and a future agent's author has no reason to know the
    /// answer is fed to a pty rather than to `Process`. One consumer cannot forget.
    static func terminated(_ command: String) -> String {
        command.hasSuffix("\n") ? command : command + "\n"
    }
```

- [ ] **Step 4: Apply it in `openSignInSession`**

Change the `addSession` call at the end of `openSignInSession` from `initialInput: typing` to:

```swift
            session, in: URL(fileURLWithPath: directory, isDirectory: true),
            initialInput: Self.terminated(typing)
```

Then update that method's doc comment — it currently says `typing` is "sent verbatim", which is no longer true. Replace that clause with: "`typing` is `LoginInvocation`'s own `command` (`"claude"`, `"codex login"`), newline-terminated by `terminated(_:)` rather than built from `AgentAdapter.launchCommand`."

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | rg "AccountSignInTests|error:|failed|Executed .* tests"`
Expected: PASS, whole suite green.

- [ ] **Step 6: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/AccountSignInTests.swift
git commit -m "$(cat <<'EOF'
fix: press Return on the sign-in command so signing in actually starts the agent

`initial_input` reaches the pty as typed characters with no implicit
Return (SurfaceConfiguration.swift:99 passes it straight through), which
is why every working producer terminates its own string —
ClaudeSession.launchCommand:130 and resumeCommand:148 both end "\n".
LoginInvocation does not, so "Sign In Now" opened a tab with the literal
text `claude` sitting at a shell prompt, unexecuted. Same for
`codex login`.

Normalized in openSignInSession rather than in each adapter's
LoginInvocation: an adapter is asked what to run and has no reason to
know the answer is fed to a pty rather than to Process, so putting it at
the single consumer means a future agent cannot forget it.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: A deferred prompt that carries its own text

Pure refactor, no behavior change — it exists so Task 3 has somewhere correct to put `/login`.

`SessionStore.inject` gates on `statuses[id]?.activity == .idle` plus a readable one-row `InputBar`, neither of which holds while `claude` boots, so any injection needs a retry queue. One already exists — `pendingResumePrompts: [UUID: Date]` — but its text is the hardcoded constant `Self.resumePrompt`. Generalize it to carry text.

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (declaration ~`:835`, `restore` ~`:1717`, `flushPendingResumePrompts` ~`:2724`, `cancelSupersededPrompts` ~`:2753`, `applyRegistry`'s `defer` ~`:2896`)
- Modify: `Tests/FlightDeckTests/SessionAutoResumeTests.swift` (assertions read `.deadline` now)

**Interfaces:**
- Consumes: nothing
- Produces: `SessionStore.DeferredPrompt` (`struct`, `Equatable`, fields `let text: String`, `let deadline: Date`); `SessionStore.pendingPrompts: [UUID: DeferredPrompt]` (`private(set)`, internal); `SessionStore.flushPendingPrompts()`

- [ ] **Step 1: Rename the storage and give it a type**

In `Sources/FlightDeck/SessionStore.swift`, replace the `pendingResumePrompts` declaration (~`:835`) with:

```swift
    /// One queued injection per tab: what to type, and when it stops being worth typing.
    ///
    /// Carries its text rather than assuming one, because two callers now share this queue —
    /// `restore` queues "Keep going" for a resumed session, and `openSignInSession` queues an
    /// agent's `LoginInvocation.inject` (`/login`). Before it carried text, sign-in had
    /// nowhere correct to go and was routed through the *rename* channel instead, which typed
    /// `/rename /login` at the tab.
    struct DeferredPrompt: Equatable {
        let text: String
        let deadline: Date
    }

    private(set) var pendingPrompts: [UUID: DeferredPrompt] = [:]
```

Delete the old `pendingResumePrompts` declaration and its doc comment.

- [ ] **Step 2: Update the four use sites**

In `restore` (~`:1717`), replace `pendingResumePrompts[entry.id] = promptDeadline` with:

```swift
                pendingPrompts[entry.id] = DeferredPrompt(
                    text: Self.resumePrompt, deadline: promptDeadline
                )
```

Rename `flushPendingResumePrompts()` to `flushPendingPrompts()` and rewrite its body:

```swift
    /// Types every queued prompt that is finally ready for it.
    ///
    /// Driven by the registry scan because a queued prompt usually waits on an agent that has
    /// not finished booting — which is not a status change, so gating the retry on one would
    /// strand it.
    private func flushPendingPrompts() {
        let currentTime = now()
        for (id, prompt) in pendingPrompts {
            guard currentTime < prompt.deadline else {
                // Dropped unsent. See `resumePromptWindow`.
                pendingPrompts.removeValue(forKey: id)
                continue
            }
            // A rename is a direct user action and wants the same input box. It will clear
            // itself within a tick or two, and this is queued anyway.
            guard pendingRenames[id] == nil else { continue }
            inject(
                prompt.text,
                into: id,
                // Cancelled during the settle window — the session started working on its
                // own, or the deadline passed on another path.
                stillWanted: { [weak self] in self?.pendingPrompts[id] != nil },
                onSent: { [weak self] in self?.pendingPrompts.removeValue(forKey: id) }
            )
        }
    }
```

In `cancelSupersededPrompts` (~`:2753`), change the early-out guard to `guard !pendingPrompts.isEmpty else { return }` and both `pendingResumePrompts.removeValue(forKey: transition.id)` calls to `pendingPrompts.removeValue(forKey: transition.id)`.

In `applyRegistry`'s `defer` (~`:2899`), change `flushPendingResumePrompts()` to `flushPendingPrompts()`.

- [ ] **Step 3: Update the existing assertions**

In `Tests/FlightDeckTests/SessionAutoResumeTests.swift`, replace every `store.pendingResumePrompts[X]` with `store.pendingPrompts[X]`. The two that compare a `Date` directly (~`:111` and `:133-134`) must read the field: `store.pendingPrompts[ids[0]]?.deadline`.

Also add one assertion to the test at `:133` proving the text travelled:

```swift
        XCTAssertEqual(store.pendingPrompts[ids[0]]?.text, SessionStore.resumePrompt)
```

- [ ] **Step 4: Run the tests**

Run: `./scripts/test-unit.sh 2>&1 | rg "SessionAutoResumeTests|error:|failed|Executed .* tests"`
Expected: PASS. This task changes no behavior, so any failure is a mistranscribed use site.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift Tests/FlightDeckTests/SessionAutoResumeTests.swift
git commit -m "$(cat <<'EOF'
refactor: let a queued prompt carry its own text instead of assuming "Keep going"

pendingResumePrompts held [UUID: Date] and injected the hardcoded
Self.resumePrompt, so it could serve exactly one caller. Sign-in needs
the same deferred-retry behaviour for a different string — inject() gates
on an idle status and a readable one-row InputBar, neither of which holds
while claude boots, so a single attempt is guaranteed to fail — and
having nowhere correct to put that string is why sign-in was routed
through the rename channel instead.

Pure refactor: same deadline, same rename precedence, same
cancel-on-busy/waiting, same registry-scan retry tick. Only the value
type changes.

Rejected a parallel pendingLogins queue: it duplicates ~15 lines and
creates a second home for the rename-precedence rule to drift out of.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Sign-in queues `/login` through the prompt queue, not the rename channel

`AccountsSection.signIn` currently does:

```swift
guard let inject = invocation.inject, let claude = adapter as? ClaudeAdapter else { return }
Task { await claude.injectRename(session.pinnedConversationID, inject) }
```

`ClaudeAdapter.injectRename` is a closure the store supplies (`SessionStore.swift:534-544`) whose whole job is to queue a **rename**: it lands in `pendingRenames` and types `"/rename \(name)"`. `/` is not in `shellMetacharacters` (`ClaudeSession.swift:77`), so `sanitizedName("/login")` returns `"/login"` intact and the tab is eventually sent `/rename /login` — renaming the conversation instead of authenticating, and clobbering any genuine pending rename for that tab.

**Files:**
- Modify: `Sources/FlightDeck/SessionStore.swift` (`openSignInSession`)
- Modify: `Sources/FlightDeck/Preferences/UI/AccountsSection.swift` (`signIn`, ~`:300-307`)
- Modify: `Tests/FlightDeckTests/FleetAccountEmissionTests.swift` (two `openSignInSession` call sites, `:31` and `:150`)
- Test: `Tests/FlightDeckTests/AccountSignInTests.swift` (extend)

**Interfaces:**
- Consumes: `SessionStore.terminated(_:)` (Task 1); `SessionStore.DeferredPrompt`, `pendingPrompts` (Task 2)
- Produces: `SessionStore.openSignInSession(for: AgentAccount, in: String, using: LoginInvocation) -> Session` (`@discardableResult`) — replaces the `typing: String` signature

- [ ] **Step 1: Write the failing tests**

Append to `Tests/FlightDeckTests/AccountSignInTests.swift` (inside the class):

```swift
    private func makeAccount(_ agent: AgentID, named name: String = "Work") -> AgentAccount {
        AgentAccount(agent: agent, displayName: name, home: root.appendingPathComponent(name))
    }

    private func makeStore() -> (SessionStore, RecordingProvider) {
        let provider = RecordingProvider()
        retained.append(provider)
        let store = SessionStore(provider: provider, persistence: nil)
        store.transcriptsRootOverride = root.appendingPathComponent("projects")
        store.statusRootOverride = root.appendingPathComponent("status")
        return (store, provider)
    }

    /// The whole point of Task 1, asserted through the real path rather than on the helper.
    func testTheSignInTabIsHandedANewlineTerminatedCommand() {
        let (store, provider) = makeStore()
        store.openSignInSession(
            for: makeAccount(.claude), in: root.path,
            using: LoginInvocation(command: "claude", inject: "/login")
        )
        XCTAssertEqual(provider.configs.last?.initialInput, "claude\n")
    }

    /// The regression test for the misrouting. `/login` must be queued as a prompt; queuing it
    /// as a rename typed `/rename /login` at the tab, renaming the conversation instead of
    /// authenticating and clobbering any genuine pending rename.
    func testSignInQueuesTheInjectionAsAPromptAndNeverAsARename() {
        let (store, _) = makeStore()
        let session = store.openSignInSession(
            for: makeAccount(.claude), in: root.path,
            using: LoginInvocation(command: "claude", inject: "/login")
        )
        XCTAssertEqual(store.pendingPrompts[session.id]?.text, "/login")
        XCTAssertTrue(store.pendingRenamesForTesting.isEmpty, "a login is not a rename")
    }

    /// Codex signs in with a one-shot subcommand and has nothing to type afterwards, so it
    /// must not leave an entry sitting in the queue until its deadline.
    func testAnAgentWithNothingToInjectQueuesNothing() {
        let (store, provider) = makeStore()
        let session = store.openSignInSession(
            for: makeAccount(.codex), in: root.path,
            using: LoginInvocation(command: "codex login", inject: nil)
        )
        XCTAssertEqual(provider.configs.last?.initialInput, "codex login\n")
        XCTAssertNil(store.pendingPrompts[session.id])
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | rg "AccountSignInTests|error:|Executed .* tests"`
Expected: compile errors — no `using:` overload, and no `pendingRenamesForTesting`.

- [ ] **Step 3: Expose the rename queue for the regression assertion**

`pendingRenames` is `private`. Add a read-only test seam beside it in `SessionStore.swift`:

```swift
    /// Read-only view of the rename queue, so `AccountSignInTests` can assert that signing in
    /// puts nothing in it. Sign-in used to queue `/login` *as a rename*, and the only way to
    /// pin that regression is to look at this from outside.
    var pendingRenamesForTesting: [UUID: String] { pendingRenames }
```

- [ ] **Step 4: Give `openSignInSession` the whole invocation**

Replace the signature and body (keeping the existing doc comment's first three paragraphs, and rewriting its last paragraph):

```swift
    @discardableResult
    func openSignInSession(
        for account: AgentAccount, in directory: String, using invocation: LoginInvocation
    ) -> Session {
        let session = Session(
            title: nextSessionTitle(), workingDirectory: directory, agent: account.agent,
            accountID: account.id
        )
        let created = addSession(
            session, in: URL(fileURLWithPath: directory, isDirectory: true),
            initialInput: Self.terminated(invocation.command)
        )
        // Queued rather than sent: `inject` needs an idle status and a readable one-row
        // InputBar, and this tab is a bare shell that has not even started the agent yet. The
        // registry scan retries it until the agent is up, or the deadline passes.
        //
        // Deliberately NOT routed through `ClaudeAdapter.injectRename`, which is what this
        // used to do: that is the *rename* channel, and it typed `/rename /login` at the tab.
        if let inject = invocation.inject {
            pendingPrompts[created.id] = DeferredPrompt(
                text: inject, deadline: now().addingTimeInterval(Self.resumePromptWindow)
            )
        }
        return created
    }
```

Rewrite the method's final doc paragraph to: "`invocation` is the agent's own `LoginInvocation`: its `command` (`"claude"`, `"codex login"`) is newline-terminated and typed at the shell, and its `inject` (`/login`, or nil) is queued for the agent once it is up. The store owns both halves so no caller has to know which agent it is holding."

- [ ] **Step 5: Simplify the view**

In `Sources/FlightDeck/Preferences/UI/AccountsSection.swift`, replace `signIn` entirely:

```swift
    /// What both "Sign In Now" (from the Add sheet) and "Sign In Again" (from the context
    /// menu) call — there is nothing to distinguish a first login from a re-login, per the
    /// spec's "re-login needs no separate machinery" note.
    ///
    /// Reads the account's `LoginInvocation` off its adapter and hands the whole thing to the
    /// store, which owns both halves. This view used to unwrap the invocation itself and push
    /// the `/login` half through `ClaudeAdapter.injectRename` behind an `as? ClaudeAdapter`
    /// downcast — that downcast is what dragged the *rename* channel into a login, and a view
    /// has no business knowing which adapter class it is holding in the first place.
    private func signIn(_ account: AgentAccount) {
        let adapter = sessions.adapter(for: account.agent, account: account.id)
        let directory = frontmostProjectPath ?? account.home.path
        sessions.openSignInSession(
            for: account, in: directory, using: adapter.loginInvocation(for: account)
        )
    }
```

- [ ] **Step 6: Update the other call sites**

In `Tests/FlightDeckTests/FleetAccountEmissionTests.swift`, change both calls (`:31`, `:150`) from `typing: "claude"` to `using: LoginInvocation(command: "claude", inject: nil)`. `inject: nil` keeps those tests asserting only what they are about — fleet emission — rather than incidentally queuing a prompt.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | rg "AccountSignInTests|FleetAccountEmission|error:|failed|Executed .* tests"`
Expected: PASS, whole suite green.

- [ ] **Step 8: Commit**

```bash
git add Sources/FlightDeck/SessionStore.swift \
        Sources/FlightDeck/Preferences/UI/AccountsSection.swift \
        Tests/FlightDeckTests/AccountSignInTests.swift \
        Tests/FlightDeckTests/FleetAccountEmissionTests.swift
git commit -m "$(cat <<'EOF'
fix: type /login at a signing-in tab instead of renaming its conversation to it

AccountsSection.signIn unwrapped LoginInvocation.inject itself and pushed
it through ClaudeAdapter.injectRename behind an `as? ClaudeAdapter`
downcast. injectRename is the *rename* channel — the store wires it to
injectPendingRename, which queues into pendingRenames and types
"/rename \(name)". `/` is not in ClaudeSession.shellMetacharacters, so
sanitizedName("/login") returns it intact and the tab was eventually sent
`/rename /login`: the conversation got renamed, the account never got
signed in, and any genuine pending rename for that tab was clobbered.

openSignInSession now takes the whole LoginInvocation and owns both
halves — the command it types at the shell and the injection it queues
for the agent. The view loses the downcast entirely; it had no business
knowing which adapter class it was holding, and that downcast is exactly
what dragged the rename channel into a login.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Removing an account tombstones it instead of dropping it

`PreferencesStore.resolvedAccountID` collapses a *deleted* id to `nil`, so dropping the record flips a live tab's `SessionStore.instance(for:)` key from `<id>` to `nil` mid-run. Its existing `statusWatchers[<id>]` / `codexStacks[<id>]` can then no longer be matched for teardown, and the next lookup at the `nil` key builds a **second** codex app-server pointed at the built-in home. That hazard is why removal was blocked at all.

A tombstone retires it by construction: a removed account **still resolves by id**, so the runtime key never moves.

**Files:**
- Modify: `Sources/FlightDeck/Agents/AgentAccount.swift` (`AgentAccount`)
- Modify: `Sources/FlightDeck/Preferences/Preferences.swift` (`accounts(for:)`, `moveAccounts`, new `liveAccounts` + `purgeRemovedAccounts`)
- Modify: `Sources/FlightDeck/Preferences/PreferencesStore.swift` (`init`, `account(for:project:)`, `resolvedAccountID`, `homeIsTaken`, `removeAccount`)
- Modify: `Tests/FlightDeckTests/AccountResolutionTests.swift:78` (`removeAccount` → `markAccountRemoved`)
- Test: `Tests/FlightDeckTests/AccountTombstoneTests.swift` (create)

**Interfaces:**
- Produces: `AgentAccount.removedAt: Date?`, `AgentAccount.isRemoved: Bool`; `Preferences.liveAccounts: [AgentAccount]`, `Preferences.purgeRemovedAccounts()`; `PreferencesStore.markAccountRemoved(id: UUID)` (replaces `removeAccount(id:)`)

- [ ] **Step 1: Write the failing tests**

Create `Tests/FlightDeckTests/AccountTombstoneTests.swift`:

```swift
import XCTest
@testable import FlightDeck

/// Removal is a soft delete. The rules split cleanly in two and this suite pins both halves:
/// a tombstoned account still resolves BY ID (so a live tab's runtime key never moves), and
/// is absent from every LIST and default (so nothing offers it).
@MainActor
final class AccountTombstoneTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func home(_ name: String) -> URL { root.appendingPathComponent(name, isDirectory: true) }

    /// A store holding the built-in claude account plus one ordinary one.
    private func makeStore() -> (PreferencesStore, AgentAccount, AgentAccount) {
        let store = PreferencesStore(persistence: nil)
        let builtIn = AgentAccount(
            agent: .claude, displayName: "Default", home: AgentID.claude.builtInHome
        )
        let work = AgentAccount(agent: .claude, displayName: "Work", home: home("work"))
        store.preferences.storedAccounts = [builtIn, work]
        return (store, builtIn, work)
    }

    /// The invariant the whole design exists for. A tab running as this account keys its
    /// watchers and its codex stack on the resolved id; if removal moved that key, the
    /// existing watchers would be unmatchable and the next lookup would build a SECOND codex
    /// app-server at the nil key, pointed at the wrong home.
    func testATombstonedAccountStillResolvesByID() {
        let (store, _, work) = makeStore()
        store.markAccountRemoved(id: work.id)
        XCTAssertEqual(store.account(id: work.id)?.id, work.id)
        XCTAssertEqual(store.resolvedAccountID(for: .claude, in: work.id), work.id)
    }

    /// A genuinely unknown id still resolves to nothing — the tombstone must not turn every
    /// dangling reference into a live one.
    func testAnUnknownIDStillResolvesToNothing() {
        let (store, _, _) = makeStore()
        XCTAssertNil(store.resolvedAccountID(for: .claude, in: UUID()))
    }

    func testATombstonedAccountLeavesEveryListAndDefault() {
        let (store, builtIn, work) = makeStore()
        store.markAccountRemoved(id: builtIn.id)
        XCTAssertEqual(store.preferences.accounts(for: .claude).map(\.id), [work.id])
        XCTAssertEqual(store.preferences.liveAccounts.map(\.id), [work.id])
        // The topmost fallback for a project that has chosen nothing.
        XCTAssertEqual(store.account(for: .claude, project: root.path)?.id, work.id)
        // And it stops being what a nil `Session.accountID` resolves to.
        XCTAssertEqual(store.resolvedAccountID(for: .claude, in: nil), nil)
    }

    /// The user removed it, so its home is theirs to re-use. Leaving it "taken" would refuse
    /// the obvious recovery from an accidental removal.
    func testATombstonedAccountReleasesItsHome() {
        let (store, _, work) = makeStore()
        XCTAssertTrue(store.homeIsTaken(work.home, excluding: nil))
        store.markAccountRemoved(id: work.id)
        XCTAssertFalse(store.homeIsTaken(work.home, excluding: nil))
    }

    /// Unchanged from hard delete: nothing may be left pointing at an account the user removed.
    func testRemovalStillClearsProjectAssignments() {
        let (store, _, work) = makeStore()
        store.setProjectSettings(root.path, ProjectSettings(accounts: [.claude: work.id]))
        store.markAccountRemoved(id: work.id)
        XCTAssertNil(store.projectSettings(root.path).accounts[.claude])
    }

    /// Reordering writes a reordered live list back into the slots the live accounts hold. If
    /// it wrote into every slot for the agent, a tombstone in the middle would swallow one
    /// entry and shift the rest.
    func testReorderingSkipsTombstonedSlots() {
        let store = PreferencesStore(persistence: nil)
        let a = AgentAccount(agent: .claude, displayName: "A", home: home("a"))
        let dead = AgentAccount(agent: .claude, displayName: "Dead", home: home("dead"))
        let b = AgentAccount(agent: .claude, displayName: "B", home: home("b"))
        store.preferences.storedAccounts = [a, dead, b]
        store.markAccountRemoved(id: dead.id)
        store.preferences.moveAccounts(forAgent: .claude, fromOffsets: IndexSet(integer: 1), toOffset: 0)
        XCTAssertEqual(store.preferences.accounts(for: .claude).map(\.displayName), ["B", "A"])
    }

    /// Tombstones exist only to protect live tabs, and at launch there are none.
    func testTombstonesArePurgedAtLaunch() {
        var preferences = Preferences()
        let live = AgentAccount(agent: .claude, displayName: "Live", home: home("live"))
        var dead = AgentAccount(agent: .claude, displayName: "Dead", home: home("dead"))
        dead.removedAt = Date()
        preferences.storedAccounts = [live, dead]
        preferences.purgeRemovedAccounts()
        XCTAssertEqual(preferences.accounts.map(\.id), [live.id])
    }

    /// Existing stored JSON has no `removedAt` key. Decoding must treat that as live, not fail.
    func testAccountsStoredBeforeTombstonesDecodeAsLive() throws {
        let json = Data("""
        [{"id":"\(UUID().uuidString)","agent":"claude","displayName":"W","home":"file:///tmp/w"}]
        """.utf8)
        let decoded = try JSONDecoder().decode([AgentAccount].self, from: json)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertNil(decoded[0].removedAt)
        XCTAssertFalse(decoded[0].isRemoved)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | rg "AccountTombstoneTests|error:|Executed .* tests"`
Expected: compile errors — no `removedAt`, `isRemoved`, `liveAccounts`, `purgeRemovedAccounts`, or `markAccountRemoved`.

- [ ] **Step 3: Add the tombstone to the model**

In `Sources/FlightDeck/Agents/AgentAccount.swift`, add to `AgentAccount` after `cachedIdentity`:

```swift
    /// When the user removed this account, or nil while it is live.
    ///
    /// Removal is a soft delete because a hard one moves a running tab's identity. A tab keys
    /// its status watcher and its codex stack on `resolvedAccountID`, which answers nil for an
    /// id that no longer exists — so dropping the record mid-run strands those watchers under
    /// a key nothing can match again, and the next lookup builds a SECOND codex app-server at
    /// the nil key, tailing the built-in home's `session_index.jsonl` instead of this one's.
    /// A tombstone still resolves by id, so the key never moves.
    ///
    /// Purged at launch (`Preferences.purgeRemovedAccounts`), where there are no live tabs
    /// left to protect.
    var removedAt: Date?

    /// Reads better than `removedAt != nil` at the call sites that only ask the question.
    var isRemoved: Bool { removedAt != nil }
```

Add `removedAt: Date? = nil` as the final parameter of `init`, and `self.removedAt = removedAt` as the final assignment. The synthesized `Codable` uses `decodeIfPresent` for optional properties, so existing stored JSON decodes unchanged — no migration.

- [ ] **Step 4: Split the list accessors**

In `Sources/FlightDeck/Preferences/Preferences.swift`, replace `accounts(for:)` and `moveAccounts` with:

```swift
    /// One agent's LIVE accounts. Tombstones are filtered here rather than at each caller
    /// because every consumer of this — the Accounts list, the Projects tab's picker,
    /// reordering — is a list the user picks from, and a removed account must appear in none
    /// of them. Lookups BY ID go through `PreferencesStore.account(id:)` instead and must
    /// keep seeing tombstones; see `AgentAccount.removedAt`.
    func accounts(for agent: AgentID) -> [AgentAccount] {
        accounts.filter { $0.agent == agent && !$0.isRemoved }
    }

    /// Every live account, flat. What the "New … Session" menus render — the raw `accounts`
    /// array would offer a login the user has removed.
    var liveAccounts: [AgentAccount] { accounts.filter { !$0.isRemoved } }

    /// Drops every tombstone. Called once at launch, from `PreferencesStore.init`'s migration
    /// chain: tombstones exist only to keep a *running* tab's identity stable, and at launch
    /// there are none left to protect. Nothing else prunes them — one mechanism, not two.
    ///
    /// Cannot resurrect what the user removed: this never sets `storedAccounts` back to nil,
    /// so `migrateAccountsIfNeeded`'s seed-once guard still holds on the next launch.
    mutating func purgeRemovedAccounts() {
        accounts.removeAll { $0.isRemoved }
    }

    /// Reorders one agent's accounts without disturbing any other agent's.
    ///
    /// `accounts` is one flat array, so offsets from a per-agent list cannot be applied to it
    /// directly. This maps them back: pull out this agent's entries, reorder them, then write
    /// them into the positions the flat array already reserved for that agent.
    ///
    /// The write-back filter must match `accounts(for:)`'s exactly, tombstones included. Read
    /// live entries but write into every slot for the agent and the iterator runs dry early:
    /// a tombstone mid-list swallows one entry and shifts every account after it.
    mutating func moveAccounts(forAgent agent: AgentID, fromOffsets source: IndexSet, toOffset destination: Int) {
        var mine = accounts(for: agent)
        mine.move(fromOffsets: source, toOffset: destination)
        var reordered = mine.makeIterator()
        accounts = accounts.map {
            $0.agent == agent && !$0.isRemoved ? (reordered.next() ?? $0) : $0
        }
    }
```

- [ ] **Step 5: Split the store's lookups**

In `Sources/FlightDeck/Preferences/PreferencesStore.swift`:

`account(for:project:)` — both branches must refuse a tombstone, because this answers "what does a NEW session launch as":

```swift
    func account(for agent: AgentID, project: String) -> AgentAccount? {
        if let assigned = preferences.projectSettings[Self.key(project)]?.accounts[agent] {
            // A tombstone here is answered as nil — i.e. BROKEN — rather than by silently
            // falling through to the topmost account, which is the wrong-login bug this
            // method's nil exists to prevent. `markAccountRemoved` clears these assignments,
            // so this is defence in depth rather than a reachable state.
            return account(id: assigned).flatMap { $0.isRemoved ? nil : $0 }
        }
        return preferences.accounts.first { $0.agent == agent && !$0.isRemoved }
    }
```

`resolvedAccountID` — the stored branch is deliberately left alone:

```swift
    func resolvedAccountID(for agent: AgentID, in stored: UUID?) -> UUID? {
        // Unfiltered on purpose: a tombstoned account MUST still resolve here, or a live tab
        // running as it re-keys mid-run. See `AgentAccount.removedAt`.
        if let stored { return account(id: stored)?.id }
        // The nil branch is a default, not a lookup, so it skips tombstones like every other
        // default does.
        return preferences.accounts.first { $0.agent == agent && $0.isBuiltIn && !$0.isRemoved }?.id
    }
```

`homeIsTaken` — a removed account releases its home:

```swift
    func homeIsTaken(_ home: URL, excluding id: UUID?) -> Bool {
        preferences.accounts.contains {
            $0.id != id && !$0.isRemoved && AgentAccount.key($0.home) == AgentAccount.key(home)
        }
    }
```

Replace `removeAccount(id:)` with:

```swift
    /// Tombstones the account AND drops every project assignment naming it, so nothing is left
    /// pointing at a login the user removed. A record emptied by that clearing is removed,
    /// matching how an emptied flag override already drops a project from the list.
    ///
    /// Stamps rather than deletes: see `AgentAccount.removedAt` for the running-tab identity
    /// this protects.
    func markAccountRemoved(id: UUID) {
        guard let index = preferences.accounts.firstIndex(where: { $0.id == id }) else { return }
        preferences.accounts[index].removedAt = Date()
        for (path, var settings) in preferences.projectSettings {
            let before = settings.accounts
            settings.accounts = settings.accounts.filter { $0.value != id }
            guard settings.accounts != before else { continue }
            preferences.projectSettings[path] = settings.isEmpty ? nil : settings
        }
    }
```

In `init`, add the purge immediately after `migrateAccountsIfNeeded()`:

```swift
        migrated.migrateAccountsIfNeeded()
        // After seeding, so "at least one account per agent" already holds, and before
        // anything resolves against the list. In this chain so it participates in the
        // `migrated != loaded` comparison below and reaches disk on the launch that performs
        // it, rather than waiting for the user's next preference edit.
        migrated.purgeRemovedAccounts()
```

- [ ] **Step 6: Update the one existing caller**

In `Tests/FlightDeckTests/AccountResolutionTests.swift:78`, change `store.removeAccount(id: doomed.id)` to `store.markAccountRemoved(id: doomed.id)`. That test asserts a *dangling* id resolves to nothing; if it now fails because the tombstone resolves, replace the removal with `store.preferences.accounts.removeAll { $0.id == doomed.id }` so it keeps testing a genuinely absent account — read the test first and pick whichever matches its stated intent.

Then audit the two comments that name the old method — `SessionStore.swift:445` and `AccountLaunchTests.swift:287` both say "`removeAccount` clears…" — and update the name.

- [ ] **Step 7: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | rg "AccountTombstone|AccountResolution|error:|failed|Executed .* tests"`
Expected: PASS, whole suite green.

- [ ] **Step 8: Commit**

```bash
git add Sources/FlightDeck/Agents/AgentAccount.swift \
        Sources/FlightDeck/Preferences/Preferences.swift \
        Sources/FlightDeck/Preferences/PreferencesStore.swift \
        Sources/FlightDeck/SessionStore.swift \
        Tests/FlightDeckTests/AccountTombstoneTests.swift \
        Tests/FlightDeckTests/AccountResolutionTests.swift \
        Tests/FlightDeckTests/AccountLaunchTests.swift
git commit -m "$(cat <<'EOF'
feat: tombstone a removed account so a tab running as it keeps its identity

Hard deletion moves a running tab's identity. resolvedAccountID answers
nil for an id that no longer exists, so dropping the record flips
SessionStore.instance(for:) from <id> to nil mid-run: the tab's existing
statusWatchers[<id>] and codexStacks[<id>] stop being matchable by
stopStatusWatchingIfUnused / stopCodexIfUnused, and the next lookup
builds a SECOND codex app-server at the nil key, tailing the built-in
home's session_index.jsonl. That hazard is the reason removal was blocked
for any account with a live session at all.

A tombstone retires it by construction: removedAt is stamped, the record
stays, and the account still resolves BY ID — so the runtime key never
moves. Lists and defaults filter it out instead: accounts(for:), the
topmost fallback, the nil-accountID built-in fallback, and homeIsTaken
(a removed home is the user's to re-use again).

moveAccounts had to learn the same filter. It reads the live list and
writes back into slots; writing into every slot for the agent while
reading only live ones runs the iterator dry, so a tombstone mid-list
would swallow an entry and shift every account after it.

Purged at launch, where there are no live tabs left to protect. The purge
never nils storedAccounts, so migrateAccountsIfNeeded's seed-once guard
still holds and nothing the user removed comes back.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Both New Session menus drop a tombstoned account

The File menu (`SessionCommands.swift:106`) and the sidebar dropdown (`SessionSidebar.swift:459`) each feed the raw flat `preferences.preferences.accounts` into `NewSessionAffordance.menu`, so a removed login would keep appearing in "New … Session".

**Files:**
- Modify: `Sources/FlightDeck/SessionCommands.swift:106`
- Modify: `Sources/FlightDeck/SessionSidebar.swift:459`
- Test: `Tests/FlightDeckTests/AccountTombstoneTests.swift` (extend)

**Interfaces:**
- Consumes: `Preferences.liveAccounts` (Task 4)

- [ ] **Step 1: Write the failing test**

Append to `Tests/FlightDeckTests/AccountTombstoneTests.swift` (inside the class):

```swift
    /// Both "New … Session" menus build from `liveAccounts`. Two live accounts nest into a
    /// submenu; tombstoning one drops the agent back to a single flat row — and
    /// `NewSessionAffordance.chords` moves the agent's chord onto it, so no shortcut is lost.
    func testTombstonedAccountsLeaveTheNewSessionMenus() {
        let store = PreferencesStore(persistence: nil)
        let work = AgentAccount(agent: .claude, displayName: "Work", home: home("work"))
        let personal = AgentAccount(agent: .claude, displayName: "Personal", home: home("personal"))
        store.preferences.storedAccounts = [work, personal]
        let agents = [AgentSettings(id: .claude, options: .claude(FlagSet()))]

        let before = NewSessionAffordance.menu(
            agents: agents, accounts: store.preferences.liveAccounts,
            resolved: [.claude: work.id]
        )
        guard case .submenu(_, let rows) = before.first else {
            return XCTFail("two live accounts should nest, got \(String(describing: before.first))")
        }
        XCTAssertEqual(rows.count, 2)

        store.markAccountRemoved(id: personal.id)
        let after = NewSessionAffordance.menu(
            agents: agents, accounts: store.preferences.liveAccounts,
            resolved: [.claude: work.id]
        )
        XCTAssertEqual(after, [.agent(.claude, account: work.id, isResolved: true)])
        XCTAssertEqual(NewSessionAffordance.chords(for: after, agents: agents)[work.id], [.command])
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./scripts/test-unit.sh 2>&1 | rg "AccountTombstoneTests|error:|failed|Executed .* tests"`
Expected: FAIL — with `accounts` unfiltered at the call sites this test would pass trivially, so if it passes, confirm you used `liveAccounts` in the test body and that Task 4 landed. If `AgentSettings(id:options:)` does not compile, read `Sources/FlightDeck/Preferences/AgentSettings.swift` and use its real initializer.

- [ ] **Step 3: Point both menus at the live list**

In `Sources/FlightDeck/SessionCommands.swift:106` and `Sources/FlightDeck/SessionSidebar.swift:459`, change:

```swift
                    agents: agents, accounts: preferences.preferences.accounts,
```

to:

```swift
                    agents: agents, accounts: preferences.preferences.liveAccounts,
```

In `SessionSidebar.swift` the surrounding call is indented differently — match the existing indentation rather than copying the snippet's.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | rg "AccountTombstoneTests|error:|failed|Executed .* tests"`
Expected: PASS, whole suite green.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionCommands.swift Sources/FlightDeck/SessionSidebar.swift \
        Tests/FlightDeckTests/AccountTombstoneTests.swift
git commit -m "$(cat <<'EOF'
fix: drop removed accounts from both New Session menus

The File menu and the sidebar dropdown each fed the raw flat accounts
array into NewSessionAffordance.menu, so a tombstoned login kept its row
and could still be launched. Both now read liveAccounts.

The nesting knock-on is already handled and is what we want: menu()
nests into a submenu only above one account, so removing one of two
un-nests that agent back to a flat row and chords() moves the agent's
chord onto it. No shortcut is dropped.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 6: The `−` button refuses only an agent's last account — and Relocate keeps the old guard

`AccountsSection.canRemove` today refuses the built-in account and any account with a live tab. Both clauses go; the new rule is "another live account exists for this agent."

**This task carries a correction to the spec.** `canRemove` is *also* what gates `Relocate…` (`AccountsSection.swift:241` and inside `relocate()` at `:276`). Relocating is a genuinely different act from removing — it moves the home directory out from under a running agent whose already-forked shell still points at the old path, and relocating the *built-in* account makes `isBuiltIn` false, breaking what a nil `Session.accountID` resolves to. So Relocate keeps the old rule under its own name; only the `−` button gets the new one.

**Files:**
- Modify: `Sources/FlightDeck/Preferences/UI/AccountsSection.swift` (`canRemove`, new `canRelocate`, `remove`, `deleteFiles`, and the three call sites)
- Modify: `Tests/FlightDeckTests/AccountsSectionTests.swift` (six tests change meaning)

**Interfaces:**
- Consumes: `AgentAccount.isRemoved`, `PreferencesStore.markAccountRemoved` (Task 4)
- Produces: `AccountsSection.canRemove(_ account: AgentAccount, among live: [AgentAccount]) -> Bool`; `AccountsSection.canRelocate(_ account: AgentAccount, boundAccountIDs: Set<UUID>) -> Bool`; `AccountsSection.remove(accountID: UUID, in: PreferencesStore) -> Bool`; `AccountsSection.deleteFiles(accountID: UUID, in: PreferencesStore, trash:) -> Bool`

- [ ] **Step 1: Rewrite the affected tests**

In `Tests/FlightDeckTests/AccountsSectionTests.swift`, replace `testTheBuiltInAccountCannotBeRemoved` and `testAnAccountWithLiveSessionsCannotBeRemovedOrRelocated` with:

```swift
    /// The built-in account is removable like any other now. It is not special — it is simply
    /// what a nil `Session.accountID` resolves to, and a tombstone keeps resolving.
    func testTheBuiltInAccountCanBeRemovedWhenAnotherAccountRemains() {
        let builtIn = AgentAccount(agent: .claude, displayName: "D", home: AgentID.claude.builtInHome)
        let work = AgentAccount(agent: .claude, displayName: "W", home: temporary("w"))
        XCTAssertTrue(AccountsSection.canRemove(builtIn, among: [builtIn, work]))
    }

    /// The one refusal left: there must always be at least one account per agent.
    func testAnAgentsLastAccountCannotBeRemoved() {
        let only = AgentAccount(agent: .claude, displayName: "D", home: AgentID.claude.builtInHome)
        XCTAssertFalse(AccountsSection.canRemove(only, among: [only]))
    }

    /// Live sessions no longer refuse removal — they only change the warning. A tombstone
    /// keeps the account resolvable, so those tabs keep their identity.
    func testAnAccountWithLiveSessionsCanStillBeRemoved() {
        let work = AgentAccount(agent: .claude, displayName: "W", home: temporary("w"))
        let other = AgentAccount(agent: .claude, displayName: "O", home: temporary("o"))
        XCTAssertTrue(AccountsSection.canRemove(work, among: [work, other]))
    }

    /// Relocating is NOT removing, and keeps the old guard. Moving a home out from under a
    /// running agent leaves its already-forked shell pointed at the old path, and relocating
    /// the built-in account makes `isBuiltIn` false — which changes what a nil
    /// `Session.accountID` resolves to.
    func testRelocateStillRefusesTheBuiltInAccountAndLiveSessions() {
        let builtIn = AgentAccount(agent: .claude, displayName: "D", home: AgentID.claude.builtInHome)
        let work = AgentAccount(agent: .claude, displayName: "W", home: temporary("w"))
        XCTAssertFalse(AccountsSection.canRelocate(builtIn, boundAccountIDs: []))
        XCTAssertFalse(AccountsSection.canRelocate(work, boundAccountIDs: [work.id]))
        XCTAssertTrue(AccountsSection.canRelocate(work, boundAccountIDs: []))
    }
```

Then update the four `remove`/`deleteFiles` tests to the new signatures and meanings:

- `testDeleteFilesTrashesTheAccountsOwnHomeForAnOrdinaryAccount` (`:69`) — drop the `boundAccountIDs: []` argument.
- `testDeleteFilesRefusesTheBuiltInAccount` (`:85`) — rename to `testDeleteFilesRefusesAnAgentsLastAccount` and seed a store holding *only* that account; assert `false` and that the home still exists.
- `testDeleteFilesRefusesAnAccountWithLiveSessions` (`:101`) — rename to `testDeleteFilesIsPermittedWithLiveSessions`, seed a second account, assert `true`. Add the comment: live sessions warn, they do not refuse; see the accepted risk in the spec.
- `testRemoveDropsAnOrdinaryAccount` (`:197`) — drop `boundAccountIDs:`, and assert the account is *tombstoned*, not gone: `XCTAssertTrue(store.account(id: work.id)?.isRemoved == true)` and `XCTAssertTrue(store.preferences.accounts(for: .claude).allSatisfy { $0.id != work.id })`.
- `testRemoveRefusesAnAccountABoundSessionAcquiredWhileTheDialogWasOpen` (`:209`) — rename to `testRemoveRefusesAnAgentsLastAccountEvenIfTheDialogWasAlreadyOpen`, seed a store with one account, assert `false`.
- `testRemoveRefusesTheBuiltInAccount` (`:218`) — delete; superseded by the last-account test above.
- `testRemoveRefusesAnAccountThatIsAlreadyGone` (`:227`) — drop `boundAccountIDs:`; still asserts `false` for an unknown UUID.
- `testASessionStoringNoAccountCountsAsBoundToTheBuiltInAccount` (`:237`) — the two `canRemove`/`remove` assertions no longer apply to this test's subject. Keep the `boundAccountIDs` assertion (it still binds the built-in id) and delete lines `:245-246`.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | rg "AccountsSectionTests|error:|Executed .* tests"`
Expected: compile errors — no `among:` overload, no `canRelocate`, and `remove`/`deleteFiles` still demand `boundAccountIDs:`.

- [ ] **Step 3: Replace the predicates**

In `Sources/FlightDeck/Preferences/UI/AccountsSection.swift`, replace `canRemove` with both predicates:

```swift
    /// What the `−` button gates on: is there another live account for this agent to fall
    /// back to.
    ///
    /// The only refusal left. Removal used to also refuse the built-in account and any account
    /// with a live tab — the first because a nil `Session.accountID` resolves to it, the
    /// second because dropping a record moved a running tab's runtime key. Tombstoning
    /// (`AgentAccount.removedAt`) answers both: a removed account still resolves by id, so
    /// neither the legacy tabs nor the running ones lose their identity. What remains is the
    /// one rule that is about the user rather than the machinery — an agent with no accounts
    /// at all has nothing to launch.
    ///
    /// `live` is the agent's already-filtered list (`Preferences.accounts(for:)`), so a
    /// tombstone can never count as the sibling that licenses a removal.
    static func canRemove(_ account: AgentAccount, among live: [AgentAccount]) -> Bool {
        live.contains { $0.id != account.id && !$0.isRemoved }
    }

    /// What `Relocate…` gates on — deliberately NOT `canRemove`'s rule, though it used to be
    /// the same predicate.
    ///
    /// Relocating is not removing. It moves the home directory itself, and a tab already
    /// running as this account has a forked shell whose `CLAUDE_CONFIG_DIR` still names the
    /// old path — so its watchers would follow the new home and see nothing. Relocating the
    /// built-in account is worse than useless: `isBuiltIn` is computed from the home, so
    /// moving it changes what a nil `Session.accountID` resolves to for every legacy tab.
    static func canRelocate(_ account: AgentAccount, boundAccountIDs: Set<UUID>) -> Bool {
        !account.isBuiltIn && !boundAccountIDs.contains(account.id)
    }
```

- [ ] **Step 4: Re-point the static guards**

Replace `remove` and `deleteFiles`. Both lose `boundAccountIDs` and re-check the last-account rule against the store:

```swift
    /// The full guard chain the `−` button's confirmation must clear immediately before it
    /// acts — not only what disables the button, because the dialog can sit open while the
    /// account list changes underneath it.
    @MainActor
    @discardableResult
    static func remove(accountID: UUID, in store: PreferencesStore) -> Bool {
        guard let account = store.account(id: accountID), !account.isRemoved,
              canRemove(account, among: store.preferences.accounts(for: account.agent))
        else { return false }
        store.markAccountRemoved(id: accountID)
        return true
    }

    /// The full guard chain "Also Delete Files…" must clear immediately before it touches the
    /// filesystem. Re-reads the account fresh from `store` by id rather than trusting whatever
    /// `AgentAccount` value the caller is holding, so a relocate that raced the confirm dialog
    /// can never trash a since-abandoned home; `trash` always receives that freshly-read
    /// `account.home` and nothing else. Defaults `trash` to the real Trash so production call
    /// sites need not know this exists; tests substitute a spy to stay hermetic.
    ///
    /// Live sessions no longer refuse this. That is deliberate and is the accepted cost of "the
    /// button is never disabled": the second dialog names the sessions instead. See the spec's
    /// §3g.
    @MainActor
    @discardableResult
    static func deleteFiles(
        accountID: UUID, in store: PreferencesStore,
        trash: (URL) throws -> Void = { try FileManager.default.trashItem(at: $0, resultingItemURL: nil) }
    ) -> Bool {
        guard let account = store.account(id: accountID), !account.isRemoved,
              canRemove(account, among: store.preferences.accounts(for: account.agent))
        else { return false }
        do {
            try trash(account.home)
        } catch {
            return false
        }
        return true
    }
```

- [ ] **Step 5: Update the three call sites in the view body**

The `−` button's `.disabled` modifier (~`:139`):

```swift
                .disabled(!(selectedAccount.map { Self.canRemove($0, among: accounts) } ?? false))
```

The `Relocate…` menu item (~`:241`) and `relocate()`'s own guard (~`:276`) both change `Self.canRemove(account, boundAccountIDs: boundAccountIDs)` to `Self.canRelocate(account, boundAccountIDs: boundAccountIDs)`.

The two confirmation-dialog buttons drop their `boundAccountIDs:` arguments:

```swift
                AccountsSection.remove(accountID: account.id, in: preferences)
```

```swift
                if AccountsSection.deleteFiles(accountID: account.id, in: preferences) {
                    preferences.markAccountRemoved(id: account.id)
                }
```

`boundAccountIDs` itself stays — Task 7 uses it for the warning copy, and `canRelocate` still takes it.

- [ ] **Step 6: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | rg "AccountsSectionTests|error:|failed|Executed .* tests"`
Expected: PASS, whole suite green.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/Preferences/UI/AccountsSection.swift \
        Tests/FlightDeckTests/AccountsSectionTests.swift
git commit -m "$(cat <<'EOF'
feat: enable the remove button for every account except an agent's last one

canRemove refused the built-in account and any account with a live tab.
Both clauses existed to protect identity — the first because a nil
Session.accountID resolves to the built-in account, the second because
hard deletion moved a running tab's runtime key — and tombstoning answers
both, since a removed account still resolves by id. What is left is the
one rule that is about the user rather than the machinery: an agent with
no accounts has nothing to launch.

Relocate keeps the OLD guard under its own name. It was sharing
canRemove, but relocating is not removing: it moves the home directory
while a running tab's already-forked shell still names the old path, and
relocating the built-in account makes isBuiltIn false, changing what
every legacy nil-accountID tab resolves to.

remove() and deleteFiles() lose their boundAccountIDs parameter and
re-check the last-account rule against the store instead, keeping the
"the dialog can sit open while the list changes" property they already
had. deleteFiles is now reachable with live sessions; that is the
accepted cost of the button never being disabled, and task 7 makes the
dialog say so.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

### Task 7: The dialogs warn about permanence and about live sessions

**Files:**
- Modify: `Sources/FlightDeck/Preferences/UI/AccountsSection.swift` (two `.confirmationDialog` message closures, new copy helpers)
- Modify: `Tests/FlightDeckTests/AccountsSectionTests.swift` (extend)

**Interfaces:**
- Consumes: `AccountsSection.boundAccountIDs(in:resolvedBy:)` (existing)
- Produces: `AccountsSection.boundSessionCount(for: AgentAccount, in: [Session], resolvedBy: PreferencesStore) -> Int`; `AccountsSection.removalWarning(for: AgentAccount, boundSessions: Int) -> String`; `AccountsSection.fileDeleteWarning(for: AgentAccount, boundSessions: Int) -> String`

- [ ] **Step 1: Write the failing tests**

Append to `Tests/FlightDeckTests/AccountsSectionTests.swift` (inside the class):

```swift
    /// Permanence is stated whether or not sessions are running; the sessions sentence is
    /// added only when there are any, so the common case is not padded with "0 sessions".
    func testTheRemovalWarningStatesPermanenceAndNamesLiveSessions() {
        let work = AgentAccount(agent: .claude, displayName: "W", home: temporary("w"))
        let quiet = AccountsSection.removalWarning(for: work, boundSessions: 0)
        XCTAssertTrue(quiet.contains("can't be undone"))
        XCTAssertTrue(quiet.contains(work.home.path))
        XCTAssertFalse(quiet.contains("session"))

        let busy = AccountsSection.removalWarning(for: work, boundSessions: 2)
        XCTAssertTrue(busy.contains("2 open sessions"))
        XCTAssertTrue(busy.contains("keep running"))
    }

    /// One session is "1 open session", not "1 open sessions".
    func testTheWarningPluralisesASingleSession() {
        let work = AgentAccount(agent: .claude, displayName: "W", home: temporary("w"))
        XCTAssertTrue(AccountsSection.removalWarning(for: work, boundSessions: 1).contains("1 open session "))
    }

    /// The destructive dialog says what is actually lost, and repeats the live-session warning
    /// — this is the one that trashes an OAuth token out from under a running agent.
    func testTheFileDeleteWarningNamesCredentialsAndTranscripts() {
        let work = AgentAccount(agent: .claude, displayName: "W", home: temporary("w"))
        let text = AccountsSection.fileDeleteWarning(for: work, boundSessions: 1)
        XCTAssertTrue(text.contains("credentials"))
        XCTAssertTrue(text.contains("transcripts"))
        XCTAssertTrue(text.contains("Trash"))
        XCTAssertTrue(text.contains("1 open session"))
    }

    /// Counted through the same resolution the removal guards use, so a legacy tab storing no
    /// account is counted against the built-in account it actually runs as.
    func testBoundSessionsAreCountedThroughResolution() {
        let store = PreferencesStore(persistence: nil)
        let builtIn = AgentAccount(agent: .claude, displayName: "D", home: AgentID.claude.builtInHome)
        store.preferences.storedAccounts = [builtIn]
        let legacy = Session(title: "s", workingDirectory: "/tmp", agent: .claude, accountID: nil)
        XCTAssertEqual(
            AccountsSection.boundSessionCount(for: builtIn, in: [legacy], resolvedBy: store), 1
        )
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `./scripts/test-unit.sh 2>&1 | rg "AccountsSectionTests|error:|Executed .* tests"`
Expected: compile errors — no `removalWarning`, `fileDeleteWarning`, or `boundSessionCount`.

- [ ] **Step 3: Add the copy helpers**

In `Sources/FlightDeck/Preferences/UI/AccountsSection.swift`, add beside the other statics:

```swift
    /// How many open tabs are running as this account, counted through the same resolution
    /// `boundAccountIDs` uses — so a legacy tab storing no account is counted against the
    /// built-in account it actually runs as, not against nothing.
    @MainActor
    static func boundSessionCount(
        for account: AgentAccount, in sessions: [Session], resolvedBy store: PreferencesStore
    ) -> Int {
        sessions.filter { store.resolvedAccountID(for: $0.agent, in: $0.accountID) == account.id }.count
    }

    /// The live-sessions sentence, or nothing when there are none. Separate from the two
    /// warnings below because both need it and neither should pad the common case with a
    /// "0 sessions" clause.
    private static func liveSessionsClause(_ count: Int) -> String {
        guard count > 0 else { return "" }
        let noun = count == 1 ? "1 open session " : "\(count) open sessions "
        return "\n\n\(noun)signed in to this account will keep running, but Flight Deck will "
            + "no longer offer this login."
    }

    /// The `−` button's confirmation. States permanence — removal is not re-seeded on the next
    /// launch — and that the directory itself is untouched, which is what separates this from
    /// the destructive button beside it.
    static func removalWarning(for account: AgentAccount, boundSessions: Int) -> String {
        "This can't be undone. The directory at \(account.home.path) is left in place."
            + liveSessionsClause(boundSessions)
    }

    /// The separately-confirmed destructive action. Names what is actually in that directory,
    /// because "delete files" undersells an OAuth credential and every transcript for a login.
    static func fileDeleteWarning(for account: AgentAccount, boundSessions: Int) -> String {
        "The credentials and transcripts at \(account.home.path) will be moved to the Trash. "
            + "This can't be undone from Flight Deck."
            + liveSessionsClause(boundSessions)
    }
```

- [ ] **Step 4: Use them in the two dialogs**

Add a helper on the view beside `boundAccountIDs`:

```swift
    private func boundSessions(for account: AgentAccount) -> Int {
        Self.boundSessionCount(
            for: account, in: sessions.repos.flatMap(\.sessions), resolvedBy: preferences
        )
    }
```

Replace the first dialog's message closure:

```swift
        } message: { account in
            Text(AccountsSection.removalWarning(for: account, boundSessions: boundSessions(for: account)))
        }
```

and the second's:

```swift
        } message: { account in
            Text(AccountsSection.fileDeleteWarning(for: account, boundSessions: boundSessions(for: account)))
        }
```

Then update the second dialog's block comment above it — it currently says the destructive button "is never reached by the default button" and describes guards that no longer include live sessions. Rewrite it to state the accepted risk: this is now reachable while sessions are live, the wording is the mitigation, and that follows from the button never being disabled.

- [ ] **Step 5: Run the tests to verify they pass**

Run: `./scripts/test-unit.sh 2>&1 | rg "AccountsSectionTests|error:|failed|Executed .* tests"`
Expected: PASS, whole suite green.

- [ ] **Step 6: Verify in the real app**

Build and launch **in place** — never by swapping `/Applications`:

```bash
./scripts/build.sh
open "DerivedData/Build/Products/Debug/Flight Deck.app"
```

In the running app: open Settings → Agents. Confirm the `−` button is enabled for a non-last account, that its dialog states permanence, and that with a tab open on that account the dialog names the session. Then add an account and click "Sign In Now": the new tab must **run** `claude` (not merely display it), and `/login` must be typed into the input bar once the agent is idle. Confirm the removed account is gone from both the File → New Claude Session menu and the sidebar's `+` dropdown.

- [ ] **Step 7: Commit**

```bash
git add Sources/FlightDeck/Preferences/UI/AccountsSection.swift \
        Tests/FlightDeckTests/AccountsSectionTests.swift
git commit -m "$(cat <<'EOF'
feat: warn that removing an account is permanent and name the sessions it affects

The remove dialogs described guards that no longer exist. Both now state
permanence outright, and both add a sentence naming the open sessions
running as the account when there are any — counted through the same
resolution the guards use, so a legacy tab storing no account is counted
against the built-in account it actually runs as.

The destructive dialog also names what is in the directory. "Delete
files" undersells an OAuth credential and every transcript for a login,
and this is now reachable while sessions are live — the accepted cost of
the button never being disabled, with the wording as the mitigation.

Copy lives in static functions rather than inline in the view body for
the reason every other rule in this pane does: a SwiftUI body cannot be
unit tested, and the pluralisation and the omit-when-zero rule can.

Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>
EOF
)"
```

---

## Self-review notes

- **Spec coverage.** §1 → Task 1. §2a/2b → Tasks 2–3. §3a/3b/3c/3e/3f → Task 4. §3d → Task 5. §3 opening + guards → Task 6. §3g → Task 7.
- **Two corrections to the spec, both carried above.** (a) `canRemove` also gates `Relocate…`; the spec did not say so, and reusing the new rule there would let a relocate move a home out from under a running agent. Task 6 splits `canRelocate` off with the old rule. (b) `Preferences.moveAccounts` reads `accounts(for:)` and writes back into slots; filtering the read without filtering the write runs the iterator dry and shifts accounts past a tombstone. Task 4 Step 4 fixes it.
- **Type consistency.** `terminated(_:)`, `DeferredPrompt`, `pendingPrompts`, `liveAccounts`, `purgeRemovedAccounts`, `markAccountRemoved`, `isRemoved`, `canRemove(_:among:)`, `canRelocate(_:boundAccountIDs:)`, `boundSessionCount`, `removalWarning`, `fileDeleteWarning` are each defined once and referenced under exactly that name.
