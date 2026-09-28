# Codex control-socket access Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Let codex tabs reach the `flightdeck` control socket without widening their network
access, and make `flightdeck` say why when a sandbox blocks it.

**Architecture:** Codex only allowlists a unix socket inside its sandbox through its managed
network proxy (`network_proxy` feature) plus a permissions profile with `network.enabled=true` and
`network.unix_sockets = {"<dir>"="allow"}`. Flight Deck appends those flags to the
`codex`/`codex resume` lines it types into a codex tab. The CLI maps a sandbox refusal to exit 77.

**Tech Stack:** Swift 5 (app, CLI), XCTest, codex-cli 0.155.1.

**Spec:** the approved design is at `/Users/nate/.claude/plans/vivid-cuddling-hearth.md`. Its
evidence table is below, so no one has to reproduce it.

| Probe (codex-cli 0.155.1, echo server in `~/Library/Application Support/Flight Deck/`) | Socket | Internet |
|---|---|---|
| default `:workspace` / `:read-only` | EPERM | blocked |
| `codex sandbox --enable network_proxy` + profile `network.enabled=true` + `unix_sockets` map allow | connects | blocked |
| same without the `unix_sockets` entry (control) | EPERM | blocked |
| `features.network_proxy.unix_sockets` on a built-in profile | EPERM | — |
| live `codex exec` turn with the five flags below | connects | blocked, no approval prompt |

The five flags, in this order:
```
--enable network_proxy
-c 'default_permissions="flightdeck"'
-c 'permissions.flightdeck.extends=":workspace"'
-c 'permissions.flightdeck.network.enabled=true'
-c 'permissions.flightdeck.network.unix_sockets={"<STATE DIR>"="allow"}'
```

## Global Constraints

- Work only in `/Users/nate/Projects/Protos-n-Tools/flight-deck/.claude/worktrees/codex-control-access`
  (branch `worktree-codex-control-access`). Never commit anything under `vendor/`.
- `./scripts/test-unit.sh` always runs the full suite (~2 min here). Run it in the FOREGROUND.
  Never run `smoke.sh`. Never launch any `.app`.
- `./scripts/test-codex-live.sh` is NOT hermetic. It spawns real codex, and one existing test
  costs tokens. Run it at most ONCE, in Task 3 only.
- Quote shell arguments with the existing `ClaudeSession.shellQuoted(_:)`
  (Sources/FlightDeck/ClaudeSession.swift:92). Do not add a second quoting helper.
- Profile name: `flightdeck`. CLI exit code for a sandbox refusal: `77` (EX_NOPERM).
- TDD: RED first. Comments explain WHY. Commits are lowercase and imperative, with the trailer
  `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Review Focus

1. **A user who chose a codex sandbox in Flight Deck's preferences** (`CodexThreadOptions.sandbox`
   set) must get NO injected flags. Codex rejects `sandbox_mode` + `default_permissions`
   together, and the tab would fail to start. Test: Task 1,
   `testNoFlagsWhenTheUserChoseASandbox`.
2. **A state dir path with spaces or quotes** (the default contains "Application Support") must
   survive shell quoting and TOML quoting together. Test: Task 1,
   `testAPathWithSpacesAndQuotesIsQuotedForShellAndToml`.
3. **Control socket disabled:** no flags, and codex launches exactly as before. Test: Task 1.
4. **A sandbox refusal is not "cannot reach":** EPERM/EACCES before ready gives 77 and the
   sandbox message, never 69. Test: Task 2.
5. **A future codex drops or renames the mechanism:** the Task 3 live guard fails loudly.

---

### Task 1: Inject the control-socket grant into codex launch lines

**Files:**
- Create: `Sources/FlightDeck/Agents/Codex/CodexControlAccess.swift`
- Modify: `Sources/FlightDeck/Agents/Codex/CodexAdapter.swift` (`launchCommand` ~325,
  `resumeCommand`, and the fresh `codex\n` fallback in `coldCreateCommand` ~346)
- Modify: `Sources/FlightDeck/SessionStore.swift`. `controlSocket` (~1095) is set by FlightDeckApp,
  and the codex adapter must learn it (the adapter is built at ~421).
- Test: `Tests/FlightDeckTests/CodexControlAccessTests.swift` (new), plus launch-line cases in the
  existing codex launch tests (see `Tests/FlightDeckTests/CodexOptionsRoutingTests.swift` /
  `CodexLaunchFailureTests.swift` for how a `CodexAdapter` is built in tests).

**Interfaces:**
- Produces: `enum CodexControlAccess { static func launchFlags(socket: URL?, options: CodexThreadOptions) -> [String] }`,
  and `CodexAdapter.controlSocket: URL?` (a stored var, nil by default).

- [ ] Step 1: write the failing tests.
  - `launchFlags(socket: URL(fileURLWithPath: "/s/Flight Deck/control.sock"), options: CodexThreadOptions())`
    returns exactly the five flags, in order, as separate array elements:
    - `--enable`, `network_proxy`
    - `-c`, then the quoted `default_permissions="flightdeck"`
    - and so on through the other three.
    - The unix-socket key is the socket's **parent directory** (`/s/Flight Deck`).
    - Each `-c` value is passed through `ClaudeSession.shellQuoted`, so it is one shell word.
    - Assert the exact strings.
  - `testNoFlagsWhenTheUserChoseASandbox`: `options.sandbox = "workspace-write"` returns `[]`.
    Repeat for `"danger-full-access"`.
  - `socket: nil` returns `[]`.
  - `testAPathWithSpacesAndQuotesIsQuotedForShellAndToml`, directory `/s/it's "odd"/x`:
    1. Run the produced `-c` value through `/bin/sh -c 'printf %s "$1"' _ <value>` (use
       `Process`), or unquote it by hand.
    2. Parse the resulting `key=value`. The value must be a valid TOML inline table
       `{"<dir>"="allow"}`, with `"` and `\` escaped per TOML basic-string rules.
    3. Write the TOML escaping inside `CodexControlAccess`. It is a small helper, private to that
       file.
  - Adapter: with `controlSocket` set and default options, `launchCommand` gives
    `codex resume <id> <flags joined by space>\n`. The same holds for `resumeCommand`, and for
    the `coldCreateCommand` fresh-launch branch (`codex <flags>\n`). With `controlSocket == nil`,
    each line is byte-identical to today's.
- [ ] Step 2: run `./scripts/test-unit.sh` and confirm RED (a build failure for the missing
  symbols counts).
- [ ] Step 3: implement.
  - `CodexControlAccess`. Its doc comment carries:
    - the probe table, condensed;
    - why the allowlist exists only through the proxy (`codex-rs sandboxing/src/seatbelt.rs`
      `proxy_policy_inputs`);
    - that `network_proxy` is experimental in 0.155.1, pinned by the Task 3 live test;
    - why an explicit sandbox skips injection (`codex-rs core/src/config/mod.rs`:
      "`sandbox_mode` and `default_permissions` overrides cannot both be set").
  - `CodexAdapter.controlSocket` plus the three launch lines.
  - In SessionStore, make `controlSocket`'s `didSet` (or the existing adapter wiring, whichever the
    code already uses) push the URL onto the codex adapter, so a socket set after the adapter
    exists still reaches it. Check both orders in a test.
- [ ] Step 4: run `./scripts/test-unit.sh` (foreground) and confirm GREEN.
- [ ] Step 5: commit with `feat: let codex tabs reach the flightdeck control socket`.

---

### Task 2: Report a sandbox refusal as exit 77, not "cannot reach"

**Files:**
- Modify: `Sources/FlightDeckCLI/CLIRunner.swift` (`disconnected(_:)` ~150-160; the 69 path)
- Modify: `Sources/FlightDeckTool/main.swift` (the finish handler prints the 69 message ~88;
  add the 77 message) and `usageLines` (document exit codes if they are listed)
- Test: `Tests/FlightDeckTests/CLIRunnerTests.swift`

- [ ] Step 1: write the failing tests (FakeTransport has `onDisconnect`).
  - Run `ls`, then call `onDisconnect(NWError.posix(.EPERM))` before any ready or frame. Expect
    `code == 77`.
  - The same with `.EACCES` gives 77.
  - `onDisconnect(nil)` or `NWError.posix(.ENOENT)` before ready still gives 69.
  - For `tail`, a 77 must be final: no reconnect is scheduled. A sandbox refusal will not heal
    on retry.
- [ ] Step 2: confirm RED.
- [ ] Step 3: implement.
  - `import Network` in CLIRunner. The Network framework is allowed; the rule is only no AppKit
    and no FlightDeck module.
  - Classify the error: `NWError.posix(let code)` where the code is `.EPERM` or `.EACCES` means
    sandbox-denied. Also accept a `POSIXError` with those codes, if FleetClient can surface one.
  - `finish(77)`.
  - In main.swift, for 77 print exactly:
    ```
    flightdeck: the agent's sandbox blocked the control socket at <path>
    flightdeck: codex tabs opened by Flight Deck are granted it; reopen a tab that predates this, or one run with an explicit sandbox mode
    ```
  - Add `77` to any exit-code list in `usageLines` / `docs/HANDOFF.md` / `docs/ARCHITECTURE.md`
    that lists 69.
- [ ] Step 4: `./scripts/test-unit.sh` GREEN.
- [ ] Step 5: commit with `fix: tell a sandboxed agent why flightdeck cannot reach the app`.

---

### Task 3: Live guard, headless end-to-end check, docs

**Files:**
- Modify: `Tests/FlightDeckTests/CodexIntegrationTests.swift` (runs only under
  `./scripts/test-codex-live.sh`)
- Modify: `docs/ARCHITECTURE.md` (local control socket section), `docs/HANDOFF.md`, `docs/FOLLOWUPS.md`

- [ ] Step 1: add `testControlSocketGrantConnectsWithoutOpeningTheInternet` to
  CodexIntegrationTests.
  1. Stand up a unix echo server in a short temp dir (`/tmp/fdcx-<8 hex>/`); use a tiny Swift or
     `python3` server.
  2. Build the flags with `CodexControlAccess.launchFlags(socket: <tmp>/control.sock, options: .init())`.
  3. Run `codex sandbox <the same --enable/-c flags, unquoted as argv> -P flightdeck -C <tmp> -- python3 -c '<connect+echo>'`.
     `codex sandbox` takes `-P <profile>` where the TUI takes `default_permissions`; pass both
     the `-c` flags and `-P flightdeck`.
  4. Assert it echoes.
  5. Run a second sandboxed command that TCP-connects to 1.1.1.1:443 with a 4 s timeout, and
     assert it fails.
  6. No model turn: this costs nothing.
- [ ] Step 2: run `./scripts/test-codex-live.sh` ONCE and record the output. If the NEW test fails,
  stop and report BLOCKED with the output; do not re-run.
- [ ] Step 3: headless real-flow check, run ONCE (one model turn):
  - In a temp dir, run
    `codex exec --skip-git-repo-check <flags as argv> "Run exactly: python3 <client> <sock>; python3 <netcheck> — reply with their stdout only"`,
    with the same echo server.
  - Unset `CLAUDE_CODE_CHILD_SESSION` first.
  - Expect CONNECTED and INTERNET-BLOCKED. Paste the output in the report.
- [ ] Step 4: docs.
  - ARCHITECTURE: a "Codex tabs" paragraph covering the mechanism, the experimental flag, the
    guard test, the sandbox-choice exception and exit 77.
  - HANDOFF: one line.
  - FOLLOWUPS: an entry noting the `network_proxy` experimental dependency, and what to do if
    the live guard fails.
- [ ] Step 5: `./scripts/test-unit.sh` GREEN. Commit with
  `test: pin codex's unix-socket grant with a live guard, and document it`.
