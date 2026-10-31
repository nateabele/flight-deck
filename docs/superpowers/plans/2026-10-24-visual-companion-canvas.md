# Flight Deck Canvas Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build Flight Deck's opt-in canvas skill: streamed high-fidelity HTML/CSS previews, element comments, session feedback and hierarchical subtree history, eventually replacing Visual Companion in Flight Control v2.

**Architecture:** A TypeScript engine inside the app's WKWebView owns the document model, operation validation, event reduction, checkpoints, branches, restore planning and annotations. Swift is a thin native host: lifecycle, permissions, CLI routing, atomic SQLite/blob storage, resource access and durable agent delivery. TS computes a candidate, Swift commits it with compare-and-append semantics, and TS renders only the acknowledged result. There is one semantic engine, not matching Swift and TS implementations.

**Tech Stack:** TypeScript/HTML/CSS, browser DOM, Swift/Foundation/SQLite/WebKit, Node for build/unit tests only, headless browser tests and actual WKWebView tests on the dedicated Mac. Puppertino is the proposed kit baseline; compare MacVue before pinning. No runtime Node process, Swift CanvasKit package, new localhost web server or runtime dependency installation.

**Spec:** [2026-10-24-visual-companion-canvas-design.md](../specs/2026-10-24-visual-companion-canvas-design.md)

**Research:** [2026-10-25-canvas-ui-kit-research.md](../specs/2026-10-25-canvas-ui-kit-research.md)

**Status:** Redrafted 2026-10-26 after the user chose a TS/browser engine and thin Swift host. Supersedes the Swift-core plan previously opened in Plannotator. Any previous review decision applies only to that older text; the redraft is not implicitly approved. This turn changes planning documents only.

## Global constraints

- Built directly into Flight Deck as a default-off opt-in skill; no automatic Flight Control provider replacement.
- Restore the entire authored subtree, preserve compatible current interaction state, and retain newer history as branches.
- Ship a built-in SwiftUI/AppKit-style HTML/CSS kit in the first release. Native execution remains a different renderer capability.
- TS owns all semantic document/history/annotation rules. Swift owns native authority and durable bytes; no native tree reducer, checkpoint planner or branch-merging implementation.
- Commit before acceptance/render. A storage failure never publishes candidate state; replay never reissues external actions.
- A single host-registered engine instance writes each canvas. Engine loss pauses mutation processing until recovery; no acknowledgment of uncommitted commands.
- Built web assets ship in Debug/Release. Node is development tooling, never a required child process of Flight Deck.
- Preview-authored code has no native handler, local-control token, arbitrary filesystem access or direct agent-send capability.
- Preserve managed-skill user edits/deletions, existing agent instructions and unrelated concurrent changes. Do not modify installed Superpowers caches.
- Keep current `project.yml` macOS deployment target/Swift language mode. Check impact/context via Qartez before changing shared app/control files.
- Private control values and opaque browser state are not persisted by default. Recovery guarantees committed authored state and explicitly captured supported UI state, not every keystroke.
- Use headless tools or the dedicated test Mac for GUI checks. Never launch a DerivedData app or seize this Mac's foreground.
- Each regression is written and observed failing before implementation, then passes targeted verification. Stage/commit task-owned changes only.

## Ownership and file map

| Responsibility | Implementation |
|---|---|
| Model/schema validation, canonical hashes, operation reducer | TS `Resources/Canvas/src/engine/` |
| Events, revisions, checkpoints, scoped history, restore conflicts | TS engine |
| Semantic component catalog, kit, project adapters, rendering | TS/CSS `Resources/Canvas/src/` |
| Input/focus/selection/scroll state, annotation UI and thread semantics | TS engine + browser adapters |
| Atomic append/dedup/sequence, blob bytes, opaque snapshots | Swift storage adapter |
| Engine registration/lease, readiness, WKWebView lifecycle | Swift coordinator |
| CLI/control authorization, skill opt-in and session delivery | Swift app integration |

```text
Resources/Canvas/package.json, lockfile, tsconfig.json
Resources/Canvas/src/engine/         protocol, model, reducer, hashes, events, checkpoints,
                                    branches, restore, annotations, recovery, commit pipeline
Resources/Canvas/src/host/           typed native bridge and storage adapter
Resources/Canvas/src/renderer/       shell, keyed DOM updates, state serializers
Resources/Canvas/src/kit/            semantic catalog, controls, layout, CSS/token profiles
Resources/Canvas/src/project/        discovery-manifest interpretation and project renderer
Resources/Canvas/test/               pure engine tests, fake storage/host, shared wire fixtures
Resources/Canvas/test/browser/       rendering, interaction, history and annotation tests
Resources/Canvas/third-party/        pinned licensed kit sources/notices
Resources/Canvas/built/              generated bundled assets; build policy decided in Task 0
Sources/FlightDeck/Canvas/           CanvasStorage, CanvasBlobStore, CanvasEngineCoordinator,
                                    CanvasBridge, CanvasWindow, CanvasWebView,
                                    CanvasControl, CanvasDelivery, CanvasSkill
Resources/CanvasSkill/               canonical SKILL.md and bounded references
Sources/FlightDeckCLI/CanvasCommands.swift
Sources/FleetKit/CanvasWire.swift    capability-gated transport envelopes if required
Tests/FlightDeckTests/Canvas/        storage, lifecycle, bridge, CLI/skill and WebKit tests
scripts/build-canvas.sh
scripts/test-canvas-engine.sh
scripts/test-canvas-browser.sh
scripts/test-canvas-webkit.sh
```

Existing seams inspected during planning: `ClaudePluginLocation`'s writable materialized plugin; `CodexDelegateSkill` and `PeerMessagingSkill`'s user-edit-preserving installation; launch setup in `DelegationBootstrap`; scope policy in `ControlScope`; long-lived CLI runners in `CLIRunner`. Reuse those contracts. Candidate integration files are `FlightDeckApp.swift`, `SessionStore.swift`, `FleetService.swift`, `CLIArguments.swift`, `CLIRunner.swift`, `Sources/FlightDeckTool/main.swift`, `project.yml`, preference UI and `IntakeService`; resolve exact anchors against the current checkout during implementation.

## Dependency order and milestones

Execute **0 → 1 → 2 → 3 → 8 → 4 → 5 → 6 → 7 → 9 → 10 → 11**. Task 8 first exposes only implemented capabilities; extend its recipes as later tasks land. Task 4 tests patches first and adds restore integration after Task 5. Native storage and pure TS work can run independently once Task 0 fixes the bridge fixtures; shared host/control edits remain coordinated.

| Milestone | Tasks | Exit gate |
|---|---|---|
| M0: compatibility | 0 | Pinned kit/build choices; measured WebKit comparison; safe preview arrangement; proven bridge/stream and offscreen-engine lifecycle. |
| M1: opt-in canvas | 1–3, 8 initial | Enable, stream three stages, preserve typed input, close/reopen window, kill/recover web process and retry an ambiguous commit without duplication. Disabled install exposes no skill. |
| M2: kit and history | 4–6 | Native reference comparison meets recorded tolerances; scoped back/forward preserves sibling changes and compatible input; newer branch remains accessible. |
| M3: feedback/project fidelity | 7, 9, 8 recipes | Revision-anchored comments survive restore; explicit send works through durable delivery; project overrides and efficient delta generation pass fixtures. |
| M4: v2 candidate | 10–11 | Intake artifacts reopen, old provider remains available, and fidelity/correctness/recovery gates pass before rollout. |

## Shared contracts

These are TS-owned semantic types. Swift decodes only the native transport/storage envelope and authorized effect descriptors. Do not mirror `DocumentState`, `Operation`, checkpoint internals or reducer logic in Swift.

```ts
type NodeId = string;
type RevisionId = string;
type BranchId = string;
type CheckpointId = string;
type Json = null | boolean | number | string | Json[] | { [key: string]: Json };
type PreviewNode = {
  id: NodeId; type: string; props: Record<string, Json>; children: NodeId[];
};
type DocumentState = {
  documentId: string; revision: RevisionId; branchId: BranchId;
  rootId: NodeId; nodes: Record<NodeId, PreviewNode>;
};
type DocumentRevision = {
  id: RevisionId; parentRevision: RevisionId | null; branchId: BranchId;
  sourceCheckpointId: CheckpointId | null; treeHash: string;
};
type ScopedHistoryEntry = {
  id: string; scopeId: NodeId; previousEntryId: string | null;
  sourceCheckpointId: CheckpointId; resultingRevision: RevisionId;
};
type Operation =
  | { op: 'insert'; parentId: NodeId; beforeId: NodeId | null; node: PreviewNode }
  | { op: 'move'; nodeId: NodeId; parentId: NodeId; beforeId: NodeId | null }
  | { op: 'remove'; nodeId: NodeId }
  | { op: 'setProps'; nodeId: NodeId; set: Record<string, Json>; unset: string[] }
  | { op: 'text'; nodeId: NodeId; text: string };
type Command = {
  eventId: string; actorId: string; scopeId: NodeId; branchId: BranchId;
  baseRevision: RevisionId; transactionId: string; operations: Operation[];
};
type Checkpoint = {
  id: CheckpointId; label: string; scopeId: NodeId;
  parentCheckpointId: CheckpointId | null; branchId: BranchId;
  revision: RevisionId; seq: number; treeHash: string;
  dependencyHash: string; interactionSnapshotHash: string | null;
};
type StatePolicy = 'preserve-compatible' | 'restore-captured';
type RestoreRequest = {
  eventId: string; actorId: string; checkpointId: CheckpointId;
  scopeId: NodeId; expectedRevision: RevisionId; expectedScopeHash: string;
  statePolicy: StatePolicy;
  insertion: { parentId: NodeId; beforeId: NodeId | null } | null;
};
type Conflict = {
  code: 'stale' | 'identity' | 'ownership' | 'dependency' | 'missing-parent';
  nodeIds: NodeId[]; explanation: string;
};
type RestorePlan = {
  request: RestoreRequest; operations: Operation[];
  conflicts: Conflict[]; beforeHash: string; afterHash: string;
  affectedIds: NodeId[]; dependencyHash: string;
};
```

Task 1 defines versioned runtime schemas for the semantic types above, resource/action registration, feedback payloads and `EventEnvelope` in the spec. `seq` advances on all durable events; authored `revision` advances only for document mutations. Feedback carries immutable `subjectRevision` and does not invalidate unrelated authored edits. Engine version and resource versions travel with recovery/export records.

### Native persistence boundary

```ts
type EngineLease = { instanceId: string; generation: string };
type StoredEvent = { seq: number; body: Json };
type PendingEvent = { body: Json };
type SnapshotRef = { hash: string; engineVersion: string; schemaVersion: number };
type DeliveryDescriptor = {
  messageId: string; destinationSessionId: string;
  action: 'send-comments' | 'revise-selection'; contextHash: string;
};
type AppendRequest = {
  canvasId: string; lease: EngineLease; requestId: string;
  command: Json; requestHash: string; expectedSeq: number;
  events: PendingEvent[]; snapshot: SnapshotRef | null;
  blobRefs: string[]; deliveries: DeliveryDescriptor[];
};
type CommitAck = { firstSeq: number; lastSeq: number; duplicate: boolean };
type RecoveryBundle = {
  lastSeq: number; snapshot: { throughSeq: number; ref: SnapshotRef } | null;
  events: StoredEvent[];
};
interface CanvasHost {
  load(canvasId: string, lease: EngineLease): Promise<RecoveryBundle>;
  append(request: AppendRequest): Promise<CommitAck>;
  putBlob(canvasId: string, bytes: Uint8Array): Promise<string>;
  getBlob(canvasId: string, hash: string): Promise<Uint8Array>;
  deliveryStatus(canvasId: string, messageId: string): Promise<
    'queued' | 'delivered' | 'acknowledged' | 'failed'>;
}
```

The bridge binds every method to the registered canvas, lease and native permissions; producer-supplied IDs do not grant access. `requestHash` hashes the original canonical semantic `command`; it excludes attempt-specific lease/expected sequence and derived events/snapshot. Swift recomputes that hash without interpreting operations, rejects a reused request ID with a different command, deduplicates before expected-sequence checks, verifies blob existence, and performs one transaction. Lease/permission checks still precede duplicate acknowledgment. `snapshot` captures the state through that batch's final sequence; TS hash-validates and schema-validates it when replaying. `StoredEvent.seq` supplies the outer sequence; pending bodies omit storage-assigned fields and are combined with that sequence when decoding a committed `EventEnvelope`. Persisted native outbox descriptors are drained by Swift, never executed by reducers. Receipt status lives outside the semantic journal and is folded into TS feedback only through a later append.

Per canvas, `CanvasEngine.submit(command): Promise<CommitAck>` serializes command handling, computes a candidate with `reduce`, prepares events and blobs, calls `host.append`, then publishes committed state. For `duplicate: true`, discard the new candidate and catch up from stored events rather than publish freshly derived duplicate state. Recovery builds the committed request-ID index before accepting commands, so a known retry does not fail stale-base validation first. `CanvasEngine.recover(bundle)` reconstructs state and exposes ready only after validation. `ready` is a native coordinator state, not a caller assertion. Revoked leases cannot append or finish an old command.

## Task 0: Bridge/lifecycle and UI-kit spike

**Files:** Create `docs/superpowers/specs/2026-10-26-canvas-spike-results.md` during execution; isolated Swift/HTML galleries; `Resources/Canvas/package.json`, lockfile, TS config and `scripts/build-canvas.sh` after build choice.

**Consumes:** Spec/research. **Produces:** pinned tooling/kit/reconciler, native envelope fixtures, engine-readiness arrangement, safe preview arrangement, streaming control design.

- [ ] Benchmark legacy screen creation and one-control revision; mark selective restore unsupported rather than invent a comparison. Separate tool/model time and emitted tokens from rendering.
- [ ] Compare Puppertino and MacVue against native control fixtures in actual WKWebView on the dedicated Mac. Include control size/state/appearance, accent, inactive window, reduced transparency, and fallback effects. Record tolerances and package/license/asset revisions.
- [ ] Prove a bundled TS engine can boot in an offscreen WKWebView, receive a fixture command, call a fake persistence handler, and signal readiness without opening a window. Measure closed-window/hidden-view behavior and restart after web-process termination. Record that runtime mutations require an available engine.
- [ ] Test preview-authored scripts cannot access shell handlers/tokens, native storage or non-allowlisted resources after navigation. Choose an isolated frame or a separate unprivileged preview view based on the result; preserve one trusted engine writer in either arrangement.
- [ ] Prove bounded request/ack streaming through a fixture local-control transport and a native storage transaction. Select incremental existing protocol extension or same-policy local stream. Check build availability against current macOS/SDK; no runtime Node dependency.
- [ ] Record exact dependencies and reproducible web build/test commands, bridge fixtures and why the design wins. Commit only the spike/build artifacts. Failures of isolation or lifecycle are architecture findings to resolve before production work.

## Task 1: Pure TS engine and protocol

**Files:** Create `Resources/Canvas/src/engine/{protocol,model,reduce,hash,events}.ts`, `test/engine.test.ts`, `test/fixtures/page.ts`, JSON envelope fixtures and runtime schema tests.

**Consumes:** Shared contracts. **Produces:** `createDocument(id): DocumentState`, `reduce(state, command): DocumentState`, `hashScope(state, nodeId): string`, typed/schema-validated events and resources.

- [ ] Write a failing reducer test with `pageFixture()` containing page/sidebar/main/search. `setPropsCommand` constructs a command using the fixture's current revision and branch.

```ts
test('sidebar edit preserves main', () => {
  const old = pageFixture();
  const next = reduce(old, setPropsCommand(old, 'sidebar', { width: 240 }));
  assert.deepEqual(next.nodes.main, old.nodes.main);
  assert.equal(next.nodes.sidebar.props.width, 240);
});
```

- [ ] Run the test to observe failure, then implement immutable reduction, canonical serialization/hashes, scope validation, tombstones and explicit errors. No DOM, host calls or side effects inside the reducer.
- [ ] Cover duplicate IDs, cycles, missing anchors, root removal, stale bases, out-of-scope mutation and invalid batch atomicity. Define text nodes and action/resource references with exact runtime schemas.
- [ ] Separate journal sequence, design revision, checkpoint grouping, document ancestry and scoped history references. Test deterministic replay and shared native envelope fixtures; Swift tests will decode envelopes only. Run `npm --prefix Resources/Canvas run test:engine` and `typecheck`; commit.

## Task 2: Swift persistence adapter and TS commit pipeline

**Files:** Create Swift `CanvasStorage.swift`, `CanvasBlobStore.swift`, `CanvasStorageEnvelope.swift`; TS `src/host/{bridge,storage}.ts`, `src/engine/{commit,recovery}.ts`; storage/commit tests under both native and TS test directories.

**Consumes:** Task 1 and native persistence contract. **Produces:** SQLite-backed `CanvasHost` implementation, pure TS commit pipeline, fake host test implementation and durable replay.

- [ ] Write failing tests for storage rejection leaving public state unchanged and duplicate commits returning original acknowledgment. Native tests use temporary stores; TS tests use `MemoryCanvasHost` with failure/ack-loss injection.

```ts
test('failed persistence cannot publish candidate state', async () => {
  const host = new MemoryCanvasHost();
  host.seed(pageFixture());
  const engine = await CanvasEngine.open(host, 'canvas-a');
  const before = engine.state;
  host.failNextAppend('disk-full');
  await assert.rejects(engine.submit(setPropsCommand(before, 'sidebar', { width: 240 })));
  assert.deepEqual(engine.state, before);
});
```

Define `MemoryCanvasHost`, its explicit `seed`/`failNextAppend` methods and canvas-a registration in `test/fixtures/host.ts`. The test never depends on real app state.

- [ ] Implement native bounds/identity/lease checks, canonical request fingerprint, dedup-before-CAS and transactional sequence/event/snapshot/outbox records. Store semantic payload as versioned opaque bytes; no Swift element/branch inspection. Blob writes complete durably before references commit.
- [ ] Implement TS candidate validation → append → committed publication; serialize in-flight semantic commands. Feedback append advances seq without changing design revision. A committed retry returns original ack even when current revision/seq have advanced.
- [ ] Test command A→R1/seq1, comment→R1/seq2, command B→R2/seq3, retry A→original seq1, new stale command→refusal. Test commit-before-ack-loss, missing blob, duplicate differing payload, wrong canvas/lease, and snapshot+tail/full-replay hash equality.
- [ ] Keep native delivery receipts separate from journal CAS; outbox descriptors append atomically with events and drain only through native policy. Provide stored-data export without running TS. Run engine/type checks and filtered remote native storage tests; commit.

## Task 3: Native coordinator, CLI routing and persistent canvas

**Files:** Create `CanvasEngineCoordinator.swift`, `CanvasBridge.swift`, `CanvasWindow.swift`, `CanvasWebView.swift`, `CanvasResourceHandler.swift`, `CanvasControl.swift`, `CanvasCommands.swift`; TS `src/{shell.ts,renderer/dom.ts,renderer/state.ts}`; coordinator/CLI/browser/WebKit tests; resource wiring in `project.yml`.

**Consumes:** Commit pipeline/host bridge. **Produces:** stopped/loading/replaying/ready/failed/disabled lifecycle, `flightdeck canvas` creation/read/stream routing, persistent keyed renderer.

- [ ] Add failing lifecycle tests: one registered writer per canvas; window close does not discard active engine; a CLI command can trigger offscreen boot without stealing focus; recovering commands return `engine_not_ready` with retry guidance.
- [ ] Register host-issued instance/generation leases and revoke after process loss/replacement. Route authenticated CLI commands to TS; Swift checks native policy/ownership but leaves semantic validation to TS. Bound input buffers and in-flight requests; no unbounded hidden queue.
- [ ] Implement load→replay→ready handshake and lease-matched command/commit/render replies. A second window attaches to the existing canvas instead of creating another writer. Lazy recovery does not start an agent turn. Disabled blocks writes even if a cached skill still exists.
- [ ] Add browser regression for compatible input preservation across keyed updates; keep shell/frame mounted. Track dirty values, control/binding/serializer identity, composition and reset reporting.

```ts
const { canvas, producer } = await openFixture(page, 'page');
await canvas.locator('[data-node-id="search"]').fill('unsent');
await canvas.locator('[data-node-id="search"]').focus();
await producer.setProps('sidebar', { width: 240 });
await expect(canvas.locator('[data-node-id="search"]')).toHaveValue('unsent');
await expect(canvas.locator('[data-node-id="search"]')).toBeFocused();
```

- [ ] Test scroll/caret/selection/expansion/IME, default-value versus explicit reset, type/binding change, invalid rendering, literal `$&`, hidden/reattached view and process termination. Recovery promises committed state, not uncaptured keystrokes.
- [ ] Bundle generated assets reproducibly in Debug/Release; add shell/preview resource allowlist and validated frame messaging. Run engine/browser tests, filtered native tests and delegated actual-WebKit tests. Commit a working M1 foundation.

## Task 4: Built-in Apple-style UI kit

**Files:** Create TS `src/kit/{catalog,controls,layout,bindings,state}.ts`, `tokens.css`, `native-overrides.css`, pinned `third-party/` sources/licenses, reference/gallery browser tests and native `NativeReferenceGallery.swift`.

**Consumes:** Task 0 kit decision and renderer. **Produces:** versioned semantic catalog, SwiftUI names/AppKit aliases, appearance/profile/resource manifests.

- [ ] Write failing fixture coverage for Button/NSButton, fields/search/secure field, checkbox/radio/toggle, slider/stepper, segmented/pop-up control, progress, list/table, toolbar/sidebar/window, sheet/popover and layout stacks. Unknown styles produce diagnostics.
- [ ] Wrap selected pinned CSS/helpers behind semantic props; preserve license notices and separately verify asset permissions. Helpers attach once per stable node. Do not expose upstream class names as the generation API or introduce Vue solely for a metric reference.
- [ ] Implement light/dark, accent, OS profile, control sizes, enabled/focus/pressed/selected/inactive states and keyboard/reduced-motion/transparency behavior. Project recipes/tokens override defaults explicitly.
- [ ] Compare against native fixture tolerances on matched OS/scale settings. Record unsupported effects and calibrate CSS. Test dirty value/binding preservation during patches; add restore integration after Task 5. Include immutable kit and engine resource versions in checkpoints, not just token values.
- [ ] Run headless and actual WKWebView/native comparison gates, retain measurement results and notices, and commit M2 kit resources.

## Task 5: TS checkpoints, dependency comparison and subtree restore

**Files:** Create TS `src/engine/{checkpoints,dependencies,restore}.ts`, `test/{checkpoints,restore}.test.ts`; checkpoint persistence uses the existing host's opaque records/blobs, not new native semantic code.

**Consumes:** Model/hash/commit APIs and kit resource manifests. **Produces:** `createCheckpoint(state, scopeId, options): Checkpoint`, `planRestore(state, checkpoint, request, dependencies): RestorePlan`, restore command preparation through `CanvasEngine.submit`.

- [ ] Add failing regression: checkpoint C1 sidebar; C2 edits sidebar and main; restore sidebar to C1; all sidebar descendants restore, main remains at C2, compatible current input persists, and C2 remains reachable.
- [ ] Implement structurally shared immutable subtree/dependency snapshots; parent checkpoint grouping never mutates existing ancestor manifests. TS plans explicit before/after operations and compares hashes; Swift only commits opaque results.
- [ ] Test moved-out descendant ownership, deleted root with/without explicit insertion, missing ancestor, ID collision, foreign document, missing resource, changed shared token/provider/action and concurrent edit between preview/apply. No partial publication or storage on conflict.
- [ ] Default to current compatible state; historical state only uses explicitly captured serializers. Restore follows candidate→commit→publish and cannot execute external effects. Run engine/browser restore tests and native blob round-trip tests; commit.

## Task 6: TS branches and per-element history UI

**Files:** Create TS `src/engine/branches.ts`, `src/history/{panel,preview}.ts`, history tests and native CLI routing for checkpoint/list/compare/fork/back/forward.

**Consumes:** Task 5; CLI forwards semantic commands. **Produces:** scoped lineage navigation, retained branch tips, selective subtree adoption and restore previews.

- [ ] Write failing C1→C2→back→forward→edit-from-old scenario; sibling changes survive and C2 stays selectable. Ambiguous forward requires explicit lineage. Restore itself is undoable.
- [ ] Keep checkpoint containment, revision ancestry and scoped previous/source pointers distinct. Implement branching and comparisons only in TS; persist through opaque commit records.
- [ ] Render scope highlights, labels, before/after comparison, conflict reasons and mixed-provenance indicators. Scrubbing is read-only until Apply. Check stale apply again at commit preparation.
- [ ] Test restart, interrupted restore, duplicate apply, branch switch and immutable ancestor manifests. Add Task 4 kit restore tests now, run engine/browser/native-envelope tests and commit M2 history.

## Task 7: TS annotations/feedback with native delivery

**Files:** Create TS `src/engine/{annotations,feedback}.ts`, `src/annotations/{overlay,panel}.ts`; native `CanvasDelivery.swift`, bounded effect descriptor/status records; engine/browser/native-delivery tests.

**Consumes:** Stable IDs/revisions, element mapping and append outbox descriptors. **Produces:** create/reply/resolve/reopen comments, orphan listing, explicit send/revise actions and native delivery receipts.

- [ ] Write failing tests for comment-mode click not invoking control, stable thread across patch/restore, deleted anchor becoming orphan, new lookalike ID not inheriting thread, and iframe/scroll/zoom/scale geometry.
- [ ] Keep thread semantics, original `subjectRevision`, fallbacks, resolution state and annotation overlays in TS. Store crop bytes through blob API; do not capture the desktop. Feedback advances journal seq, not design revision.
- [ ] Prepare a native delivery descriptor only on explicit Send comments/Revise selection. Commit descriptor and its event together before Swift drains the outbox. Swift resolves/authorizes the destination, bounds payload and uses supported agent channels; it does not interpret document history.
- [ ] Test wrong/closed/busy session, acknowledgment loss, offline retry, engine crash after commit, app restart and replay sending no duplicate action. Without receiver deduplication, surface uncertain delivery instead of blind retry. Inbox fallback remains available; no arbitrary keystroke injection. Run targeted TS/native/browser tests; commit.

## Task 8: Opt-in skill lifecycle

**Files:** Create native `CanvasSkill.swift`, canonical `Resources/CanvasSkill/SKILL.md` and bounded references; preference/launch/materialized-plugin integration and native skill tests.

**Consumes:** Task 3 basic commands initially. **Produces:** default-off enable/disable, additive managed skill delivery and capability-gated recipes.

- [ ] Add failing tests for disabled fresh install, enable/disable, account home, user edits/deletion, restored tabs, app update and Debug/test isolation. Existing delegate/peer skill bytes remain unaffected.
- [ ] Deliver the initial skill after Task 3 with create/open/read/stream only. Extend the same managed source when catalog/history/comments/project APIs land. Agent discovery can remain normal after opt-in; unavailable capabilities never appear as runnable examples.
- [ ] Follow writable Claude materialization and account-scoped additive Codex installation contracts; never replace developer instructions or user-owned files. Service gating is native and independent of whether skill content is cached by an agent.
- [ ] Disable removes only unchanged managed files, revokes write/append authority and engine leases, and leaves history readable/exportable. Settled durable commits remain intact; pending callbacks from revoked engines cannot change storage. Run filtered remote lifecycle tests and skill validation; commit M1 skill, then update recipes at later milestones.

## Task 9: TS project adapters and efficient streamed generation

**Files:** Create TS `src/project/{manifest,discover,adapter}.ts`, `src/stream/{decode,producer}.ts`, compact catalog interfaces, fixtures/benchmarks; native bounded project-file access and CLI stream byte framing.

**Consumes:** Kit, history, comments and bridge. **Produces:** project-aware component catalog, read-only discovery, delta generation, bounded HTML import and project renderer adapters.

- [ ] Write failing stream tests for split UTF-8/JSON chunks, malformed complete record, valid records around rejection, producer retry, CAS conflicts, backpressure and disconnect. Each committed operation renders before EOF; partial records never mutate.
- [ ] Swift authorizes and bounds project resource access; TS interprets token/component/asset metadata and records provenance/hashes. Discovery never automatically executes project code or installs dependencies.
- [ ] Provide a compact manifest and query component interfaces on demand. Native projects map recipes into the HTML kit; real web-project components run through an explicitly selected isolated project adapter. Built-in kit remains usable without project tooling.
- [ ] Support managed HTML fragments and full documents with explicit script/reload boundaries. Implement three-stage generation and one-node delta edits; retain resource/profile versions for restore. Measure first-use and warmed manifest/token costs, with identical task quality.
- [ ] Run TS/type/browser tests and native project-access integration; update skill recipes and commit M3.

## Task 10: Flight Control v2 integration

**Files:** Create native `Intake/Canvas/CanvasArtifact.swift`, `CanvasProvider.swift`, `CanvasAttachmentView.swift`; TS v2 event adapter; integrate current `IntakeService`/artifact UI at Qartez-verified anchors.

**Consumes:** Registered canvas IDs, TS engine commands and committed artifact references. **Produces:** optional v2 provider, intake/round linkage and old provider fallback.

- [ ] Inspect actual v2 entry points. Write failing contract tests for create/attach/reopen, round/checkpoint references, feedback destination and default legacy behavior. Do not assume a not-yet-built v2 entry exists.
- [ ] Native code maps intake/round/session identities to canvas IDs and forwards commands; TS owns all document/history processing. Persist artifact references rather than localhost URLs and never delete canvas history on tab close.
- [ ] Add explicit v2 rollout/provider switch after parity; legacy HTML import becomes a labeled new branch without fabricated event ancestry. The upstream Superpowers plugin stays untouched.
- [ ] Test paused/busy/closed session, engine_not_ready during review, app restart, missing engine/resource version and provider fallback. Run targeted remote tests and one scoped UI gate; commit M4 integration.

## Task 11: Recovery, fidelity, performance and release gate

**Files:** Create TS recovery/performance tapes and benchmarks, native bridge/storage fault harness, `docs/CANVAS.md`, test scripts; update affected architecture/build/follow-up docs to actual behavior.

**Consumes:** Tasks 1–10. **Produces:** measured acceptance report and release candidate, not an automatic deployment.

- [ ] Replay 1,000 nodes/10,000 events/100 checkpoints; compare full replay with snapshot+tail. Inject crashes before native append, after commit/before ack, after publication, during restore and engine replacement; compare committed hashes and original retry acknowledgments.
- [ ] Verify stale leases cannot append, old callbacks cannot publish, competing views cannot write concurrently, and engine startup/replay refuses mutation until ready. Test offscreen/hidden canvas throughput and idle eviction rather than assume browser scheduling.
- [ ] Verify export/import bundles journal/resources/notices, retains all branch/checkpoint references and protects in-progress exports from collection. Missing engine/kit version becomes explicit read-only/migration behavior. No automatic history pruning in first release.
- [ ] Measure producer→TS validation→Swift durable commit→TS publication→next-frame rendering separately. Report visible and hidden views. Proposed targets remain p95 under 100 ms for a small visible update, recovery under 2 s excluding compilation, and at least 40% fewer emitted repeat-edit tokens at equal quality. These are measured targets, not claims of success.
- [ ] Run native-reference kit matrix, keyboard/IME/state tests, default-off/skill isolation tests, receiver-ack uncertainty tests and v2 fallback. Node test runner validates the same TS semantics used in WebKit; it is not evidence of actual WebKit layout/material behavior.
- [ ] Run `scripts/test-canvas-engine.sh`, TypeScript checks, `scripts/test-canvas-browser.sh`, filtered remote native tests, `scripts/test-canvas-webkit.sh` and Debug/Release asset-build checks. Record failures and results; review licenses and commit task-owned changes. Deployment/release is a separate authorized action using the existing detached swap process.

## Coverage and planning disposition

| Requirement | Tasks |
|---|---|
| TS/browser engine and thin Swift host | 0–3 |
| Atomic durable commit before acceptance/render | 2–3, 11 |
| Hot updates preserving compatible local state | 3–4, 9 |
| Built-in high-fidelity Apple-style HTML/CSS kit | 0, 4, 11 |
| Hierarchical subtree history and retained branches | 1–2, 5–6 |
| Element comments and UI/session feedback | 7 |
| Default-off skill and user-owned configuration preservation | 3, 8 |
| Project design-system reuse and low-token streaming | 4, 9, 11 |
| Flight Control v2 migration | 10–11 |
| Engine-loss recovery and pending external commands | 0, 2–3, 11 |

Removed from the previous architecture: Swift CanvasKit/reducer, Swift semantic checkpoint/branch/annotation models, duplicate Swift/TS document validation, and any runtime Node host. Swift still validates native authority and commit integrity; moving semantics to TS does not grant preview code native privileges.

Remaining spike decisions: exact CSS/reconciler/tool versions, safe preview arrangement, concrete existing-control stream extension, and real-WebKit offscreen/recovery behavior. They are explicit Task 0 outputs. Product decisions and rollback semantics are settled. No runtime implementation or dependencies changed while redrafting; submit this revision for approval before execution.
