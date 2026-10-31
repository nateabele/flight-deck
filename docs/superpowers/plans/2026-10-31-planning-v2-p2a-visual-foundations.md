# Planning v2 P2a (foundations): Visual Blocks Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development. This plan runs **alongside P1**. V0 lands alone, after P1's Task 0, because both touch `Frames.swift` and `IntakeWire.swift`. Streams V1–V3 then run in parallel worktrees, and V4 integrates them after P1's Task 6.

**Goal:** A plan can carry `fd-visual` blocks. They render inline as full-width live Mermaid diagrams with snapshots, the phone shows them, and release exports them into the repo with fidelity references on the tasks.

**What this plan leaves out:** making visuals from threads or rounds, which is P2a-integration and needs P1's runtime; comps, which are P2b; pluggable providers, which are P3. Here, test fixtures create visuals.

**Spec:** §7, §8 (VisualBlockView, Mermaid, VisualRenderHost), §10 (`visual.fetch`), §12.

## Rulings on where the spec and the code disagree

These come from the P2a code map.

| # | Spec assumed | Code has | Ruling | Cost if wrong |
|---|---|---|---|---|
| V-R1 | `VisualBlockView` is an NSTextAttachment | The editor has no attachment API | It follows the **table pattern**. The styler hides the block's source text, sets a fixed paragraph height equal to the view height, and lays a subview over it, positioned the same way as `PlanTableController.bandOrigin` and `PlanTableOverlay.refresh`. | A second overlay system to maintain |
| V-R2 | The web view uses `loadFileURL(_:allowingReadAccessTo:)` | The canvas branch serves files through a `WKURLSchemeHandler` from a hash manifest | Use **the scheme handler** (`fdvisual://<visualID>/r<n>/…`). It serves only files listed in the revision manifest, uses a `.nonPersistent()` store, and cancels navigation to any other scheme, which turns networking off. It reuses the canvas's approach and is easier to confine than file URLs. | The spec text changes |
| V-R3 | Fidelity references are written by the agent | Task bodies are written by the agent | References are added **by code**. `NewBead` gains an optional `visualRefs: [VisualRef]`. `BeadWriter` appends the "Fidelity references" section to the description. `ChangeSetValidator` gains `unknownVisual`. | None. This is more deterministic. |
| V-R4 | Release commits the export by path | Nothing commits to the user's repo yet | New `RepoCommitter`, built on `CommandRunner`: `git status --porcelain -- <dir>` (any dirty path refuses), `git add -- <paths>`, then `git commit -m … -- <paths>`. `PlanExporter` runs at `IntakeService.swift:2077`, before `ApplyPlanner`. | One more code path that touches git |
| V-R5 | Mermaid is vendored | There are no web assets on master | `Resources/Visuals/mermaid/mermaid.min.js`, pinned to one exact version, with a SHA-256 in `manifest.json` that is checked at load. Added as a folder reference in `project.yml`. | Its size grows the bundle by about 3 MB |
| V-R6 | `visual.fetch` is intake-scoped | `.fileRead` is scoped to a tab session | A new op, `intake.visualFetch(id:visualID:revision:part:offset:limit:)`, returns `WireFileChunk`, gated by the `visuals` flag. | None |

## Global Constraints
These are the same as P1's: words, additive storage, atomic wire cases, gated ops, TDD with filtered RED and GREEN, one full suite in V4, worktree per stream, hotspots only in V0 and V4. In addition:
- The **only writer** of `visuals/` is ThreadRunner (spec §3). Until P2a-integration, nothing writes it outside tests.
- **Every render gets looked at** (renders via `FD_INTAKE_RENDER_DIR` or `FD_PLANNING_RENDER_DIR`).

## Review Focus
1. **A `fd-visual` block whose id has no revision folder.** It renders a quiet "missing visual" placeholder of fixed height, never a crash or a collapsed editor. (V1)
2. **Editing text right next to a visual block** (typing above or below, or deleting the fence). The overlay follows the block or disappears. It never paints over text. (V1)
3. **A Mermaid source that fails to parse.** The block shows the error text from Mermaid, and the snapshot shows the same. (V1)
4. **Release when `docs/plans/<slug>/` has uncommitted changes.** Release is refused with the path named. Nothing is written. (V2)
5. **A revision folder holding a file not in its manifest, or a symlink out of the folder.** It is never served. (V1, V-R2)

---

### V0: Interfaces (lands alone, after P1 Task 0)

**Create:**
- `Sources/IntakeKit/Visuals/VisualModel.swift`: `VisualID`, `VisualRevision{id, r: Int, manifest: VisualManifest}`, `VisualManifest{provider, providerVersion, kind, title, entry, states, sizes, pins: PinScheme, madeOnCheckpoint, madeBy, parent, alternates, primary}`, `BlockState{representations: [RevisionRef], primary: RevisionRef}`, and `VisualRef{visualID, states}`.
- `Sources/IntakeKit/Visuals/VisualStoreReading.swift`: the read protocol, plus `TapeStore.visualsDirectory(_:)` and `revisionDirectory(_:r:)`.
- `Sources/FleetKit/VisualWire.swift`: `WireVisualRef{id, revision, kinds, alternates, states}` and `WireIntakePlan.visuals: [WireVisualRef]?`.

**Modify:**
- `MarkdownStyler`: `lineKind` returns the fence **info string**, and `MarkdownBlock.Kind` gains `.visual(id: String, pending: Bool)`. Fences now match only a closing fence with the same character and at least the same length.
- `ChangeSet`: `NewBead.visualRefs: [VisualRef]?`.
- `ChangeSetValidator`: the `unknownVisual` case.
- `Frames.swift`: `intakeVisualFetch`, with every arm present and a stub that refuses `visuals_unavailable`.

**Tests:**
- `VisualModelCodingTests`.
- `MarkdownStylerFenceTests`: `fd-visual id=x`, then `pending`, then unmatched-length fences, then old plans parsing the same.
- `ChangeSetVisualRefTests`: an old change set decodes.
- `VisualWireCodingTests`.

**Commit:** `feat: plans can name inline visuals, and the wire can carry them, with nothing drawn yet`.

### V1: Mac rendering (VisualBlockView, Mermaid, snapshots)

**Create:**
- `Sources/FlightDeck/Intake/Planning/Visuals/VisualBlockView.swift`: header, body, filmstrip, Compare, and the states and sizes controls.
- `VisualBlockOverlay.swift`: positioning, per V-R1.
- `VisualSchemeHandler.swift`: per V-R2.
- `VisualRenderHost.swift`: offscreen `WKWebView.takeSnapshot`, writing `snapshot@<state>-<size>.png`.
- `MermaidPage.swift`: the HTML shell that loads the vendored `mermaid.min.js`.

**Add:** `Resources/Visuals/`, per V-R5. Link `WebKit` in `project.yml`.

**Rules:**
- An off-screen block shows its snapshot. It goes live when scrolled into view, and **at most 3 live web views** exist at once. The least recently used becomes a snapshot again.

**Tests:**
- `VisualSchemeHandlerTests`: covers Review Focus 5, rejecting a symlink out of the folder, a file not in the manifest, and an `http` navigation.
- `VisualBlockOverlayTests`: covers Review Focus 1 and 2.
- `MermaidRenderTests`: WebKit runs on the UI-test Mac and the PNG is checked by eye. It covers a sequence diagram, a flowchart, and the parse-error case from Review Focus 3.
- `VisualRenderHostTests`: the snapshot set follows the spec §8 rule.

### V2: Export and fidelity references

**Create:**
- `Sources/IntakeKit/Visuals/PlanExporter.swift`: pure. It decides which files go where:
  - `plan.md`, with the image and link substitution;
  - `visuals/<id>/`, with `README.md`;
  - `_unused-alternates/<n>/README.md`;
  - the slug, with `-2` added on collision.
- `Sources/IntakeKit/RepoCommitter.swift`: V-R4.

**Modify:**
- `BeadWriter`: appends the Fidelity references section, per V-R3.
- `ReleaseSheetModel`/`ReleaseReviewView`: lists the files and the commit.

**Tests:**
- `PlanExporterTests`: paths, slug collision, alternates README text, plan rewriting.
- `RepoCommitterTests`: in a temp git repo, a commit by path leaves other dirty files untouched, and a dirty target directory is refused (Review Focus 4).
- `BeadWriterFidelityTests`.

### V3: Phone

**Create:**
- `Sources/FlightDeck/Intake/IntakeService+Visuals.swift`: `phoneVisualFetch`.
- `Sources/FlightDeckMobile/VisualBlockCard.swift`: snapshot plus filmstrip.
- `VisualViewerScreen.swift`: a live `WKWebView` built from cached bundle bytes, with networking off.
- `VisualCache.swift`: keyed by `(visualID, revision)`, kept indefinitely.

**Modify:**
- `TimelineSegments`: a `.visual(id:caption:)` segment.
- `PlanSegmentView`.

**Tests:**
- `VisualCacheTests`.
- `PhoneVisualFetchTests`: chunking, the 10 MB cap, and the gate.
- A phone render through `RENDER_INTAKE`, checked by eye.

### V4: Integration (after P1 Task 6)

**Modify:**
- `IntakeService.runRelease`: calls `PlanExporter` and `RepoCommitter` at :2077.
- `IntakePlanProjection`: fills `visuals`.
- `IntakeDetailProjection`: sets `visuals: true`.
- Remove the V0 stubs.
- `RoundPrompts.encode`: gets the visuals catalogue.

**Docs:** HANDOFF (§2.10 release, §3.7 editor, §4), ARCHITECTURE, spec errata V-R1–V-R6, and a CHECKLIST section for P2a, marked unverified.

**Tests:** the full Mac and iOS suites, plus one XCUITest that opens a plan with a diagram and switches size.
