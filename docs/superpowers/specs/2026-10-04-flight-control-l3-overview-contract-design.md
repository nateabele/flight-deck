# Flight Control Level 3 "Operate" — overview and shared contract (L3-0)

Date: 2026-10-04. Status: design approved section by section in brainstorming; spec under review.
Base: master `503a867`. Handoff: `docs/FLIGHT-CONTROL-LEVEL3-HANDOFF.md`.

## 1. Goal

Level 3 makes Flight Deck *run* the swarm, not only watch it. Released tasks go to agents.
Each task runs on a model that suits it. No agent stalls on a usage cap while another account
still has headroom.

**Success criteria:**
1. You release an intake and launch a swarm with a concurrency cap. Flight Deck claims ready
   tasks, gives each to an agent with the right harness, model and account, and keeps the swarm
   fed until nothing is ready.
2. Each task carries a structured execution block that says how to run it and why.
3. You write routing rules as sentences. Flight Deck compiles them and routes by them. When no
   rule matches, a benchmark-fed capability index routes instead.
4. An account that crosses its soft usage threshold takes no new work. An agent on an account
   that crosses its hard threshold is handed off to a fresh agent on the next account.
5. You can see contested files and blocked commits on the sessions themselves.

## 2. Five specs, built in parallel

| Spec | File | Owns |
|---|---|---|
| **L3-0 Contract** | this file | `ExecutionBlock`, kind registry, adapter capabilities, protocols, fakes, fixtures |
| **L3-R Routing** | `2026-10-04-flight-control-l3-routing-design.md` | rule sentences → compiled rules, `Router`, encode-time classification, kind proposals |
| **L3-I Capability index** | `2026-10-04-flight-control-l3-capability-index-design.md` | dimensions, sources, refresh run, scoring, rule hints |
| **L3-U Usage & rollover** | `2026-10-04-flight-control-l3-usage-rollover-design.md` | pools, meters, thresholds, leases, hand-off |
| **L3-S Swarm** | `2026-10-04-flight-control-l3-swarm-design.md` | launch, keep-it-fed loop, reuse, claim, first prompt, annotations, contested, phone, disable |

**Build order.** L3-0 lands first, alone, in one small branch. After it merges, L3-R, L3-I, L3-U
and L3-S start at the same time, each in its own worktree. Each builds and tests only against
L3-0's protocols and fakes. None imports another's concrete types.

```
            L3-0 contract (merge first)
     ┌──────────┬──────────┬──────────┐
   L3-R       L3-I       L3-U       L3-S        ← parallel worktrees
     └──────────┴────┬─────┴──────────┘
              integration branch: swap fakes for real conformers, run the UI suite
```

**Why the contract lands first.** If four branches each invent the execution block, they
collide at merge. This is the "wire enum cases are atomic" problem across branches. One small
commit that freezes the shapes removes it.

**Integration.** The last step is one short branch. It wires the real conformers into
`AppDelegate` in place of the fakes and runs the L3-S UI suite against the real stack with a
fixture backend. Each spec lists what it provides at integration.

**Outside dependency.** The OpenCode adapter is built in its own workstream (branch
`opencode-adapter`). It adds `AgentID.opencode`. Level 3 depends on it only through the adapter
capabilities in §5. Level 3 does not wait for it: everything is tested with claude, codex and a
fake adapter.

## 3. Decisions locked in brainstorming

- **Shared main by default** (prior ruling). Contested visibility is required.
- **Task kinds are dynamic**, per project, and anchored to stable capability dimensions.
  Planning sessions may propose new kinds.
- **Harness is any registered adapter**, validated against the adapter registry, never a
  hard-coded enum.
- **Routing rules are sentences**, compiled by an LLM into a structured form, which you confirm.
  Only the confirmed compiled form routes.
- **The capability index is a fallback and gives rule hints.** Rules always win.
- **A full pool spills over** to the next-best model, unless the block is pinned.
- **Two thresholds.** Soft: no new leases. Hard: running swarm agents are handed off.
- **Hand-off is a fresh agent with a transcript pointer.** Nothing is migrated.
- **Leases go to the first account in order under the soft threshold.**
- **The swarm is kept fed.** FD claims and spawns on its own after you click Launch, until
  nothing is ready or you pause.
- **Reuse before spawn.** An idle swarm agent with the same configuration gets the next task
  after a context reset.
- **No swarm view.** Swarm state appears on sidebar rows, the project header and the Observe
  drawer.
- **Phone:** status plus pause/resume, and hand-off confirmation when that setting is on.
- **Disable** stops FD and keeps the repo. "Remove from repo…" is a separate action.
- **Nudge and send-mail are Level 3** (this settles the Observe spec's disagreement).
- **UI tests are automated** with XCUITest and screenshots. The maintainer's checklist is a short set of
  real tasks.

**Deferred (not in these specs):** Agent Mail inbox (handoff §3 E), tending actions other than
hand-off (D), the task-graph convergence gauge (F), worktree mode, and remote-host placement
(the block reserves a `host` field, always null in v1).

## 4. The execution block

Stored at `agent_context.flight_deck.execution` on each br task. Probed on br 0.6.0: arbitrary
JSON in `--agent-context` round-trips through `br show --json` and `br list --json`.
`br ready --json` does **not** include `agent_context`, so readers use `br list --json`.

```json
{"v": 1,
 "kind": "snapshot-tests",
 "harness": "codex",
 "model": "gpt-6-sol",
 "knobs": {"effort": "high"},
 "pool": "codex-subs",
 "source": {"by": "rule", "ruleId": "r3", "reason": "test-authoring 0.8 → codex", "at": "2026-10-04T18:00:00Z"},
 "pinned": false,
 "host": null}
```

| Field | Meaning |
|---|---|
| `v` | Schema version. Readers reject a higher major version and leave the task alone. |
| `kind` | An id in the project's kind registry (§6). Classification, set at encode. |
| `harness` | An `AgentID` raw value. Must name a registered adapter. |
| `model` | An id from that adapter's model catalog. |
| `knobs` | Adapter-declared options (effort, agent/persona). Validated by the adapter. |
| `pool` | A capacity pool id (L3-U). **Not an account.** The account is picked at spawn. |
| `source.by` | `rule`, `index`, `default`, `spill` or `manual`. |
| `pinned` | True after a manual edit. The router never overwrites a pinned block. A pinned block never spills. |
| `host` | Reserved for remote hosts. Always null in v1. |

**Other keys in `agent_context` are kept.** Writers read the whole JSON, change only
`flight_deck.execution`, and write the whole JSON back. This keeps the existing `br` governing
instructions intact.

**Codec.** `ExecutionBlockCodec` (pure, IntakeKit) decodes and encodes, and reports a typed error
for each invalid field. An invalid block is shown on the task as "unroutable: <reason>" and the
swarm skips it. It is never silently repaired.

## 5. Adapter capabilities

A separate `@MainActor` protocol, `AgentRoutingCapabilities`, with one conformer per agent, held in `RoutingCapabilityRegistry` (`Sources/FlightDeck/FlightControl/AgentRoutingCapabilities.swift`). Not on `AgentAdapter`: adapters are built per account, these answers are per agent. Session-specific calls take the `Session`. `RoutingCapabilityRegistry.standard()` switches exhaustively over `AgentID`, so a new agent case must state its answers to compile.

| Capability | Type | Used by |
|---|---|---|
| `modelCatalog()` | `async -> [ModelEntry]` (id, display name, knobs it accepts) | L3-R validation, L3-I alias mapping |
| `knobSchema` | declared knobs and their allowed values | L3-R, launch sheet |
| `accountModel` | `.login`, `.providerKeys`, `.none` | L3-U |
| `usageMeterSource(account:)` | `UsageMeterSource?` (§7) | L3-U |
| `transcriptPointer(session:)` | `TranscriptPointer?` (path or command, format, how to read) | L3-U hand-off |
| `resetContext(session:)` | `async throws` | L3-S reuse |
| `launchOverrides` | how model and knobs reach `createSession` | L3-S |

Known values today (verify in each spec's first task):
- **claude:** catalog = aliases plus full ids; knobs = effort; account `.login`; transcript = JSONL
  under the account's `projects/`; reset = `/clear`.
- **codex:** catalog = app-server model list; knobs = effort; account `.login`; transcript =
  rollout path; reset = new thread.
- **opencode** (from the OpenCode workstream, 2026-10-04): catalog = configured providers'
  models as `provider/model`; knobs = `agent`; account `.providerKeys` for hosted providers,
  `.none` for local; usage = no meter (errors only); reset = new session over HTTP.

## 6. Task kinds and capability dimensions

**Dimensions** are a small, stable set that L3-I owns: the axes benchmarks measure. They are
listed in L3-I §2. L3-0 ships the initial list as data, so the other specs can compile against it.

**A kind** is a project-scoped record in the kind registry:

```json
{"id": "snapshot-tests", "name": "Snapshot tests",
 "description": "Write or update snapshot/golden-file tests",
 "dimensions": {"test-authoring": 0.8, "agentic-coding": 0.3},
 "origin": "planning", "status": "active", "createdAt": "…"}
```

- `origin`: `seed`, `planning` or `user`.
- `status`: `active`, `proposed`, or `merged:<id>`. A merged kind resolves to its target, so no
  task needs rewriting.
- **Storage:** `.flightdeck/kinds.json` in the repo. It is versioned with the project, and
  agents in planning rounds can read it. A new project starts from the seed set in L3-0.
- **The seed set:** `implement-simple`, `implement-complex`, `algorithm`, `tests`, `refactor`,
  `docs`, `investigate`, `review`, `ui`, each with dimension weights.

## 7. Protocols

All in IntakeKit (pure, Foundation only) unless noted.

```swift
protocol KindRegistry      { func kinds(project: URL) throws -> [TaskKind]; func propose(_ kind: TaskKind, project: URL) throws -> TaskKind }
protocol Router            { func assign(kind: TaskKind, project: URL, catalogs: AdapterCatalogs, now: Date) -> Assignment; func spill(_ block: ExecutionBlock, kind: TaskKind, project: URL, exhausted: Set<PoolID>, catalogs: AdapterCatalogs, now: Date) -> Assignment? }
protocol CapabilityIndex   { func rank(kind: TaskKind, candidates: [ModelRef]) -> [ScoredModel]; var snapshotDate: Date? { get } }
protocol CapacityReader    { func headroom(pool: PoolID) -> [AccountHeadroom] }
protocol PoolAllocator     { func lease(pool: PoolID) -> AccountLease?; func release(_ lease: AccountLease) }
protocol PoolDirectory     { func pools() -> [PoolSummary]; func defaultPool(for harness: HarnessID) -> PoolID? }
protocol HandoffPlanner    { func request(for agent: SwarmAgentSnapshot) -> HandoffRequest? }
protocol SwarmSpawner      { func spawn(task: TaskRef, block: ExecutionBlock, lease: AccountLease?, firstPrompt: String) async -> Result<SessionRef, SpawnError> }   // FlightDeck target, @MainActor
protocol UsageMeterSource  { var readings: AsyncStream<UsageReading> { get } }
```

`DefaultPoolDirectory` (IntakeKit) is the one built conformer of `PoolDirectory`: one
`<harness>-default` pool per agent, so routing runs end to end before L3-U's pool store exists.

**Value types, as built.** Codable: `ModelRef`, `AssignmentSource`, `AssignmentSourceKind`,
`TaskKind`, `Dimension`, `KindRegistryFile`, `HarnessID`, `PoolID`, `KindID`, `ModelEntry`,
`AdapterCatalog`, `HeadroomState`, `AccountRef`, `PoolSummary`, `UsageWindow`, `UsageReading`,
`TranscriptPointer`, `TaskRef`, `SessionRef`. Not Codable: `ExecutionBlock` (the codec writes it
into `agent_context`, so foreign keys survive), `Assignment`, `AdapterCatalogs`, `ScoredModel`,
`AccountHeadroom`, `AccountLease`, `SwarmAgentSnapshot`, `HandoffRequest`, `SpawnError`.
`AccountRef` is equal by harness + id, so a renamed account still matches its leases and
readings; an id-less local-pool slot compares by label. `Router.assign` cannot fail, so
`Assignment.unroutable(kind:reason:at:)` is the shared way to say "no route"; check it with
`isUnroutable` and read `unroutableReason`. A writer never stores an unroutable block.

## 8. Fakes and fixtures (shipped in L3-0)

- A fake for every protocol in `Tests/FlightDeckTests/FlightControlL3/Fakes/`, each scriptable
  and recording its calls.
- `FakeAdapter` is `FakeRoutingCapabilities` with harness `"fake"`, not an `AgentAdapter` conformer, so "any adapter" is tested from day one.
- `FakePoolDirectory` is scriptable with `summaries` and `defaults`.
- Fixture tasks: br JSON with valid, invalid, pinned and missing execution blocks.
- A fixture kind registry with seed, planning-proposed and merged kinds.
- A fixture usage timeline: readings that cross soft, then hard, then reset.

## 9. Words

UI says *tasks*, never "beads". It says *agent*, never "seat". It says *Flight Control*.
Code identifiers and persisted keys may keep "flywheel". `TerminologyGuardTests` covers every
new view.

## 10. Testing L3-0

Codec round-trips for every field, rejection of each invalid field, preservation of foreign
`agent_context` keys, a merged-kind resolution test, and a compile-only test that each fake
conforms. A live test (skipped by default, `BR_LIVE=1`) writes and reads a block with real `br`
in a scratch repo.

## 11. Files

- `Sources/IntakeKit/FlightControl/`: `Identifiers.swift`, `ExecutionBlock.swift`,
  `ExecutionBlockCodec.swift`, `Dimensions.swift`, `TaskKind.swift`, `ContractValues.swift`,
  `ContractProtocols.swift`
- `Sources/FlightDeck/FlightControl/AgentRoutingCapabilities.swift`: the claude and codex
  "unsupported" stubs live here, not in each adapter, where L3-R/U/S will fill them in
- `Tests/FlightDeckTests/FlightControlL3/` (tests, `Fakes/ContractFakes.swift`,
  `Fakes/FakeRoutingCapabilities.swift`, `L3Fixtures.swift`) and
  `Tests/FlightDeckTests/Fixtures/FlightControlL3/` (`br-list-with-blocks.json`, `kinds.json`,
  `usage-timeline.json`)
- `docs/FOLLOWUPS.md`: replace "Level 3 'Operate' — not started" with pointers to these specs
