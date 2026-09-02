# Adapter Capability Suite — Design

**Date:** 2026-09-02 · **Status:** proposed

## 1. The problem

`AgentAdapter` declares twenty members. Every one of them is a claim about an external
binary that this repo does not control and cannot pin: `claude` and `codex` both ship on their
own cadence, and codex is explicitly experimental. The suite has 237 test files and ~750 tests,
and almost all of them prove the *shape* of our side against a scripted transport or a captured
fixture. Two things nothing proves:

1. **That a declaration is still honest.** `CodexAdapter.openPromptReader` is `nil`, justified
   in prose by "codex writes nothing to its rollout when the approval list goes up". If codex
   started writing that record tomorrow, the declaration would be wrong, the phone would keep
   answering `unsupported_agent`, and every test would stay green.
2. **That the pty-facing half works at all.** `resumeCommand` returns a *string*. Tests assert
   the string. Nothing types it at a real TUI and checks that a session comes back.

The reported symptoms are both in that second gap: `codex resume <uuid>` typed into a terminal
does not actually resume without going through `/resume` and picking from a menu, and renamed
tabs do not pick their names back up. Neither is visible to any existing test.

The drift is already observable statically. `AgentAdapter.swift`'s own documentation says
codex's `textChannel` is `nil` and that "nothing codex has goes through the funnel"; the code
declares `CodexTextChannel()`. The prose is describing a state the code left. That is doc drift
rather than behavioural drift, but it is the same failure mode: a claim nobody re-checks.

## 2. What this is

A **capability matrix**, produced by probing a real `claude` and a real `codex`, and diffed
against a checked-in baseline.

Each cell is one (agent, capability) pair carrying two values — what the adapter **declares**
and what the probe **observed** — plus a verdict. The valuable cell is the one where those two
disagree; a bare ✓/✗ would throw away exactly the signal being sought.

Verdict vocabulary:

| Verdict | Meaning |
|---|---|
| `ok` | Probed, and behaviour matches the declaration. |
| `broken` | Probed, and behaviour contradicts the declaration. **The finding.** |
| `by-design` | The adapter declares the capability absent, and the probe confirms the stated *reason* still holds. |
| `rotted` | The adapter declares it absent, but the reason no longer holds — the refusal is now stale. |
| `needs-auth` | Cannot be probed honestly in a sandbox (login flows). |
| `error` | The harness failed. Says nothing about the adapter. |

`error` is deliberately not a verdict about the agent. A probe that cannot run must never be
recorded as a capability that does not work.

### Baseline and drift

`baseline.json` pins the expected verdict for every cell, alongside the `claude` and `codex`
versions the baseline was taken against. A run diffs and exits nonzero on any change. Two
consequences, both wanted:

- A codex-cli upgrade that breaks resume fails the run loudly instead of being discovered from
  a pocket three weeks later.
- A fix that repairs a cell also fails the run, forcing the baseline update that records *when*
  it started working — which is the durable form of the version-pinned behaviour notes that
  currently live in comments and expire silently.

The agent versions are part of the diff. A matrix identical under a different codex version is
reported as such, because that is new information about how stable the surface is.

## 3. Architecture

```
scripts/adapterprobe/
  probe.swift        the real adapter, as a CLI
  ptyscreen.py       pty.fork + pyte rendering            (extracted from livefuzz)
  sandbox.py         throwaway agent homes
  capabilities.py    the row definitions
  run.py             matrix runner, baseline diff, report
  baseline.json      pinned verdicts + agent versions
scripts/test-adapters.sh
```

Python drives; Swift answers. This mirrors `scripts/livefuzz/`, which already drives a real
`claude` TUI in a real pty and checks it by calling the *actual* `ChoiceDialog` parser through a
compiled probe rather than a Python reimplementation. That property is the one worth keeping: a
`broken` verdict here means the production code declined, not that a mirror of it disagreed.

### 3.1 `probe.swift` — the real adapter as a CLI

`livefuzz` compiles its probe with `swiftc ChoiceDialog.swift probe.swift`, which works only
because `ChoiceDialog.swift` is nearly standalone. `CodexAdapter` is not: it needs FleetKit,
`CodexRPC`, `CodexProcessTransport`, `SessionStore`'s types, and `@MainActor async` context.
Recompiling that source list would be a second, drifting build description of the app.

So the probe links **the built app instead**. `DerivedData/Build/Products/Debug` already emits
`FlightDeck.swiftmodule`, `FleetKit.framework` and `Flight Deck.debug.dylib`, and Debug is built
with `-enable-testing` — which is exactly what lets `FlightDeckTests` say `@testable import
FlightDeck`. The probe says the same thing and links the same dylib, resolving FleetKit through
`DYLD_FRAMEWORK_PATH` the way `test-unit.sh` and `test-codex-live.sh` already do. No new build
description, and the probe cannot drift from the app because it *is* the app's module.

Subcommands are one-per-adapter-member, taking JSON on stdin and emitting JSON on stdout:

```
probe declare <agent>                     every static capability answer, as JSON
probe prepare <agent> --cwd <dir>         AgentBinding, or the error
probe rebind  <agent> --pin <uuid>        the settled binding
probe rename  <agent> --id <uuid> --to S  outbound rename through the real channel
probe read    <agent> --id <uuid>         title + activity
probe launch-command <agent> --id <uuid>  the literal text to type
probe resume-command <agent> --id <uuid>
probe title-from-transcript <agent> <path>
probe timeline <agent> < transcript.jsonl every line, as TimelineItems
probe sanitize <agent> <raw>
probe identity <agent> < marker.json
probe composer-empty <agent> < screen     AgentTextChannel.isComposerEmpty
probe focused-row <agent> < screen        AgentDialogDriver.focusedRow
probe row-reads <agent> <n> <label> < screen
probe open-prompt <agent> < tail.jsonl    AgentOpenPromptReader, or the refusal
```

`probe declare` is what makes the matrix's "declared" column real rather than transcribed —
transcribing it into Python would create a third copy to drift.

### 3.2 `ptyscreen.py` — the live terminal

`pty.fork` + `pyte.Screen`/`ByteStream` at 136×34, with the mouse-negotiation filter, the pump
loop and the marker wait already written and working in `scripts/livefuzz/fuzz.py`. That code is
extracted here and `fuzz.py` imports it, rather than being copied — one pty driver, two
consumers. This is the one change to existing code in scope; it is a straight extraction with no
behaviour change, and `fuzz.py`'s own run is the check.

The API is small: spawn a command in a cwd with an env, pump for N seconds, read the rendered
screen as a string, send keys, wait for a marker to appear.

### 3.3 `sandbox.py` — throwaway homes

Every run mints a temp directory and sets `CLAUDE_CONFIG_DIR` / `CODEX_HOME` into it, then
copies **only** the credential file (`~/.claude.json`, `~/.codex/auth.json`) so the agents can
authenticate. Threads, rollouts, transcripts, status files and `session_index.jsonl` are all
created inside the sandbox, and the whole tree is removed at the end.

Real history is untouchable by construction rather than by careful cleanup. This is deliberate:
`scripts/smoke.sh` carries a comment recording that it once `defaults delete`d the whole
preference domain and destroyed every real session and preference on every run. Cleanup-by-id,
as `CodexIntegrationTests` does it, is correct but relies on the cleanup path executing; a
sandbox does not.

Two guards, because the cost of getting this wrong is the user's real history:

- **Refuse to run** if the resolved `CLAUDE_CONFIG_DIR` or `CODEX_HOME` is under `$HOME`, or is
  `~/.claude` / `~/.codex`. Checked after resolution, so a symlink cannot smuggle it through.
- **Copy credentials in, never out.** The sandbox is deleted wholesale; nothing is written back.

Trade-off accepted: the sandbox has no MCP servers and none of the real settings, so
config-sensitive behaviour is not reproduced. Rows whose result could plausibly depend on
configuration are flagged `sandbox-config` in the report so a surprising verdict can be
re-checked by hand before it is believed.

### 3.4 Rows

Twenty-one capabilities, each probed for both agents. Grouped by what a probe can actually
establish.

**Declarations** — is the static answer still honest?

| Capability | How it is probed |
|---|---|
| `negotiatesIdentity` | `prepare` with no runtime started. claude must succeed; codex must fail. |
| `needsRuntimeStart` | Same call, read from the other side: does the adapter require the stack? |
| `hasStatusRegistry` | After a real turn, does `<home>/sessions` hold a status file? claude yes, codex no. |
| `textChannel` | Live TUI at an idle screen: `isComposerEmpty` must be true. |
| `dialogDriver` | Raise a real approval dialog; `focusedRow` must return a row, and `row(allowRow, reads:)` must agree with the screen. |
| `openPromptReader` | claude: derive an `OpenPrompt` from a real tail with a dialog up. codex: confirm the rollout still records **nothing** when its list is up — probing the stated reason, so the `nil` can be marked `rotted` rather than silently trusted. |
| `homeMarkerFile` | Does the named file exist in a real home? |
| `identity(fromHomeData:)` | Feed the real marker; expect an identity or an honest `nil`, never a plausible wrong address. |
| `environment(for:)` | Self-validating: the sandbox only works if this redirects the home. |

**Grammars** — does the parser still match what the agent writes *today*?

| Capability | How it is probed |
|---|---|
| `title(fromTranscriptAt:)` | claude: run a real session, recover its title. codex: `nil` is correct, and the probe confirms the name arrives via `session_index.jsonl` instead. |
| `timelineItems(inLine:at:)` | Feed every line of a freshly produced real transcript. Expect ≥1 item, and report any record type that yields nothing — the drift detector for a renamed record. |
| `sanitizedTitle` | Round trip: sanitize a hostile title, set it through the real rename channel, read it back. |

**Live operations** — including both reported symptoms.

| Capability | How it is probed |
|---|---|
| `prepare` | Identity exists before any pty. codex additionally: the start→name commit, and the `thread/archive`/`unarchive` writer-lock release. |
| `binding(for:)` | Pin read; conversation id and transcript path agree with what the agent wrote. |
| `location(for:)` | Launch in the stated working directory; the agent reports that directory. |
| `launchCommand` | **Typed at a live pty.** A TUI comes up bound to the expected conversation. |
| **`resumeCommand`** | **Typed at a live pty in a fresh terminal. Prior turns are on screen, with no `/resume` picker.** ← reported symptom 1 |
| `rebind` | Restore path settles identity. codex with a deleted pin must hand back a *different* conversation, not fail. |
| **`rename`** | Outbound: rename, then confirm the agent's own record changed. Inbound: rename, relaunch, **confirm the name is still there.** ← reported symptom 2 |
| `loginInvocation` | `needs-auth`. The sandbox is authenticated, so an honest probe is impossible; the weaker check that the binary exists and advertises the subcommand is recorded as such, never as `ok`. |
| Runtime observation | During a real turn: claude's status file transitions, codex's rollout tail. `AgentRuntime`'s fan-out to the right tab. |

### 3.5 Cost and safety

Some rows need a real model turn, which costs tokens. Rows are tagged, and the runner takes
`--tier=cheap` (default) or `--tier=full` (adds the rows that need a completion).

The grammar rows in §3.4 need a transcript, and the sandbox that produced one is deleted at the
end of its run — so the cheap tier reads a **checked-in captured corpus** instead, following the
`rollout.captured.jsonl` precedent already in `Tests/`. A `--tier=full --capture` run refreshes
that corpus from the live agents and records the versions it came from. This keeps the default
run free and offline-ish while making corpus staleness explicit: a capture's recorded version
drifting from the installed one is reported, because a grammar checked only against a corpus
from four codex releases ago is checking history rather than today.

`--keep` retains the sandbox tree for inspection instead of deleting it, for diagnosing a
`broken` cell by hand. It is off by default and prints the retained path.

The suite spawns no GUI and steals no focus — it is pty-only, never the app — so it does not
carry `smoke.sh`'s constraint against being run while the user is typing. It is still not
something to loop: it creates real threads and, at `--tier=full`, spends tokens.

## 4. Error handling

- A probe that raises, times out, or cannot build reports `error` with its stderr attached, and
  the run continues. One unbuildable row must not cost the other forty-one.
- The runner separates **harness failure** from **capability failure** in both the report and the
  exit code: `error` cells never satisfy a baseline expectation of `ok`, and a run that is all
  `error` exits nonzero with a distinct code from a run that found real drift.
- Sandbox teardown runs on every exit path including `SIGINT`, and the guard in §3.3 runs before
  anything is created.
- Agent version is captured at the start of every run and attached to the report, so a matrix is
  never read without knowing what it was taken against.

## 5. Testing

The harness is itself testable, and the parts worth testing are the parts that decide verdicts:

- `capabilities.py` verdict derivation — given a declared value and an observed value, does it
  produce `ok` / `broken` / `by-design` / `rotted` correctly? Pure, table-driven, hermetic.
- Baseline diffing — added, removed and changed cells; version change with an identical matrix.
- The sandbox guard — refuses `$HOME`, `~/.claude`, `~/.codex`, and a symlink pointing at any of
  them.
- `ptyscreen.py` — `fuzz.py` continuing to pass is the extraction's check.

These run in the hermetic Python tests and spawn no agent.

## 6. Out of scope

- iOS / `FlightDeckMobile`. Adapters are macOS-side.
- Replacing `CodexIntegrationTests`. It proves five specific undocumented codex behaviours as
  assertions and is better at that than a matrix cell; the matrix links to it rather than
  absorbing it.
- Replacing `livefuzz`. It fuzzes one capability deeply with generated input; this suite checks
  many capabilities once each. Different jobs, now sharing a pty driver.
- Fixing anything the matrix finds. The first run's output is the input to that decision.
