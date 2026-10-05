# Flight Control Level 3 — Capability index (L3-I)

Date: 2026-10-04. Status: design approved in brainstorming; spec under review.
Depends on: L3-0 only.

## 1. Goal

Flight Deck keeps its own record of what each model is good at. Online benchmarks feed it, and a
periodic review keeps it current. It routes tasks that no rule covers, and it tells you when a
rule looks dated.

**Success criteria:**
1. A refresh produces scores for the models in your adapters' catalogs, each backed by a cited
   source.
2. A task whose kind no rule matches routes to the best-scoring available model, with the score
   in its reason.
3. A rule that picks a clearly weaker model shows a hint.
4. A bad refresh can be rolled back with one click.

## 2. Dimensions

The stable axes. L3-0 ships this list as data. L3-I owns changes to it.

| Dimension | Measures |
|---|---|
| `agentic-coding` | multi-step repo tasks end to end |
| `algorithmic-reasoning` | hard algorithm and competitive-programming problems |
| `test-authoring` | writing tests that are correct and catch bugs |
| `frontend-ui` | web and UI work |
| `large-context-refactor` | changes across many files and long context |
| `debugging` | finding and fixing a failure from evidence |
| `docs-prose` | technical writing |
| `tool-use-reliability` | correct tool calls and terminal use |
| `speed` | output tokens per second and time to first token |
| `cost-efficiency` | inverse of cost per task |

Adding a dimension is a data change plus a migration that gives existing kinds a weight of 0.

## 3. Sources

A curated, editable registry (Settings → Flight Control → Capability index → Sources). Each
entry has:
- `id`, `name`, and `url`;
- `dimensions`, a weight per dimension it feeds;
- `howToRead`, which tells the extractor which table or metric to use;
- `enabled`.

The initial set:
- SWE-bench Verified;
- SWE-bench Pro;
- Terminal-Bench;
- Aider Polyglot;
- LiveCodeBench;
- a web-dev arena leaderboard;
- an independent speed and price tracker;
- vendor model cards (for context windows and prices).

The first implementation task checks each URL live and records which ones are machine-readable.

## 4. The refresh run

- **When:** weekly (a `WatchClock` timer, while the app runs) and on demand from Settings.
- **How:** a headless agent run (default `claude -p` with WebSearch/WebFetch, model
  configurable) for each enabled source. It gets the source entry and the list of catalog models,
  and it must emit strict JSON:
  ```json
  {"source": "terminal-bench", "rows": [
    {"benchmarkModel": "GPT-6 Sol (high)", "score": 61.3, "unit": "percent",
     "url": "…", "retrievedAt": "…", "quotedFigure": "61.3%"}]}
  ```
- **Validation.** A row is rejected when:
  - it has no `url`;
  - its `quotedFigure` does not parse to its `score`;
  - its unit is unknown.

  Rejected rows are logged with the reason.
- **Budget:** a token cap per run (default set in Settings). When the cap is reached, the
  remaining sources keep their previous values and are marked stale.
- **Failure:** a source that fails keeps its previous values, marked stale with the error.

## 5. Model identity

Benchmarks name models in their own way. An **alias table** maps
`(source, benchmarkModel)` to a catalog `ModelRef`.
- The refresh proposes aliases for names it cannot map. You confirm them in Settings.
- **An unmapped model is ignored, never guessed.**
- The same benchmark model at different settings (for example "(high)" and "(low)") may map to
  the same model with different knobs. The table stores the knobs.

## 6. Scoring

- **Per benchmark:** the percentile rank of each model among the rows of that snapshot → 0–1.
- **Per dimension:** the weighted mean over the benchmarks present for that model. **Confidence**
  is the share of the dimension's total source weight that was present.
- **No data → unknown**, never zero.
- **Local models:** you can enter per-dimension scores for a model by hand, or set it to
  *inherit from* a base model with a discount (default 0.85×). Hand-entered scores have
  confidence 1 and are labeled "manual".
- **`rank(kind, candidates)`:** a kind's score for a model is the sum over dimensions of kind
  weight × model score, divided by the sum of the weights that had data. Its confidence is the
  weight-share that had data. Ties go to catalog order.
- **Rule hints:** for each confirmed rule, compare the assigned model with every candidate on the
  dimensions in the rule's `match`. If some model scores at least 0.10 higher with confidence at
  least 0.6, the rule gets a hint with the numbers and the sources.

## 7. Storage and rollback

- Snapshots go in `~/Library/Application Support/Flight Deck/capability-index/<ISO date>.json`.
  Each one holds raw rows, aliases used, scores and confidence. The newest valid snapshot is
  current.
- A new snapshot **applies automatically**. This is safe because the index only drives fallback
  routing and hints.
- Settings shows the diff against the previous snapshot (the models and dimensions that moved),
  with **Roll back**, which makes the previous snapshot current.
- Keep the last 12 snapshots.

## 8. UI

Settings → Flight Control → Capability index:
- a model × dimension heatmap with confidence shown as opacity, and a click-through to the cited
  rows;
- the sources list, the alias table (with pending proposals), and manual scores for local models;
- the last refresh time, **Refresh now**, the diff, and **Roll back**.

## 9. Testing

- **Validation and scoring** are pure. They are tested against recorded extraction outputs:
  valid, missing citation, figure mismatch, unknown unit, unmapped model, partial coverage,
  manual and inherited scores, ties.
- **Rule hints:** table tests.
- **The refresh driver** runs against a fake headless runner, covering cap reached, a source
  failing, and stale marking.
- **Live:** one probe, skipped by default (`INDEX_LIVE=1`), runs one real source and spends
  tokens.
- **UI:** XCUITest for the heatmap, diff and rollback against fixture snapshots, with screenshots.

## 10. Provides at integration

A real `CapabilityIndex` conformer, the refresh scheduler, and the Settings pane.

## 11. Files

- `Sources/IntakeKit/FlightControl/CapabilityScoring.swift`, `IndexSnapshot.swift`,
  `ExtractionValidator.swift`, `AliasTable.swift`, `CapabilityHints.swift`,
  `IndexSnapshotStore.swift`, `IndexSources.swift`, `IndexExtraction.swift`
- `Sources/FlightDeck/FlightControl/CapabilityIndexService.swift`, `IndexRefreshRunner.swift`
- `Sources/FlightDeck/Preferences/UI/CapabilityIndexPane.swift`, `CapabilityIndexSettingsTab.swift`
- `Tests/FlightDeckTests/FlightControlL3/Index/…`, `UITests/FlightDeckUITests/CapabilityIndexUITests.swift`

## 12. As built (plan `2026-10-04-flight-control-l3-i-capability-index.md`)

- **Snapshot names** are a UTC date-time stamp, `capability-index/2026-10-04T060000Z.json`, not a bare date: two snapshots a day must not overwrite each other, and a timezone change must not reorder them. A write never sorts before an existing snapshot, even after the clock moves back.
- **Rollback** renames the current file to `<stamp>.rolledback.json`; the newest valid snapshot stays the only definition of current.
- **Snapshots hold computed scores only.** Hand-entered and inherited scores are overlaid live from `capability-index/config.json`. Precedence per dimension: manual > computed > inherited; inheritance is one level.
- **Confirming, rejecting or editing an alias** rescoring writes a new snapshot from the current rows (no agent run), so it can be rolled back. A rescore whose scores and unmapped names are unchanged writes no snapshot, so a settings edit that changes nothing never pushes a real refresh out of the 12 kept.
- **One source = one metric in one unit.** The speed and price tracker is two sources; vendor model cards feed context windows only. SWT-bench was added for `test-authoring`. `docs-prose` has no source and stays unknown unless entered by hand. Machine-readable as probed on 2026-10-04: SWE-bench Verified (JSON) and Aider Polyglot (YAML); the rest are pages.
- **A benchmark with fewer than two rows contributes nothing.** Unmapped names still count in a benchmark's percentile population. Two names mapped to one model in one source keep the better row.
- **`rank`:** a candidate without knobs matches every scored knob variant of its model and returns the best one, knobs included.
- **The refresh agent is claude only** (`-p`, tools exactly WebSearch and WebFetch, `--restricted`, `--strict-mcp-config`, `dontAsk`); model, effort and the token cap (default 1,500,000) are settings. The cap counts every token the agent processes, including cached input that it re-reads each turn. A source that returns only rejected rows counts as failed. A finished refresh is rescored with the aliases and sources as they are when it writes, so an edit made during a run is not overwritten.
- **The first refresh is manual**; the weekly check (on the shared `WatchClock`) starts after the first attempt, and every attempt is recorded so a failing run waits a week.
- **Rule hints** are `hints(for:assigned:candidates:) -> [CapabilityHint]` on `SnapshotCapabilityIndex`, `LiveCapabilityIndex` and `CapabilityIndexService`; L3-R calls it at integration. Only the rule's dimension keys are compared.
- **Integration hands L3-R `SessionStore.capabilityIndexService?.live`** as its `CapabilityIndex`. Until L3-R fills `modelCatalog()`, refreshes see empty catalogs and propose no aliases.
- **Settings:** a temporary top-level `PreferencesTab.capabilityIndex` / `CapabilityIndexSettingsTab`, labelled "Capability Index" (identifier `prefs-capability-index`). L3-R uses that same label and identifier for its tab, so both coexist until integration moves `CapabilityIndexPane` into L3-R's `FlightControlSettingsTab` and deletes the temporary tab.
- **UI test:** `CapabilityIndexUITests` skips unless `INDEX_UI=1` (as `TEST_RUNNER_INDEX_UI=1`), so `smoke.sh`, which runs the whole UI bundle, does not run it. Run it with `TEST_RUNNER_INDEX_UI=1 xcodebuild … test -only-testing:FlightDeckUITests/CapabilityIndexUITests`. Its reads use `value` for static text.
- **Live probe, 2026-10-05:** claude 2.1.289 (Claude Code); aider-polyglot via WebFetch under `--restricted` — 69 rows accepted, all cited and figure-matched; 18,347 tokens; 66 s.
