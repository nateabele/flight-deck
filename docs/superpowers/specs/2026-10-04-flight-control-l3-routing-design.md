# Flight Control Level 3 — Routing (L3-R)

Date: 2026-10-04. Status: design approved in brainstorming; spec under review.
Depends on: L3-0 (`2026-10-04-flight-control-l3-overview-contract-design.md`) only.

## 1. Goal

Each task gets a full execution block: which harness, model, knobs and pool to run it on, and
why. You decide this with sentence rules. Planning sessions decide what *kind* of task each one
is, and they can propose new kinds.

**Success criteria:**
1. You write "Use Codex for unit and integration tests, and for complex algorithms" in Settings.
   Flight Deck shows its compiled form. After you confirm it, test-like tasks route to codex.
2. A kind proposed later (for example `snapshot-tests`) routes by the same rule with no recompile.
3. Each released task has a block whose `source` says which rule or fallback chose it.
4. A pinned block is never changed by the router.

## 2. Rules

**Where.** Settings → Flight Control → Routing. There is a global list and a per-project list.
The project list is checked first, then the global list. In each list, the first match wins.

**A rule** has the sentence you wrote and its compiled form:

```json
{"id": "r3", "sentence": "Use Codex for unit and integration tests, and for complex algorithms",
 "compiled": {
   "match": {"any": [
     {"dimension": "test-authoring", "atLeast": 0.5},
     {"dimension": "algorithmic-reasoning", "atLeast": 0.6},
     {"kind": "tests"}]},
   "assign": {"harness": "codex", "model": "gpt-6-sol", "knobs": {"effort": "high"},
              "pool": "codex-subs", "fallbackPool": null}},
 "state": "confirmed", "compiledAt": "…", "compiler": {"harness": "claude", "model": "haiku"}}
```

- `match` supports `any` and `all`, over `{dimension, atLeast}` and `{kind}` terms.
- A kind-name term matches a kind and every kind merged into it.
- When the sentence does not name a model, the compiler picks the adapter's default model and
  says so in the compiled form.
- `fallbackPool` exists for rules that name an explicit spill target ("…, else claude-subs").

**States:** `draft` → `compiled` (waiting for you) → `confirmed`, or `failed` (shown inline with
the reason). Only `confirmed` rules route. Editing the sentence moves the rule back to `draft`.

**Storage.** Global rules in preferences (`PreferencesStore`, the Flight Control section).
Project rules in `.flightdeck/routing.json` in the repo, so they are versioned with the project.

## 3. The rule compiler

- One cheap headless model call per sentence (default `claude -p` haiku, configurable). It gets
  the sentence, the dimension list, the project's kind registry, every enabled adapter's model
  catalog and knob schema, and the pool list.
- The output is constrained by a JSON schema. A validator then checks:
  - every dimension and kind exists;
  - the harness is a registered adapter;
  - the model is in that adapter's catalog;
  - the knobs pass the adapter's knob schema;
  - the pool exists and belongs to that adapter.
- If validation fails, the rule is `failed` with the first error. The compiler is not retried
  automatically.
- The compiled form is shown under the sentence in plain words: "matches test-authoring ≥ 0.5,
  algorithmic-reasoning ≥ 0.6, or kind *tests* → codex · gpt-6-sol · effort high · pool
  codex-subs". There is a **Confirm** button.

## 4. Classification at encode

The intake encode step already writes tasks through `ChangeSet` → `BeadWriter`. L3-R adds:

1. **The encode prompt gets the project's kind registry** (ids, descriptions, dimension weights).
2. **Each created task gets a `kind`**: an existing kind id, or a **proposal**
   `{name, description, dimensions}`. `Triage.swift`'s JSON schema gains `kind` and
   `kindProposal` on the create op.
3. **A proposal is added to the registry** as `origin: planning`, `status: active`. It is usable
   at once and marked *new* in Settings until you look at it. A proposal whose name normalizes to
   an existing kind id reuses that kind.
4. **The router runs** on each task (§5). `BeadWriter` writes the block with `--agent-context`,
   keeping any other `agent_context` keys.

A cross-check or polish round may change a task's kind. The block is re-routed when the kind
changes, unless it is pinned.

## 5. The router

A pure function: `assign(kind, project, rules, registry, index, catalogs, pools) -> Assignment`.

1. Resolve the kind. Follow `merged:` links.
2. Walk the project rules, then the global rules. The first confirmed rule whose `match` holds
   wins. A `{dimension, atLeast}` term holds when the kind's weight for that dimension is at
   least the threshold.
3. **No rule matched:** ask `CapabilityIndex.rank(kind, candidates)`. Candidates are the models
   of every enabled adapter that has at least one pool. Ignore results below the confidence floor
   (default 0.5). Take the best and record `source.by = "index"` with its score.
4. **The index is empty, stale or below the floor:** use the project's default agent and its
   default model, and record `source.by = "default"`.
5. Assign the pool: the rule's pool, or for the index/default path, the adapter's default pool.

**When the router runs:**
- at encode, for each created task;
- **at launch**, again for every task that is not pinned, so rule edits made after release
  apply (L3-S calls it);
- when a kind is merged or re-weighted, for the open tasks of that kind that are not pinned.

**Spill (called by L3-S at spawn, not by encode).** `spill(block, exhausted: Set<PoolID>)`
re-runs steps 2–5 with every exhausted pool removed. A rule's `fallbackPool` is tried first.
The result has `source.by = "spill"` and a reason like "codex-subs over hard limit →
claude-subs/opus". **A spill never rewrites the task's stored block.** It applies to that one
spawn only. A pinned block never spills: it waits.

## 6. Kind management UI

Settings → Flight Control → Task kinds, per project:
- a list of kinds with origin, status, the dimension weights as small bars, and the count of open
  tasks;
- **Rename**, **Re-weight** (sliders per dimension), and **Merge into…**;
- *new* badges on planning-proposed kinds you have not opened.

## 7. Rule hints (from L3-I)

Each confirmed rule can show one dismissible hint from `CapabilityIndex`: "gemini-x scores 0.14
higher on test-authoring (confidence 0.8)". L3-R draws the hint. L3-I computes it (L3-I §6).
Hints never change routing. A dismissed hint stays dismissed until the index snapshot changes.

## 8. Error handling

- An unknown harness or model in a stored block (for example, an adapter was removed): the task
  is "unroutable: <reason>" and the swarm skips it. Re-routing fixes it if it is not pinned.
- Compiler unavailable (no CLI, no network): new rules stay `draft`; confirmed rules keep
  routing.
- A missing or invalid `.flightdeck/routing.json`: project rules are treated as empty, and
  Settings shows the parse error.

## 9. Testing

- **Router:** table tests over (rules × registry × index × catalogs × pools), covering first
  match, `any`/`all`, merged kinds, index fallback, the confidence floor, default fallback, spill
  with and without `fallbackPool`, and pinned blocks.
- **Compiler:** recorded model outputs as fixtures, both valid and each validation failure. One
  live probe, skipped by default (`ROUTING_LIVE=1`), spends tokens.
- **Encode:** the existing intake round seams with a recorded encode output that contains a
  `kind` and a `kindProposal`. Assert on the registry write and the `--agent-context` argv.
- **UI:** XCUITest cases for the Routing and Task kinds panes against fixture data (add,
  compile, confirm, fail, merge), with `XCUIScreenshot` attachments.

## 10. Provides at integration

A real `Router` and `KindRegistry`, the `BeadWriter` change, and the Settings panes.

## 11. Files

- `Sources/IntakeKit/FlightControl/Router.swift`, `RuleCompiler.swift`, `RuleValidator.swift`,
  `KindRegistryStore.swift`
- `Sources/IntakeKit/Triage.swift`, `ChangeSet.swift`: `kind` and `kindProposal`
- `Sources/FlightDeck/Intake/BeadWriter.swift`: `--agent-context` with the merge
- `Sources/FlightDeck/Preferences/UI/FlightControlRoutingPane.swift`, `TaskKindsPane.swift`
- `Tests/FlightDeckTests/FlightControlL3/Routing/…`, `UITests/FlightDeckUITests/RoutingUITests.swift`

## 12. As built (deviations recorded while planning, 2026-10-04)

Plan: `docs/superpowers/plans/2026-10-04-flight-control-l3-r-routing.md`.

1. The create op carries the kind as `taskKind` (not `kind`, which is `addEdge`'s edge kind in the
   same flat op schema) and `kindProposal`; proposal weights travel as `[{dimension, weight}]`.
2. Pools come from the L3-0 contract (`PoolSummary`, `PoolDirectory`, `DefaultPoolDirectory` in
   ContractValues/ContractProtocols; `<agent>-default` pools until L3-U's store conforms). Rule
   hints (`RuleHint` / `RuleHintSource` / `NoRuleHints`) are this branch's seam until L3-I
   conforms. `NullCapabilityIndex` stands in for L3-I's index.
3. `RuleRouter.assign` (the contract's non-optional `Router.assign`) returns
   `Assignment.unroutable(kind:reason:at:)` for an unroutable task: empty harness, model and pool,
   and a reason reading `unroutable: …`. Consumers detect it with `Assignment.isUnroutable`.
   `RouterCore.assign` returns `RouteOutcome`; encode never writes an unroutable block (the codec
   refuses it).
4. Global rules compile against the seed kinds; project rules against the project registry.
5. An unclassified create (no kind, unknown id, or a proposal named only punctuation) routes as
   `implement-simple`, its reason prefixed `no kind from planning;`.
6. Claude's catalog is its `--model` aliases (opus first); codex's is `model/list` from a
   short-lived app-server, cached per launch; codex's knob schema is the union of its models'
   efforts.
7. A compiled rule always names a pool (the agent's default when the sentence names none).
8. Global rules are stored at `Preferences.flightControlRouting`; Settings gains a Flight Control
   tab with Routing and Task kinds sections. Rules can be reordered.
9. Kind re-routing runs on merge and re-weight over `br list --status open --json`; released
   tasks' edits carry no kind. `br update --agent-context` gets `--force` only when the new value
   is under half the old length (br 0.6.0 refuses that otherwise).
10. Routing UI tests run from `scripts/test-routing-ui.sh` and skip under `smoke.sh`; they are gated on `TEST_RUNNER_FLIGHTDECK_ROUTING_UI=1`.
11. Spill reasons say "exhausted", not "over hard limit": the router knows only that a pool was excluded.
12. Controller rulings during the build:
    (a) `extension PoolDirectory { defaultPools(for:) }` in RoutingSeams.swift holds the one copy
    of the default-pool loop.
    (b) `extension TaskKind { isLive; weightsText }` in TaskKind+Routing.swift; kinds with no
    weights print `none`.
    (c) The compiler prompt's dimension bullet was tightened after the live haiku probe compiled
    the spec sentence to kind terms (run 1 failed, run 2 passed). It deliberately prefers dimension
    terms over the spec §2 example's `{kind: tests}` form.
    (d) The re-route note counts writer-side pinned skips and names failed task ids.
    (e) Release re-checks cancellation after the routing await.
13. (Plan deviation 14.) L3-0's `testUnsupportedCatalogYieldsAnEmptyDisabledCatalog` was rewritten against a fake.
14. (Plan deviation 15.) The encode fixture is written in the shape of an encode output, not recorded live.
15. Follow-up ops (non-create) carry no kind: the schema forces `taskKind` null. Any block they
    would need routes as `implement-simple` with "no kind from planning;" (review finding M7).
