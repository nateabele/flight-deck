# Spec — Flywheel run-integration (Level 0) + real-agent smoke test

## Context

Flight Deck (FD) is being extended, over several increments, into a visual control
center for **agent-flywheel** swarms. Four spikes (see `docs/FLYWHEEL-SPIKE-FINDINGS.md`)
settled the architecture: **FD runs its own agents (its `fd-abduco` PTY engine) and
participates in the shared on-disk beads + Agent-Mail substrate directly; NTM is not
in the loop.** This spec is the **first build increment (Level 0)**: make an
FD-spawned agent a first-class participant in that substrate, and **prove it
end-to-end with a real-agent smoke test** — before any swarm/observe UI is built.

The crux was validated in Spike A but with *simulated* agent shell steps; this
increment turns the validated contract into FD code and closes that loose end with a
real `claude`/`codex` agent.

### Decisions locked (from brainstorming)

- **Substrate access = CLI** (AGENTS.md-instructed). Agents call `am`/`br` directly;
  FD does **not** wire any MCP server. Contract = AGENTS.md present + `am guard`
  installed + `am macros start-session` at spawn + `AGENT_NAME` injected.
- **Both agent kinds** (claude *and* codex) in this increment — solve the synchronous
  claude spawn path and the async codex `prepare()` path together.
- **Opt-in, then FD installs.** A per-project toggle. Detection auto-suggests enabling.
  On enable, FD performs one-time repo setup (`am guard install` + beads-sync hooks)
  **only after explicit confirmation** — never a silent repo mutation.

## Goal & success criteria

An agent FD spawns into a flywheel-enabled project:
1. boots with a stable Agent-Mail identity (`am macros start-session`, name captured);
2. carries that identity to the pre-commit guard via `AGENT_NAME` in its PTY env;
3. has its file-reservation conflicts **blocked** (guard fails *closed*, not open);
4. shares beads state with co-located agents.

**Proven by a real-agent smoke test:** two FD-spawned agents in one flywheel repo get
distinct `AGENT_NAME`s; one reserves a file; the other's conflicting commit is blocked
with the exact guard message; both agents' bead claims are visible via `br`.

## Non-goals (this increment)

- No swarm/observe UI (bead ring, DAG, inbox, Fleet mode) — that is Level 1.
- No convergence gauge / Encode (Level 2), no operate actions (Level 3).
- No reservation-TTL auto-renewal beyond a refresh-on-wake (noted as follow-up).
- No worktree/shared-main coordination-mode setting (a later, richer setting; this
  increment ships a plain on/off flag with room to grow).
- No change to non-flywheel projects: flag off ⇒ **zero** behavior change.

## Architecture overview

A small new `Sources/FlightDeck/Flywheel/` group, plus additive hooks into the
existing spawn path and per-project settings. Nothing in the hot path changes when
`flywheelEnabled` is false.

```
project add ──▶ FlywheelProjectProbe (markers?) ──▶ suggest opt-in
   opt-in ────▶ FlywheelSetup.enable(repo)  ── confirm ─▶ am guard install + sync hooks
 spawn agent ─▶ FlywheelCoordinator.boot(project,program,model,name?)
                    │  runs `am macros start-session … --json`, parses agent.name
                    ▼
              persisted per-session identity  ──▶ env delta {AGENT_NAME,…}
                    │                                    │
       (claude: async spawn path)              PreferencesStore.sessionEnvironment
       (codex: prepare())                       merges delta ─▶ Ghostty surface env
                                                              ─▶ forked agent PTY
```

## Components

### 1. Per-project flag — `ProjectSettings.flywheelEnabled`
`Sources/FlightDeck/Preferences/ProjectSettings.swift`. Add `var flywheelEnabled: Bool
= false`, `decodeIfPresent` for back-compat, include in `isEmpty` so an all-default
record is still dropped. Read/written through the existing
`PreferencesStore.projectSettings(_:)` / `setProjectSettings(_:_:)` (path-keyed via
`key(_:)`). This is the single source of truth for "is this project in flywheel mode."

### 2. Marker detection — `FlywheelProjectProbe`
New pure/testable type. Given a `repo.url`, returns
`FlywheelStatus { hasBeads, hasAgentMailMarker, guardInstalled, beadsSyncHooksInstalled }`
via `FileManager` checks: `.beads/` dir, `.agent-mail.yaml` file, `am guard status`
(or reading `.git/hooks/pre-commit` for the chain-runner), git hooks presence. No
mutation. Run at the project-add choke point (new-repo branch of
`SessionStore.insertSession`) to decide whether to *suggest* opt-in; run again
on-demand when the opt-in sheet opens to compute "what's missing."

### 3. One-time repo setup — `FlywheelSetup.enable(repo:) async`
Invoked only on explicit opt-in confirmation. Performs, idempotently, the pieces the
probe found missing:
- `am guard install <abs-repo> <abs-repo>` — flywheel-new omits it; without it the
  guard fails *open*. (Composes with any existing hook via the chain-runner.)
- Ensure beads-sync git hooks (a minimal `pre-commit`/`post-checkout` that runs
  `br sync --flush-only` and stages `.beads/`). **Note:** for co-located agents
  sharing one working copy, `.beads/beads.db` is already shared on disk, so basic
  coordination does not depend on these hooks — they exist for durability, history,
  and future worktree/cross-machine cases. Installed here, not on the Level-0
  critical path.
- Sets `flywheelEnabled = true` on success.
The confirmation dialog lists exactly what will run before any mutation.

### 4. Spawn bootstrap — `FlywheelCoordinator`
`boot(project:program:model:name:) async throws -> FlywheelIdentity`. Runs
`am macros start-session --project <abs> --program <claude-code|codex-cli>
--model <model> [-n <name>] --json`, capturing stdout with the established
`Process()`+`Pipe()` pattern (model on `LoginShellPath.defaultRun`), and parses
`agent.name`. Returns `FlywheelIdentity { name, project }`. Produces the env delta
`["AGENT_NAME": name, "AGENT_MAIL_AGENT": name, "AGENT_MAIL_PROJECT": <abs>]`.
`<model>` is derived from the session's agent options; `program` is `claude-code`
for `AgentID.claude`, `codex-cli` for `.codex`.

### 5. Identity persistence & stability
`AGENT_NAME` **must be stable across session wake/respawn** — a woken agent with a new
name would orphan its reservations. Persist `FlywheelIdentity` per session (add to the
session model + `sessions.json` persistence). First spawn: `boot(...)` with no name →
capture the generated name → persist. Wake/respawn (`makeAttachSurface`): re-inject the
**same** `AGENT_NAME`; re-run `boot(..., name: storedName)` to refresh the inbox/
reservation lease idempotently (also mitigates the 3600s reservation TTL for
long-lived sessions).

### 6. Spawn-path wiring (the structural work)
- **Env injection point:** `sessionEnvironment(for:)` is keyed by *account*, not
  session, so the per-session delta is layered at the two surface-config assignment
  sites (`SessionStore.insertSession`, `SessionStore.makeAttachSurface`) — where the
  session (hence its `FlywheelIdentity`) is in scope — on top of the base
  `sessionEnvironment(for:)` result (which already injects `FD_OUTLOG_BUDGET`).
  Equivalent alternative: thread an optional identity through `sessionEnvironment`.
  Either way, a session with no identity yields the current env byte-for-byte.
- **Codex (async):** run `FlywheelCoordinator.boot` inside/around
  `CodexAdapter.prepare(for:options:)` (already async, pre-PTY, already runs external
  work). Stash the identity so the env producer can read it.
- **Claude (synchronous path):** claude creation (`newSession` → `seedInitialSession`)
  bypasses `prepare`. For **flywheel projects**, route claude spawn through the async
  `createSession` path so a pre-PTY bootstrap can run and be awaited; run `boot` in a
  shared pre-launch step before surface creation. Non-flywheel claude spawns keep the
  existing synchronous path untouched.

### 7. Opt-in affordance (minimal UI)
A project context-menu action ("Enable Flywheel coordination…") on the project header
row, plus a confirmation sheet that shows the probe result and the exact setup
commands. No other UI. (Deliberately minimal — the real surfaces come in Level 1.)

## Data flow

**Enable:** add project → probe → if markers present, surface a subtle "Enable
Flywheel?" affordance → user confirms → `FlywheelSetup.enable` runs guard/hook install
→ `flywheelEnabled = true`.

**Spawn (flywheel project):** create session → (claude: async route / codex: prepare)
→ `FlywheelCoordinator.boot` → capture name → persist `FlywheelIdentity` →
`sessionEnvironment` merges `AGENT_NAME…` → surface forks agent with identity in env →
agent follows AGENTS.md, reserves files / claims beads under that identity → guard
enforces against `AGENT_NAME` at commit.

**Wake:** `makeAttachSurface` → read persisted identity → re-inject same `AGENT_NAME` →
refresh lease via `boot(name:)`.

## Error handling

- **`boot` fails** (am error, non-zero exit, unparseable JSON): surface a clear session
  error (reuse the existing `apiError`/session-error channel), do **not** launch the
  agent silently un-bootstrapped into a flywheel repo (an un-identified agent + active
  reservations would block every commit). Offer retry.
- **Setup fails** (`am guard install` error): report which step failed; leave
  `flywheelEnabled` false; no partial-enable.
- **Never bypass `am macros start-session`** with raw `am agents register` — the
  missing `project.json` is what makes the guard fail open (Spike A).
- **Flag off / non-flywheel project:** env delta empty, no bootstrap, no probe cost on
  the spawn hot path — byte-for-byte the current behavior.
- **`am` global-DB scoping:** always pass the standardized absolute project path as the
  `--project` human_key, matching `PreferencesStore.key(_:)`, so identities/reservations
  land under the right project key in the shared `storage.sqlite3`.

## Testing

**Unit (test-unit.sh, macOS — note it runs the full suite, ~8 min; budget for it):**
- `ProjectSettings.flywheelEnabled` encode/decode round-trip + back-compat (old JSON
  without the field) + `isEmpty`.
- `FlywheelProjectProbe` against fixture dirs (markers present / absent / partial).
- `FlywheelCoordinator` start-session command construction + `--json` name parsing,
  with a faked process runner (no real `am`).
- Env-delta assembly: identity present ⇒ `AGENT_NAME`/`AGENT_MAIL_*` in
  `sessionEnvironment`; identity absent ⇒ unchanged.
- Identity stability: simulated wake re-injects the same name (no new `boot` name).

**Real-agent E2E smoke test (`scripts/flywheel-smoke.sh` + a checklist doc):** on-demand,
not CI (it spawns real agents = tokens + interactive, and involves the GUI — must be
run deliberately, focus-aware, per the project's smoke-test norms). Steps: create a
scratch flywheel repo; enable flywheel mode in FD; spawn two real agents; drive each
with a minimal non-interactive prompt to claim a bead + reserve a file + attempt a
commit; a verifier reads `am`/`br` state and asserts: two distinct `AGENT_NAME`s, a
conflicting commit blocked with the exact guard message, both bead claims visible.
This closes Spike A's simulated-vs-real gap and exercises the MCP-vs-CLI reality in
passing.

## Risks & follow-ups

- **Claude async-routing** is the riskiest change (touches the load-bearing spawn
  path); it must be strictly gated on `flywheelEnabled` so the default path is
  untouched. Strong test coverage + the smoke test guard this.
- **Reservation TTL** (3600s default) — refresh-on-wake is a stopgap; proper renewal
  (a timer, or longer TTL) is a follow-up.
- **Guard fail-open on missing `project.json`** is an upstream bug (Spike A, GH#228);
  FD's mitigation is to always go through `start-session`. Worth flagging upstream.
- **`flywheel-new` skipping `am guard install`** — FD works around it; also worth an
  upstream note.
- Codex identity vs its app-server thread identity: ensure `AGENT_NAME` (Agent-Mail
  identity) and codex's own thread naming don't collide confusingly — verify in the
  smoke test.

## Files touched (representative)

- `Sources/FlightDeck/Flywheel/FlywheelProjectProbe.swift` *(new)*
- `Sources/FlightDeck/Flywheel/FlywheelCoordinator.swift` *(new)*
- `Sources/FlightDeck/Flywheel/FlywheelSetup.swift` *(new)*
- `Sources/FlightDeck/Preferences/ProjectSettings.swift` — add flag
- `Sources/FlightDeck/Preferences/PreferencesStore.swift` — env delta merge in
  `sessionEnvironment(for:)`
- `Sources/FlightDeck/SessionStore.swift` — flywheel-gated async claude route;
  bootstrap call sites; identity persistence; project-add probe hook
- `Sources/FlightDeck/Agents/Codex/CodexAdapter.swift` — bootstrap in `prepare`
- session model + `sessions.json` persistence — `FlywheelIdentity`
- `SessionSidebar.swift` / `ProjectHeaderRow.swift` — opt-in menu action + confirm sheet
- `scripts/flywheel-smoke.sh` *(new)* + a smoke checklist doc; unit tests alongside
