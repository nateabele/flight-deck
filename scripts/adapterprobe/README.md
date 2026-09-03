# `scripts/adapterprobe/` — the adapter capability matrix

## Why this exists

Flight Deck's `AgentAdapter` conformances (`ClaudeAdapter`, `CodexAdapter`) each make a set of
claims about the agent they wrap — whether it negotiates its own identity, whether renaming
survives a resume, what its approval dialog looks like today. The Swift test suite pins each
claim against **static, hand-captured fixtures**: useful for catching a regression in the
parsing logic, useless for catching the fixture itself going stale, because a captured screen
never updates when the real CLI's grammar drifts underneath it. `docs/HANDOFF-phone-answering.md`
records exactly this failure mode for the answer-drive path; `scripts/livefuzz/` (see its own
README) exists for the same reason, one layer down, for `ChoiceDialog` alone.

This suite is the same idea at the scope of a whole adapter: `capabilities.py` declares one
**row** per claim `AgentAdapter` makes, and `run.py` derives a **verdict** for each row against
both `claude` and `codex` — sometimes against a checked-in corpus (cheap, no agent spawned),
sometimes against a live agent driven through a real pty inside a throwaway sandbox (`full`,
spends real API tokens). The output is a matrix: 21 rows × 2 agents = 42 cells, refreshed on
demand rather than trusted forever.

## Verdict vocabulary

| Verdict | Meaning |
|---|---|
| `ok` | Declared and observed agree — a working capability, or a correctly-declared symmetric fact. |
| `broken` | Declared as present/true, but the live behaviour disagrees. **The finding this suite exists to produce.** |
| `by-design` | Declared absent, and the *stated reason* for the absence was itself checked and still holds. |
| `rotted` | Declared absent, but the stated reason no longer holds — the refusal has gone stale. |
| `needs-auth` | An honest probe would require deauthenticating the sandbox; recorded rather than faked. |
| `error` | The harness could not get a clean answer at all (timeout, crash, or an admitted measurement gap) — never treated as "passing", and always ranked worse than a mere verdict change (see `run.py`'s `_exit_code`). |

`kind="fact"` rows (`negotiatesIdentity`, `needsRuntimeStart`, `hasStatusRegistry`) are symmetric
booleans, not capabilities that can be absent for a reason — `declared=False` there is just the
other value of the claim, checked exactly like `True` is. See `capabilities.py`'s own `verdict()`
docstring for the full derivation.

## One-time setup

The venv lives **outside the repo**, matching `scripts/livefuzz/README.md`'s rule — `pyte` is a
harness dependency, not a project one, and nothing here should end up inside this checkout:

```sh
python3 -m venv /tmp/adapterprobe-venv && /tmp/adapterprobe-venv/bin/pip install pyte
```

`scripts/test-adapters.sh` creates this venv itself on first run if it is missing, so the step
above is optional — it exists for running the hermetic tests directly:

```sh
/tmp/adapterprobe-venv/bin/python -m unittest discover -s scripts/adapterprobe/tests -v
```

## Running it

```sh
./scripts/test-adapters.sh                          # cheap tier: no live agent, < 1 minute
./scripts/test-adapters.sh --tier full               # adds the rows needing a real turn
./scripts/test-adapters.sh --update-baseline         # write this run's matrix as the new baseline
./scripts/test-adapters.sh --capture                 # (full tier) stage fresh transcripts under scripts/adapterprobe/corpus/
./scripts/test-adapters.sh --keep                    # keep the sandbox tree after the run, for inspection
./scripts/test-adapters.sh --json PATH               # also write the matrix as JSON to PATH
```

**`--capture` never writes into `Tests/FlightDeckTests/Fixtures/`.** Those files are
sha256-pinned by `TimelineFixtureTests`, and codex writes its home's `~/.agents/skills`
inventory into a rollout regardless of `CODEX_HOME` — a sandbox does not make a capture clean
enough to land, unreviewed, on a pinned fixture (`Fixtures/Codex/rollout.captured.provenance.json`
records exactly this leak, caught only by hand-scanning a past capture after the fact). Instead
`--capture` stages `scripts/adapterprobe/corpus/{claude,codex}.*.captured.jsonl` — gitignored
working files, not test fixtures. Promoting one into the checked-in corpus (and
updating `corpus.json`'s recorded version below) is a separate, deliberate, reviewed step: scan
it by hand first, then copy it over the matching `Fixtures/{Claude,Codex}/*.captured.jsonl` file
yourself.

**`corpus.json` is what makes the corpus-staleness guard real.** It records the agent versions
the checked-in `Fixtures/{Claude,Codex}/*.captured.*` corpus was actually captured against;
`run.py` compares that against `agent_versions()`'s live read on every run and prints `corpus
stale: {...}` the moment either agent has moved on. It has to be committed to do anything — an
absent file makes every comparison vacuously pass, which is exactly the state this repo shipped
in until this file existed. `--capture` never touches `corpus.json` — it only stages a raw
transcript under `scripts/adapterprobe/corpus/` and prints which version it came from; updating
`corpus.json` is part of the same manual promotion step as copying that capture over the pinned
`Fixtures/{Claude,Codex}/*.captured.jsonl` file, both done by hand after a human has reviewed it.
So a `corpus stale` print is a prompt to go capture and review, not something `--capture` alone
resolves, and not something to silence by editing this file directly.

Exit code: `0` clean (matches `baseline.json`), `1` capability drift (a cell changed or is new),
`3` a harness failure (a cell that used to read something else now reads `error`, or a brand-new
cell reads `error` outright — always outranks plain drift), `4` the sandbox guard refused to run
at all (see below), `5` the real `~/.codex/sessions` or `~/.claude/projects` listing changed
during the run — spec invariant 9, checked unconditionally around the whole sandbox lifetime,
never just trusted.

**`baseline.json` was captured at `--tier full`, and records each cell's own tier alongside its
verdict.** A bare `./scripts/test-adapters.sh` (cheap only) diffs cleanly against it: a
full-tier-only cell this run never attempted is reported as "not exercised", not "removed", and
does not affect the exit code. Only a cell whose own tier this run *did* run, and that vanished
from the matrix anyway, is real drift. The full-tier-only count is printed above the matrix
(e.g. `8 full-tier cells not exercised (run --tier full to check them)`) so the gap stays
visible rather than silent.

**`--tier full` spends real API tokens and creates real threads** (inside the sandbox, which is
deleted afterwards) — four rows per agent need a live model turn, and `ROW_TIMEOUT["full"]` is
420 seconds per row. Budget up to ~30 minutes for a full run. **Do not loop it.** Run it once,
read the result, and only re-run if you have a specific reason to believe the environment
changed (a new agent version, a config edit) — not to "make sure".

## Safety

Everything live goes through `AgentSandbox` (`sandbox.py`): a throwaway `claude-home` /
`codex-home` under `/tmp`, seeded only with a *copy* of the real credentials (never written back)
and stripped of every `CLAUDE_CODE_*` child-session marker so a `claude` spawned from inside a
Claude Code session (this harness commonly runs from one) does not silently disable its own
transcript saving. `guard_home()` refuses to construct a sandbox whose resolved path is, or is
inside, the real `$HOME` — a symlink or an unexpanded `~` cannot smuggle a real home through —
and `AgentSandbox.__exit__` deletes the whole tree unconditionally (unless `--keep`), so **real
history is unreachable by construction, not by careful cleanup**. If the guard ever fires,
`run.py` prints the reason and exits `4` rather than proceeding.

## A `broken` cell is a finding, not a bug to fix here

This suite's job is to answer "does the adapter still do what it claims", honestly, on demand.
Recording a red cell **is** the deliverable — this branch does not touch `Sources/`, and no row
is ever edited to make a genuine finding disappear. If a row's own verdict looks wrong, the fix
belongs in a report or a follow-up task against the adapter (or, if the row's own logic is at
fault, a change to that row with its own justification) — never a silent edit to the recorded
cell.

## First capture — 2026-09-02

**`ctx.pty` deliberately launches through the same shell Flight Deck itself resolves, not a
hardcoded one — because a probe that launches a different binary than the app measures nothing
about the app.** Every live-pty row (`launchCommand`, `location`, `dialogDriver`,
`resumeCommand`, `openPromptReader`, claude's `rename`) and `pty_agent_version()` (which fills in
`codex_pty`/`claude_pty` in `versions`, next to the plain `codex`/`claude` `agent_versions()`
already reports) launch via `ProbeContext.login_shell` — `Sources/FlightDeck/Agents/
ShellResolver.swift`'s own `resolve()` answer, fetched once per run through a `probe
login-shell` subcommand rather than re-derived here, so this harness can never independently
drift from what `LoginShellPath`/`CodexProcessTransport` actually launch through for a real
spawn. This was found the hard way: an earlier revision hardcoded `/bin/sh -lc` for every pty
launch, and on this machine `/bin/sh -lc` and the account's real login shell resolve `codex` to
two *different* installs — `/opt/homebrew/bin/codex` (`0.142.4`) vs. `~/.local/bin/codex`
(`0.152.1`) — which meant every pty-driven row, including `codex.resumeCommand`, the reported
symptom this whole suite exists to check, had been measured against a `codex` build Flight Deck
itself does not run. Fixed by resolving the login shell instead of guessing at one; `codex_pty`/
`codex_pty_path` now agree with `codex`/`codex_path` on this machine, and re-running `--tier
full` against the corrected binary changed no verdict — see below. The loud `NOTE:` `run.py`
prints on any future divergence between the two is kept: a machine where they still differ is a
real hazard, not a bug in this harness.

Taken against `claude-cli 2.1.259 (Claude Code)` and `codex-cli 0.152.1` for every row, pty-driven
or not, `--tier full`, committed as `baseline.json`. 7 rows were red or admittedly inconclusive
out of 42 cells — three independent codex findings, one derivative of them, and three
harness/timing questions still open:

- **`codex.sanitizedTitle` — broken.** Codex's declared contract is "no sanitizing; the RPC
  channel needs none" — but the real CLI strips `\n` and `\t` from a hostile title anyway. The
  declaration has drifted from what codex actually does.
- **`codex.dialogDriver` — broken.** The approval-list screen's own affirmative row no longer
  reads back the way `AgentAdapter`'s driver expects — apparent grammar drift in that screen.
- **`codex.resumeCommand` — broken.** This is the reported symptom that commissioned this whole
  suite: typing codex's own `resumeCommand` at a fresh pty does not reattach to prior history —
  the seeded marker from an earlier turn never reappears on screen. Confirmed against the
  binary Flight Deck actually launches (`0.152.1`, not the `0.142.4` an earlier revision of this
  harness accidentally measured) — the finding holds, now correctly attributed.
- **`codex.runtimeObservation` — broken, but NOT a fourth independent finding.**
  `CodexAdapter.launchCommand` (`Sources/FlightDeck/Agents/Codex/CodexAdapter.swift:286`) is
  `codex resume <id>` — byte-identical to `resumeCommand`'s own launch command — and this row
  drives its turn through exactly that command via `seed_one_turn`. The rollout it measures can
  only grow if the resume attached, so this failing alongside `codex.resumeCommand` is the same
  failure counted twice, not a second, corroborating one.
- **`claude.rename` — error** (`transcript '<sandbox path>.jsonl' never appeared within 30s,
  before /rename was even typed`). The session transcript file itself never showed up in time,
  so the row cannot say whether a rename would have taken — a harness/timing question, not yet a
  confirmed product finding either way.
- **`codex.needsRuntimeStart` — error, by design.** Every codex probe subcommand bootstraps a
  live app-server connection before doing anything else, so there is no cheap way to ask "does
  *prepare* need a runtime" without the probe itself starting one just to ask. Admitted rather
  than guessed — see the row's own comment in `capabilities.py`.
- **`codex.openPromptReader` — error** (`approval list never appeared; screen was still stuck at
  'Booting MCP server: codex_apps'`). A `codex_apps` MCP-boot stall in `codex-cli 0.152.1` blocks
  the screen before any approval prompt could show, regardless of trust settings. This row also
  writes `approval_policy = "on-request"` (at top level, so it is genuinely in effect) to rule
  out the sandbox's own trust override as the cause, but the boot stall is upstream of that
  screen too, so whether the override would have mattered is NOT established — not concluded
  either way, since a full-tier run would be needed to tell and none was spent on it here. A
  finding about this environment's codex install, not about this harness or (so far) about the
  adapter.

Every other cell — including both `loginInvocation` rows (`needs-auth`, by design: the sandbox
is authenticated on purpose, so an honest login probe is impossible without destroying that) —
came back `ok`.

**A structural limit of `claude.rename`, independent of any single run's verdict:** the row's
"inbound" check, after `resumeCommand` reattaches, re-reads the SAME transcript file the
"outbound" check already read right after typing `/rename`. The two reported symptoms this
suite exists to check are "a rename doesn't take" and "a rename doesn't survive a resume" — but
a resumed claude process keeps appending to that one transcript rather than opening a new file,
so this row cannot structurally tell "the title was never written" apart from "the title was
written but a resume forgot it": both read as the same missing record in the same file. Proving
the second symptom for claude, as opposed to the first, would need a distinct signal a resume
produces (e.g. the sidecar `session_index`/status entry codex's own resume path is checked
against) rather than a second read of the file the first check already inspected.

## See also

- `docs/superpowers/specs/2026-09-02-adapter-capability-suite-design.md` and
  `docs/superpowers/plans/2026-09-02-adapter-capability-suite.md` — the spec and plan this suite
  was built from.
- `scripts/livefuzz/README.md` — the sibling harness this one shares its pty driver with: both
  import the same `ptyscreen.py` (extracted from livefuzz in `93cfd18`, before this suite
  existed), and this one's "keep the venv out of the repo" convention comes from there too. That
  one fuzzes `ChoiceDialog` alone, this one covers a whole `AgentAdapter`.
- `Tests/FlightDeckTests/CodexIntegrationTests.swift` — five specific codex behaviours pinned as
  Swift assertions against a real app-server (thread start/naming, killing a live process,
  restore-after-failure, a real resumed turn's rollout, the writer-lock handoff, and renaming
  reaching codex's own thread name). This suite's live rows exercise the same kind of surface
  through the compiled adapter itself rather than re-asserting those five directly.
