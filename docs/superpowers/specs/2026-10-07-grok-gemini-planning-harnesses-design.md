# Grok and Gemini as planning harnesses — design and test spec

Date: 2026-10-07. Status: spec for a separate implementation session.
Base: master at or after `229195c8`.

## 1. Goal

Planning rounds (intake triage, drafters, synthesizer, reviewers, cross-check, integrator,
encoder, polisher) can seat **Grok** (xAI, `grok` CLI, "Grok Build") and **Gemini** (Google,
`gemini` CLI), alongside claude and codex. Nate has SuperGrok and Google AI Pro, and wants both
as additional model families for planning.

**Scope: planning only.** These harnesses run headless planning seats. They are NOT Flight
Deck tab agents:
- no `AgentID`;
- no `AgentAdapter`;
- no terminal tabs;
- no swarm routing targets;
- no usage meters.

That can come later. This spec touches IntakeKit's `Harness` and everything that switches on
it.

**And a shared agent profile (§3.0).** This spec first extracts a per-agent `AgentProfile` that
both the tab side (`AgentAdapter`) and the headless side (`Harness`) read. Today four kinds of
knowledge about each CLI are duplicated, and two have already drifted:
- **Model catalog.** `ClaudeFlagCatalog` offers `fable`; planning and routing don't know it
  exists.
- **Error/rate-limit spellings.** These live in four separate lists.
- **The `CLAUDE_CODE_CHILD_SESSION` scrub.** This is copied in three places.
- **Account binding.** Planning seats always bill the built-in account.

Grok and Gemini are then added as profile + harness. Adapters can follow later without
duplicating anything.

**Success criteria:**
1. In the Rounds editor, any seat can be set to Grok or Gemini, with a model and an effort
   where the CLI supports one. Seats can be cross-family, e.g. drafters claude + grok, with a
   gemini reviewer.
2. A full Refine round with one Grok drafter and one Gemini drafter produces valid change sets
   that the existing validator accepts, and the round completes.
3. The second and later rounds resume each seat's own conversation, and never another seat's.
4. No Grok or Gemini seat can write to the repo or the intake directory. The integrator is the
   exception: it writes only in its own work dir, as today.
5. The planning UI shows live activity for both. A failure is diagnosed as rate-limited,
   auth-expired, timeout, harness error or invalid output, never a bare non-zero exit.
6. Cross-family coverage counts Grok and Gemini as their own families.

## 2. Verified facts (probed 2026-10-07 on this Mac; re-check in Task 1)

| | Grok | Gemini |
|---|---|---|
| Binary | `~/.local/bin/grok`, 1.0.30 | `/opt/homebrew/bin/gemini`, 0.59.0 |
| Signed in | **No.** `grok models` says "You are not authenticated." Nate signs in with `grok login`. | **No.** No credentials in `~/.gemini`. Nate signs in through `gemini`'s interactive first run (Sign in with Google). |
| Headless | `grok -p/--single <PROMPT>` | `gemini -p/--prompt <PROMPT>` (appended to stdin, if any) |
| Output | `--output-format` (json, streaming-json / streaming-messages-json), and `--include-partial-messages`-style deltas | `-o/--output-format text\|json\|stream-json` |
| Schema | **`--json-schema <SCHEMA>`**: "the model is constrained to produce JSON matching this schema. Implies --output-format json." Strict-mode compatibility is unverified. | **None.** The schema has to go in the prompt, and the output is checked after the run. |
| Model | `-m/--model`; `grok models` lists `grok-4.6` (default), `grok-4.5` | `-m/--model`. The model list command is unknown; Task 1 finds it. |
| Effort | `--reasoning-effort` / `--effort` | No flag. Model choice only (unless Task 1 finds one). |
| Read-only | `--deny <RULE>` / `--disallowed-tools`, `--allow`, `--disable-web-search`, `--cwd` | `--approval-mode plan` (documented as read-only mode), `-s/--sandbox`, `--include-directories` |
| Resume | `-r/--resume <SESSION_ID>` by id. `-s/--session-id <UUID>` names a NEW conversation. | `-r/--resume` takes `latest` or an **index** only (per `--help`). `--session-id <UUID>` starts a new session with a chosen id. `--list-sessions`. |
| Trust | — | `--skip-trust` trusts the workspace for this session |

**The Google One caveat.** Google says that since 2026-06-18 the Gemini CLI is replaced by the
Antigravity CLI for unpaid and Google One users. AI Pro is billed through Google One. The
Antigravity CLI is installed here as `~/.local/bin/agy`. Task 1 decides which binary the
Gemini harness drives:
- If a signed-in `gemini -p` refuses the AI Pro account, the harness drives `agy` instead.
- In that case, re-probe every Gemini row of the table above against `agy`, and record the
  result in §10.

**Ruling (Track M, 2026-10-07): the Gemini harness drives `agy`, not `gemini`.** The Gemini
column of the table above describes the `gemini` CLI, which the harness does NOT use. For `agy`
(1.2.3, auto-updated to 1.3.1 the same day): headless is `agy -p <prompt>`; output is
`--output-format text|json|stream-json`; the schema is native (`--json-schema <file|json>`, the
answer in `structured_output`); the model is `--model <id>` with the effort part of the id
(`gemini-3.1-pro-high`), so FD passes no `--effort`; read-only is the DEFAULT mode plus
`--sandbox` — `--mode plan` is a workflow, not a boundary (see §10) — and write mode is
`--mode accept-edits --sandbox`; resume is `--conversation <id>` with the id agy reports
(`conversation_id`), and there is no flag to pre-assign one; the sign-in check and model list
are both `agy models`. A signed-out `agy -p` opens a Google sign-in in the browser instead of
failing, so the harness runs `agy models` before every seat (`headlessSignInPreflight`).

## 3. Design

### 3.0 `AgentProfile` — one source of truth per CLI (IntakeKit, pure)

A new `Sources/IntakeKit/Agents/AgentProfile.swift`.

**The protocol.** One conformer per CLI: `ClaudeProfile`, `CodexProfile`, `GrokProfile` and
`GeminiProfile`. Each answers the following, and holds the reasoning comments that today sit
next to each copy:
- `id: HarnessID` (the raw value: `claude`, `codex`, `grok`, `gemini`) and `family: ModelFamily`.
- `binaryName` and `signInCheck`. The check is a cheap read-only command plus a predicate on its
  output, so callers can tell "not installed" from "signed out" from "ready".
- `modelCatalog`:
  - the static aliases or the list command;
  - the default planning model;
  - the knob schema (effort values).
- `classify(error:) -> AgentFailureKind?`. One classifier for `rateLimited`, `authExpired`,
  `overloaded` and `other`, fed by stderr, stream error events, transcript API-error records or
  app-server errors.
- `environment(base:account:) -> [String: String]`:
  - binds the account's home (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`, Grok's and Gemini's
    equivalents, found in Task 1);
  - re-applies what an isolation flag drops (`ClaudeUserEnv`, `CodexUserConfig`'s
    `service_tier`);
  - performs the child-session scrub.

**Who reads it.** Every duplicate becomes a call into the profile:
- **Model lists and defaults:**
  - `IntakeService`'s triage defaults;
  - `AvailableModels`;
  - `ClaudeFlagCatalog`'s `--model` choices. They stay a flag catalog, but their values come
    from the profile;
  - `RoutingCatalogs`.
- **Error and rate-limit classification:**
  - `FailureDiagnosis`;
  - `RateLimitClassifier.kinds`;
  - `CodexTurnRecovery`'s transient list;
  - the fleet's `SessionAPIError` kind mapping. That one stays in FleetKit, but it is classified
    through the profile on the Mac side before it reaches the wire.
- **The child-session scrub:** `IntakeRunnerController`, `PreferencesStore` and `ToolLauncher`.
- **Environment:** `ClaudeUserEnv` and `CodexUserConfig` fold into their profiles' `environment`.

**Account binding for planning.** `HarnessRequest` gains `account: AgentAccountRef?`, a pure
value (id + home URL), so a seat can run on a chosen account.
- `nil` keeps today's behaviour, the built-in account.
- The Rounds editor can pick an account per seat. The default is unchanged.
- Hooking L3's pools and rollover into planning is a follow-up. This spec only makes it
  possible.

**Behaviour must not change** for claude or codex beyond the drift fixes. Each fix gets a test:
- `fable` becomes known to planning and routing.
- The classifier lists merge into one. Every previously recognized spelling still classifies
  the same.

### 3.1 The harness and model family
- Add `.grok` and `.gemini` to `Harness` (`Sources/IntakeKit/Intake.swift:24`). Raw values are
  `"grok"` and `"gemini"`, and they are persisted in intakes and tapes. Older builds can't
  decode intakes that use the new cases. That is acceptable: intakes are per-machine, and the
  phone wire does not carry `Harness`.
- Add the same two cases to `ModelFamily` (`RoundConfig.swift:49`), with display names "Grok" and
  "Gemini". Its comment already expects this ("a later harness (Gemini, Grok, Qwen) adds a case
  here").
- Every `switch` over `Harness` or `ModelFamily` gains both arms. The compiler finds them. As of
  this spec they are in RoundConfig, RoundConfigEditor, IntakeService, CoverageSeries,
  SeatActivity, FailureDiagnosis, Harness, RoundExecutor, FlightControl/IndexExtraction and
  FlightControl/RoutingRule.
- **L3 routing and the capability index must not route swarm tasks to these harnesses.** They are
  not `AgentID`s. Where an L3 switch needs an arm, map the harness to "not an agent harness"
  explicitly. Don't fake a catalog.

### 3.2 Model availability
- Generalize `AvailableModels`, which today has fixed `codex`/`claude` fields, into a map
  `[Harness: ModelChoice]`, with defaults:
  - grok: `grok-4.6`, effort `high`;
  - gemini: the Pro model Task 1 finds, effort `""`.
- Keep the existing call sites working.
- Detection:
  - The binary must be on the login-shell `PATH`, as for claude and codex.
  - **The account must be signed in**: `grok models` must not print "not authenticated", and
    Gemini must pass a cheap check that Task 1 finds.
  - A missing or signed-out harness is shown in the editor as unavailable, with a reason ("Grok:
    run `grok login`"). It is never silently dropped, and never offered and then failed at round
    time.
- The model list comes from `grok models` and Gemini's equivalent, cached per launch, so the
  Rounds editor's model field becomes a picker for these two.

### 3.3 Headless commands (`HarnessCommand.build`)
These mirror the claude and codex builders and their isolation reasoning. Every flag below is
confirmed by a probe in Task 1 before it is coded.

**Grok, read-only seat:**
```
grok -p <prompt> --output-format streaming-json   (or json; pick what carries the final structured result + session id)
     --json-schema <schemaJSON>   -m <model>   --reasoning-effort <effort>
     --cwd <seat cwd>   --disable-web-search
     --deny <every write/exec tool rule>   [--resume <id> | --session-id <new uuid>]
     + whatever isolates it from ~/.grok config, plugins, MCP servers and hooks (cf. claude --restricted / codex --ignore-user-config)
```
- Give `bv`/`br` read access the way claude seats get it today. FD hands it pre-run files, with
  no `bv` (see `ShadowAnalytics` in RoundPrompts.swift).
- Web search stays off. Planning seats work from the repo and the files FD hands them, as the
  claude and codex seats do.

**Gemini, read-only seat:**
```
gemini -p <prompt> -o stream-json -m <model> --approval-mode plan --skip-trust
       --include-directories <intake dir>,<readable dirs>   [--session-id <uuid> | --resume <?>]
       + isolation from ~/.gemini settings, extensions, MCP servers (find the flags in Task 1)
```

**Integrator (write mode):**
- Grok: allow edit tools only within the work dir, deny everything else, the same as the claude
  integrator's Read/Edit/Write-only set.
- Gemini: `--approval-mode auto_edit` scoped by `--cwd` / include-dirs.
- `writeInWork` with a resume ID stays refused (`resumeNotSupportedForWrite`), as it is now.

**Environment:** follow `ClaudeUserEnv` and `CodexUserConfig`.
- Carry over only what authentication and the provider endpoint need.
- Never drop a proxy setting that the CLI's own config would have applied.
- Look for these in `~/.grok/config.toml` and `~/.gemini/settings.json`.

### 3.4 Structured output
- **Grok:** use `--json-schema`. If the strict schema (every field required, nullable unions) is
  rejected, write the smallest transformation that grok accepts and that still validates the
  same instances. Pin it with a fixture.
- **Gemini, without a schema flag:**
  1. The prompt gets a **schema appendix**: the JSON Schema verbatim, plus "Reply with one JSON
     object that validates against this schema and nothing else." This is generated from
     `schemaJSON`, so it never drifts.
  2. FD extracts the JSON from the final message: the whole message, or a single fenced
     `json` block, and nothing else.
  3. Then FD validates it against the schema. This is a new IntakeKit `SchemaValidator`, covering
     the subset the intake schemas use. The existing change-set validator still runs after it.
  4. **One repair retry.** On a parse or validation failure, FD resumes the same session once with
     "Your reply did not validate: <first error>. Reply again with only the corrected JSON."
  5. A second failure diagnoses as `invalidOutput` with the error text. No further retries.
- The repair retry is generic and keyed by a harness capability (`hasNativeSchema`), so a future
  harness without a schema flag gets it for free.

### 3.5 Session identity and resume
Each seat's conversation must resume **its own** session, never another seat's. Seats run in
parallel in the same project.
- **Grok:** start each fresh seat with `--session-id <uuid FD mints>`, record that id, and resume
  with `--resume <uuid>`. The UUID check in `--resume` means this is never mistaken for a title
  match.
- **Gemini:**
  - Start with `--session-id <uuid>`.
  - Task 1 checks whether `--resume <uuid>` accepts a session id, despite the help text saying
    "latest or index".
  - **If it does not, Gemini seats never resume.** Every round runs fresh, and RoundExecutor
    passes the seat's own previous output in the prompt. That path exists in principle for
    cross-check seats, so reuse it.
  - **Never use `latest` or an index.** With parallel seats it picks another seat's conversation.
- `HarnessOutput.parse` returns the session id: from the output stream if the CLI reports one,
  otherwise the minted UUID.

### 3.6 Live activity (`ActivityParser`)
- Parse each CLI's streaming events into `SeatActivity`: headline, tools used, thinking, last
  event time, tokens and cost if reported.
- Capture real streams in Task 1, and write the parser only against those captured lines, as
  `ActivityParserTests` does for claude and codex.
- `rateLimitWindows` stays nil for both. Neither CLI reports usage windows.

### 3.7 Failure diagnosis (`FailureDiagnosis`)
- Map each CLI's real error output (stderr, and the error events in the stream) to `rateLimited`,
  `authExpired`, `timeout`, `harnessError` and `invalidOutput`.
- Provoke each case in Task 1 where that's cheap:
  - auth: run with an empty HOME copy;
  - harness error: pass a bad model name;
  - rate limit: only if it happens to occur. Otherwise match the documented messages, and record
    that they are unverified.
- SuperGrok draws on a weekly shared pool and Gemini on 5-hour windows, so `rateLimited` is a
  likely real failure. The seat row must say so.
- Retry at the reset time, or move the seat to another slot. Both existing paths apply.

### 3.8 Prompts
- **Audit `RoundPrompts.swift` for harness-specific wording.** That covers tool names, `-p`
  assumptions and claude/codex-only instructions. Make any of it harness-neutral, or branch on
  the harness.
- No tuning beyond that in this spec. The live rounds in §5 show what Grok and Gemini actually
  need.

### 3.9 Data use (a doc note, not code)
xAI and Google consumer plans may use prompts to improve their models unless the account opts
out. Add a line in the Rounds editor's harness help, and in `docs/FOLLOWUPS.md`:
"Check xAI's and Google's data settings before seating these on private repos." Don't link to a
specific settings page; the URLs change.

### 3.10 UI
- **Rounds editor:** Grok and Gemini appear in every harness picker. The model becomes a picker
  from the detected list. Effort is shown only where the harness supports it (hidden for Gemini
  unless Task 1 finds a flag).
- **Presets:** add none by default. Cross-check's "second model family" picker includes both.
- **Seat rows, the LCD, the coverage cell and the phone:** use `ModelFamily.displayName`. No
  copy changes beyond that. UI wording rules apply: *agent*, never "seat"; *tasks*, never
  "beads".

## 4. Tasks (for the implementing session)

**Execution shape (max parallelism):**
- **Track 0 — contract** (lands first, small):
  - the `AgentProfile` protocol and its value types;
  - the `.grok`/`.gemini` cases on `Harness` and `ModelFamily`, plus every exhaustive switch arm.
    New arms may `fatalError("track G/M")` only behind a test-visible stub;
  - the schema-repair seam (`hasNativeSchema`);
  - `HarnessRequest.account`.
  - **As built (2026-10-07):** `Sources/IntakeKit/Agents/AgentProfile.swift` (protocol, value
    types, `AgentProfiles`, stubs marked by `AgentProfileStub.trackP/G/M` via `unimplemented`);
    `HarnessCommand.build` is `throws(HarnessCommandError)` and throws `.harnessNotImplemented`
    for grok/gemini; `AvailableModels` is a `[Harness: ModelChoice]` map gated by
    `AgentProfiles.headlessReady` (each track adds its harness there); the repair seam is
    `SchemaRepair.retry` (`Sources/IntakeKit/SchemaRepair.swift`), already called from
    `RoundExecutor.attempt`; the L3 mapping is `Harness.agentHarnessID` (nil for grok/gemini).
    No new arm uses `fatalError`. Pinned by `AgentProfileContractTests`.
- **Then three parallel tracks, each in its own worktree:**
  - **Track P:** claude and codex profiles, migrating every duplicate onto them (§3.0).
    - **As built (2026-10-07):** `ClaudeProfile.swift` and `CodexProfile.swift` beside
      `AgentProfile.swift`; the merged error table is `AgentErrorVocabulary` (one kind table
      with a failure kind AND a transient flag per spelling, plus the phrase rules
      `FailureDiagnosis` used). Sign-in checks are `claude auth status` (JSON `loggedIn` + exit 0)
      and `codex login status` (exit 0), probed on claude 2.1.293 and codex-cli 0.160.0; they
      are filled in but not yet wired into detection, which stays PATH-only for claude/codex.
      `ModelChoice.account: AgentAccountRef?` carries a seat's account (nil = built-in, absent
      from the JSON); the Rounds editor shows an Account picker only for a harness with a
      non-built-in account in preferences. `HarnessCommand.environment(for:base:home:account:)`
      builds the child environment through the profile; a bound codex seat also takes its
      `service_tier` from its own `config.toml`. Pinned by `AgentProfileMigrationTests`.
  - **Track G:** Grok profile + harness.
  - **Track M:** Gemini profile + harness.
- **Integration:**
  - merge P, then G, then M;
  - the Rounds editor's account and harness pickers;
  - the live round (§5).

Tracks G and M do every non-auth step first. Their probes wait for Nate to sign in.

**1. Probes. They come first and are recorded in §10 before any code depends on them.**
- **Wait for sign-in.** Nate signs in to both CLIs first (`grok login`, then the `gemini`
  interactive first run). If either is signed out, stop and ask Nate. Never try to sign in
  yourself.
- **Which Gemini binary.** Decide between `gemini` and `agy` (§2 caveat).
- **Probe both CLIs.** Use one-line prompts in a scratch dir under `$HOME` and spend minimal
  tokens. Clear `CLAUDE_CODE_CHILD_SESSION` with `env -u`. For each CLI, capture into
  `Tests/FlightDeckTests/Fixtures/Intake/`:
  - the headless run with the final structured result: `grok-p-schema.jsonl` and
    `gemini-p-json.json`;
  - a streaming run, for the activity parser: `grok-stream-activity.jsonl` and
    `gemini-stream-activity.jsonl`;
  - the session id, wherever it shows up;
  - a resume by id. Prove it continues the same conversation: ask "what number did I give
    you" after giving one.
  - the read-only enforcement. Ask the model to create a file, and verify that no file appears.
  - an auth failure and a bad-model failure, captured as stderr fixtures;
  - the isolation flags that drop user config, plugins, MCP servers and hooks;
  - the model-list command.
- **Strict schemas.** Grok: run `--json-schema` with the real `triage-schema.json` and one round
  change-set schema (strict). Gemini: run the schema appendix with one repair retry.
- **Fixtures are synthetic.** The repo is public, so no real project content goes in them.
  Probe against a scratch repo with one dummy file.

**2.** The `Harness` and `ModelFamily` cases, plus the exhaustive arms. Use the L3 "not an agent
harness" mapping.

**3.** `AvailableModels` as a map, with sign-in-aware detection and the cached model lists.

**4.** `HarnessCommand` builders for both (read-only and integrator) and the environment builders.

**5.** `HarnessOutput.parse`, plus the generic schema appendix, `SchemaValidator` and one repair
retry.

**6.** Session minting, recording, resume, and the Gemini never-resume fallback if Task 1 needs
it.

**7.** `ActivityParser` arms and `FailureDiagnosis` arms.

**8.** The `RoundPrompts` audit.

**9.** The Rounds editor UI, the cross-check family picker and the data-use note.

**10.** Live end-to-end rounds (§5). Then docs: an as-built section in this spec, and a FOLLOWUPS
entry.

## 5. Test plan

**Unit tests** (`FD_TEST_FILTER=<Class> ./scripts/test-unit.sh`, foreground). A filtered run
ends `Executed N tests, with M failures`. The script can exit 0 on failure, so read that line and
grep `error:`.

| Area | Test | Pins |
|---|---|---|
| Commands | `HarnessCommandGrokTests`, `HarnessCommandGeminiTests` | Exact argv for fresh, resume and write modes: schema, model, effort, cwd, read-only flags, isolation flags, minted session id. A write-mode request with a resume id is refused. |
| Read-only | same classes | No read-only argv contains an allow rule for any edit or exec tool. Web search is off. The Gemini approval mode is `plan`. |
| Output | `HarnessOutputGrokTests`, `HarnessOutputGeminiTests` | Parse the captured fixtures into (session id, structured JSON). Gemini: JSON in a fenced block, prose plus JSON (rejected), two JSON objects (rejected). |
| Schema | `SchemaValidatorTests` | Run against the real intake schemas: a valid instance passes; a missing required field, a wrong type, an extra property and a bad enum each fail and name the path. |
| Repair | `SchemaRepairRetryTests` | One retry on invalid output, resuming the same session. A second failure gives `invalidOutput`. Never more than one retry. Harnesses with native schema support never retry. |
| Resume | `SeatResumeTests` | Two parallel seats on the same harness each resume their own minted id. A Gemini seat on the never-resume path gets its previous output in the prompt and no `--resume`. Fails if `latest` or an index ever appears in argv. |
| Activity | `ActivityParserTests` (extend) | Each captured stream folds to the expected headline, tools and last event time. Unknown event types are ignored, not crashed on. |
| Diagnosis | `FailureDiagnosisTests` (extend) | The captured auth and bad-model stderr map to `authExpired` and `harnessError`. Documented rate-limit text maps to `rateLimited`; mark it unverified until a real one is captured. |
| Availability | `AvailableModelsTests` | A missing binary gives "unavailable: not installed". Signed out gives "unavailable: run `grok login`". The model list is parsed from the captured `grok models` output. Map-based defaults keep the old claude and codex behaviour. |
| Families | `CoverageSeriesTests`, `CrossCheck` tests | Grok and Gemini count as distinct families. A claude+grok drafter pair is cross-family. |
| Decode | `IntakeCodingTests` | An intake written by an older build (claude/codex only) still decodes. The new raw values round-trip. |
| Terms | `TerminologyGuardTests` | Every new view passes. |

**Live tests.** They are skipped by default and spend tokens, so run each once (the
`ROUNDS_LIVE`-style gate in `RoundsLiveProbeTests`):
- `GrokPlanningLiveTests`: one real read-only drafter run and one resume, on a scratch repo.
- `GeminiPlanningLiveTests`: the same, plus the repair-retry path. Force it with a schema the
  first answer is unlikely to satisfy, or with a fixture.
- One **real Refine round** with drafters claude + grok and a gemini reviewer, on a scratch
  intake. Record the round outcome, each seat's duration and tokens, and whether the cross-check
  coverage numbers make sense. This is the evidence for success criteria 2, 3 and 6.

**UI tests.** These run only on the UI-test Mac, never on this Mac:
`FD_UITEST_ONLY="FlightDeckUITests/<RoundsEditor class>" ./scripts/smoke-remote.sh`. Neither CLI
is signed in on the UI-test Mac, so UI tests must use the fixture or availability seam, and must
not need real accounts.

**Full suite:** one `./scripts/test-unit.sh` at the end, which ends with
`** SHARDED UNIT RUN PASSED|FAILED`. Known load flakes are listed in FOLLOWUPS.

## 6. Out of scope

- Grok and Gemini as Flight Deck tab agents, or as L3 swarm routing targets: `AgentID`, adapters,
  capability-index catalogs, usage meters and rollover. That is a later spec; it builds on this
  harness work.
- Tuning prompts per model beyond what the live round shows is broken.
- Any change to the claude or codex harnesses beyond the refactors this needs (the
  `AvailableModels` map, the generic repair retry).

## 7. Risks

- **Strict schema rejection (Grok)** or **unreliable JSON (Gemini)**. Covered by §3.4. If Gemini
  fails both attempts often in the live round, record the rate. Gemini seats then stay usable for
  reviewer roles only, and the editor warns.
- **No resume by id (Gemini).** The fresh-every-round fallback costs context and tokens. Record
  the cost from the live round.
- **CLI drift.** Both CLIs auto-update (grok has `update`; gemini is from Homebrew). Pin the probe
  date and version in every comment that relies on CLI behaviour, as the claude and codex
  builders do. A drift-gate row in `scripts/test-adapters.sh` would be nice to have, but is not
  required.
- **Consumer data use.** See §3.9.

## 8. Rules for the implementing session

- **Workspace setup.**
  - Work in a worktree (`git worktree add .claude/worktrees/planning-grok-gemini -b planning-grok-gemini master`).
  - Symlink `vendor/{boringssl,ghostty,fd-abduco}-artifacts` and `scripts/local.env` from the main
    checkout.
  - Apply the signing override with
    `git -C <main checkout> diff project.yml | git apply`, and never commit it.
- **Never run UI tests on this Mac.** They run on the UI-test Mac via `smoke-remote.sh`.
- **Process safety.**
  - Never launch a bundle from DerivedData.
  - Never `defaults delete`.
  - Never `git stash`.
  - Commit by path.
  - Never sign in or out of any CLI.
- **The repo is public.**
  - No host names, IPs, logins or real transcripts in commits.
  - Fixtures are synthetic.
  - The UI-test machine is "the UI-test Mac".
- **Commits.**
  - Messages are lowercase imperative, with the trailer `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
  - Comments explain WHY and name the failure prevented (docs/CONVENTIONS.md).
- **TDD.** Confirm each test fails before the fix lands.

## 9. Files (expected)

- `Sources/IntakeKit/Intake.swift` (`Harness`), `RoundConfig.swift` (`ModelFamily`, `AvailableModels`)
- `Sources/IntakeKit/Harness.swift` (builders, `HarnessOutput`), a new `Sources/IntakeKit/SchemaValidator.swift`
- `Sources/IntakeKit/RoundExecutor.swift` (session minting, repair retry, never-resume fallback)
- `Sources/IntakeKit/SeatActivity.swift`, `FailureDiagnosis.swift`, `CoverageSeries.swift`, `RoundPrompts.swift`
- New `Sources/IntakeKit/GrokUserConfig.swift`, `GeminiUserEnv.swift` (environment carry-over), if needed
- `Sources/FlightDeck/Intake/IntakeService.swift` (detection), `RoundConfigEditor.swift`
- `Sources/IntakeKit/FlightControl/IndexExtraction.swift`, `RoutingRule.swift` ("not an agent harness" arms)
- `Tests/FlightDeckTests/Intake/…` and `Tests/FlightDeckTests/Fixtures/Intake/{grok,gemini}-*`

## 10. Probe results (filled in by Task 1)

| Probe | Grok | Gemini |
|---|---|---|
| Binary chosen | | `agy` (Antigravity CLI), `~/.local/bin/agy`. Not `gemini`: Google stopped serving AI Pro accounts from it on 2026-06-18. |
| Version / date | | 1.2.3, then 1.3.1 (self-updated), 2026-10-07. 1.3.1 changed `--print-timeout`'s default from 5m to 0 (wait for the turn) and widened `--effort` to `low…max`. |
| Signed-in check command | | `agy models`. Signed out: exit 1, stderr "Error: Please sign in to view available models. Launch the CLI without arguments to sign in." — and it does NOT start a sign-in. A signed-out `agy -p` DOES (opens the browser, waits 60 s for a code). `agy mcp list` / `agy plugin list` need no sign-in. |
| Model list command and output | | `agy models`: `<id>\t<display name>` per line on stdout, "Fetching available models..." on stderr. Lists Gemini 3.8/3.7/3.6 Flash (high/medium/low), Gemini 3.1 Pro (high/low), Claude Opus/Sonnet 5.5, GPT-OSS 120B. The harness keeps only `gemini-*` ids; default `gemini-3.1-pro-high`. |
| Strict `--json-schema` / schema appendix | | Native `--json-schema`, enforced; the answer is `structured_output` (the `response` text can carry extra keys, so it is never used). Gemini refuses `null` inside `enum` (400 INVALID_ARGUMENT on the raw triage schema); `GeminiSchema` rewrites each nullable enum to an equivalent `anyOf`, which agy accepted with the triage and integrate schemas. Passed inline. No schema appendix and no `SchemaValidator`. |
| Session id source | | `conversation_id` on `init`, on every `step_update`, and on the `result`. No flag to pre-assign one, so FD records the reported id. |
| Resume by id | | `--conversation <id>`: the same id comes back and the turn remembers the earlier one (asked for 417, got 417). Never `--continue` (most recent = another seat's). |
| Read-only enforcement verified | | Yes, but NOT by `--mode plan`: with permissions skipped, plan mode wrote NOTES.md and edited README.md. In the default mode every write needs a permission headless mode cannot grant, so it is auto-denied (nothing written, including `.md`). `--sandbox` lets read-only shell commands run and blocks their writes. Never `--dangerously-skip-permissions`: with it a sandbox-blocked write was retried unsandboxed and succeeded. A denied tool ENDS the turn (SUCCESS, no `structured_output`, `denied_actions`); one resume of that conversation answers, so FD repairs it once. Integrator: `--mode accept-edits` in its work dir edited plan.md; a write to ../OUTSIDE.md was denied. |
| Isolation flags | | None exist. Permission rules (`command(…)`, `read_file(<abs>)`, `write_file(<abs>)`, allow/deny) live in `~/.gemini/antigravity-cli/settings.json` and `~/.gemini/config/projects/`; none are configured here, and a user allow rule for writes WOULD weaken read-only (FOLLOWUP). No MCP servers or plugins configured. |
| Auth-failure text | | Signed out: stderr "Authentication required. Please visit the URL to log in: …", result `{"status":"ERROR","error":"authentication failed or timed out","conversation_id":""}`, exit 1. Signed in but unverified: "Eligibility check failed: Your current account is not eligible for Antigravity. Verify your account to continue." (403 PERMISSION_DENIED), exit 1, no tokens. Both classify as `authExpired`. |
| Bad-model text | | Exit 1. stderr and `result.error`: `invalid model selection (--model "x" --effort ""): model x is not recognized as a known model or custom model in settings`, then the available models. Classified `harnessError`. |
| Rate-limit text | | Not observed. `RESOURCE_EXHAUSTED` / quota / 429 matched, UNVERIFIED. |
