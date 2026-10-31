# Visual Companion canvas and hierarchical history — draft design

Status: redrafted for the agreed TypeScript-engine architecture, 2026-10-26. Product scope and history semantics confirmed by the user; implementation has not started. Remaining empirical choices are explicit spike outputs, not assumptions of proven compatibility.

## Intent and requirements

Evolve Superpowers Visual Companion into a persistent preview canvas: incremental rendering that preserves compatible interaction state; fast, low-token generation with visible progress; project-specific design fidelity; meaningful session interactions; element-anchored comments; and hierarchical checkpoints with element-level backward/forward restoration.

The agent still generates designs. The runtime renders, versions, annotates, and transports them. It does not call a model to render each operation. Local interactions remain local unless the user submits them to the originating session.

## Confirmed product decisions

1. Build directly into Flight Deck, exposed as an opt-in skill. This is the eventual replacement for Visual Companion in Flight Control v2. Do not create a separately installed runtime or require users to run a Node server.
2. Restoring an element restores the whole authored subtree, preserving compatible current interaction state where possible.
3. Preserve newer history: restore appends an event and editing an older version retains the newer branch.
4. Ship a built-in HTML/CSS UI kit capable of high-fidelity SwiftUI/AppKit-style controls. Prefer license-compatible OSS and adapt missing components rather than starting from scratch.
5. Use a thin Swift host with a TypeScript canvas engine in WKWebView and Swift-backed durable storage. Node is build/test tooling only; there is no runtime Node process.

## Proposed implementation architecture

Flight Deck owns canvas/window lifetime, session/project identity, opt-in preference, native authorization, persistence and agent delivery. `Resources/Canvas/src/engine/` is the single semantic implementation: TypeScript document validation/reduction, events, revisions, checkpoints, branches, restore planning, annotations and resource dependency logic. The same browser bundle owns rendering and interaction state. `Sources/FlightDeck/Canvas/` contains a thin host, SQLite/blob persistence adapter, engine coordinator, resource handler and validated WebKit bridge. There is no Swift CanvasKit model/reducer and no runtime Node process. Node executes TypeScript unit tests and builds the bundled resources during development. Existing CLI/local-control infrastructure forwards commands to the registered engine; no extra WebSocket implementation is needed for the embedded canvas.

Opt-in means disabled by default and an explicit enable action before the skill is exposed or a canvas is created. Use a unique `flightdeck-canvas` name; user modifications/deletions must survive managed skill refresh. Claude's materialized bundled plugin and Codex's account-scoped skill delivery are existing patterns, not permission to overwrite user instructions. Debug and UI-test builds use separate state/skill destinations. Enabling the skill does not start a session or switch existing Flight Control behavior automatically. Disabling removes only unchanged managed skill files and blocks mutations; retained history remains readable/exportable.

The initial UI kit uses an internal semantic component catalog, hiding upstream CSS classes from generated operations. Puppertino is the proposed CSS baseline; compare MacVue as an alternative for control fidelity before pinning. Project tokens/assets override kit defaults. Native SwiftUI/AppKit controls are used as visual references and metric fixtures, not compiled for every preview update. True native execution remains a separate renderer capability.

These implementation choices remain subject to the validation spikes and review. The confirmed product decisions above do not depend on the library choice.

## Current evidence

Installed plugin: `superpowers@openai-curated`, cache revision `d416fd5a`, manifest version 6.3.0, 14 skills. Claude's local package is 7.0.0. Do not edit either plugin cache in place.

Current source: `skills/brainstorming/scripts/` in the plugin. `server.cjs` chooses the newest HTML by mtime, wraps fragments in `frame-template.html`, injects `helper.js`, and broadcasts whole-page reloads. Adding a new HTML filename clears `state/events`. Only messages with truthy `choice` are persisted. `start-server.sh` and `stop-server.sh` own session setup and shutdown. Browser clicks do not wake the session themselves.

Previous live probes confirmed authenticated HTTP, fragment wrapping, full-document rendering, WebSocket click recording, reload messages, and event clearing. They also confirmed two defects: literal `$&` is interpreted during fragment replacement in the Codex package, and `brainstorm.choice(value)` without a `choice` field is not persisted. The Claude 7.0.0 package fixes the fragment replacement problem. Baseline behavior must be captured again against the chosen source revision at implementation time.

## Persistent document and event model

Give each node an immutable ID independent of DOM position, visible text, or CSS selector. Moving a node keeps its ID; duplicating one allocates a new ID. A node has a type, authored props, child IDs, asset references, and optional source/component mapping. Deletion creates a tombstone; IDs are never reused.

Separate authored document state from ephemeral interaction state and durable feedback. Typing and scrolling do not produce design revisions. Form submission, comments, checkpoint creation, and approved session actions do produce durable events. Input values are local unless their serialization is explicitly enabled; password/file fields and opaque browser state are excluded.

The TypeScript engine defines event semantics; Swift storage assigns the authoritative durable journal sequence during atomic append. Each committed event has:

```ts
type EventEnvelope = {
  schemaVersion: 1;
  canvasId: string;
  documentId: string;
  sessionId: string;
  eventId: string;       // caller-stable retry key
  seq: number;           // storage-assigned total ordering, monotonic
  actorId: string;
  kind: string;
  scopeId: string;
  branchId: string;
  baseRevision: string;
  revision: string;
  transactionId: string;
  payload: unknown;
};
```

Sequence and design revision are different clocks. Every durable event advances the canvas journal sequence; only authored-document transactions advance the design revision. Comments, checkpoint creation, delivery acknowledgments, and diagnostic records retain the current design revision (`baseRevision === revision`); feedback payloads separately retain their original `subjectRevision`. An annotation received after another edit remains attached to the revision it describes rather than becoming a stale design mutation. Invalid state-changing commands return structured refusal responses; they cannot move a branch head. Refusal diagnostics may be journaled without changing the design revision.

Canvas/document/session identity comes from service-owned registration and the authenticated caller context, not arbitrary producer fields. A canvas can outlive its originating tab; its stored origin remains provenance, not proof of a currently live delivery destination. Deliberate reassignment is a distinct user action. The opt-in service rejects writes while disabled even if an already-running agent cached the skill text.

For each durable event ID, the idempotency fingerprint covers the complete canonical submitted command, excluding storage-assigned sequence, attempt-specific engine lease/expected journal sequence, and derived events/revisions/snapshots. Swift receives the original command as opaque JSON and recomputes its fingerprint without interpreting operations. Check idempotency before stale-base checks so a retry of a committed command returns its original acknowledgment, while native lease/permission checks remain mandatory. On a duplicate acknowledgment, TS discards any speculative candidate and catches up from stored records; it cannot publish newly computed duplicate state. Distinct concurrent design commands still require the current base revision; the initial version returns a conflict rather than silently rebasing even disjoint edits. Local UI state does not invalidate design commands.

Validate envelopes and kind-specific payloads at runtime. Reject stale preconditions, duplicate IDs, cycles, invalid parents, missing component versions, and invalid assets. Duplicate event IDs with identical payload return the original acknowledgment; differing payloads are an error. Reads of history do not mutate document state.

### Commit boundary and persistence bridge

The TS engine prepares a candidate state and versioned event batch, validates it, and calls Swift storage with an expected journal sequence and host-issued engine lease. Swift does not compute trees, branches, checkpoints or restores. It checks native authorization, envelope/schema version, identity, payload limits, engine lease, canonical request fingerprint, expected sequence and referenced blob existence. It atomically stores the batch, deduplication record, optional opaque snapshot and approved delivery descriptors, then assigns committed sequence numbers. TS publishes candidate state and renders only after the durable acknowledgment. A storage error leaves the last committed model and view intact.

The narrow native API is `load`, `append`, `putBlob`, `getBlob` and capability-gated `deliveryStatus`; window/opt-in/session controls remain native host actions. `append` returns committed sequence and a duplicate flag. Swift stores TS snapshot/checkpoint/branch data as versioned opaque records or blobs; indexes are rebuildable caches produced by TS. It must not become a second semantic engine by checking element ancestry or computing revision hashes. Native checks still apply even to malformed or overprivileged engine requests. Snapshot bytes have content hashes checked by storage; TS validates their internal state/schema on recovery.

Use SQLite transactions for committed events, idempotency metadata, snapshots and native delivery outbox. Store large immutable blobs by content hash: write/fsync blobs before committing references; unreferenced blobs after a crash are collectible. Replay reads events after the snapshot sequence. TS reconstructs the exact document, scoped history and annotation model; only an explicit upgrade procedure may change their meaning. Native delivery status lives in a separate host-owned receipt table and does not race the semantic journal sequence. TS may record the observed status as a new event later. Read-only export bundles stored records/resources without needing a running semantic engine.

### Engine lifetime, crash recovery and external commands

Exactly one registered TS engine may write a canvas journal at a time. Swift issues a new engine instance/lease on boot and revokes the previous lease after termination or replacement. Opening a second view does not create a second writer. Closing the canvas window retains its engine while its session is active; app shutdown or idle eviction may dispose it. A later CLI command can boot the bundled engine in an offscreen WKWebView without bringing a window to the foreground. This is an app-hosted browser engine, not a headless native reducer; offscreen timing and recovery must be measured on real WebKit.

Coordinator states are stopped, loading, replaying, ready, failed and disabled. Mutating CLI commands execute only in ready. Loading/replaying reports recoverable `engine_not_ready` with retry guidance instead of acknowledging uncommitted work or creating an unbounded in-memory queue. Limit buffered input and in-flight appends; stream producers wait for acknowledgments. Missing renderer versions, recovery corruption and disabled state are distinct visible refusals. Stored history/export remain readable while mutations are unavailable.

If the web process dies before commit, the candidate never becomes accepted. If storage commits before TS or the CLI sees its acknowledgment, recovery replays that event and a retry with the same event ID returns the original result. A retry's canonical fingerprint must match; check stored idempotency before stale base/sequence. Revoked-engine append or render acknowledgments are rejected. Replay never executes agent actions or network side effects. Swift drains only delivery descriptors already committed to its durable outbox, subject to current native permissions and receiver idempotency; engine callbacks cannot directly send arbitrary prompts. Uncaptured local browser state may be lost on termination, but acknowledged authored history must not be lost.

A generation streams many small valid transactions rather than a partial large transaction. An incomplete JSON line cannot alter the canvas. Explicit read of a checkpoint/version does not move its branch head; an applied restore is a committed transaction through the same engine/storage boundary.

## Hierarchical checkpoints

The document hierarchy and revision graph are distinct. Checkpoint scopes are document, screen, section/component, and element; each captures its selected root and descendants. Nested scopes have parent checkpoint references for grouping. Every document checkpoint records a consistent manifest of its included subtree versions. A component-level checkpoint can be created between document checkpoints without manufacturing a new full-document copy.

Checkpoint metadata includes ID, label, scope root, parent checkpoint ID, source branch/revision, sequence, tree hash, dependency manifest hash, and optional supported interaction-state snapshot reference. Referenced snapshots are immutable and content-addressed. Store structural sharing plus periodic materialized snapshots; no deep-copy-per-token implementation.

Supported commands: create/list/inspect checkpoint, preview restore, restore, move backward/forward along an explicitly selected lineage, fork, compare, and apply a selected subtree from another branch. The first release supports selective subtree adoption; arbitrary automatic branch merging is excluded.

Distinguish three relationships: parent checkpoint groups nested scopes; parent revision records document ancestry; source checkpoint records where a restored subtree came from. Never use `parentCheckpointId` as both containment and undo ancestry. Each scoped history entry records its scope root, source checkpoint, previous scoped entry, and resulting document revision. Back/forward follows that scoped lineage, with an explicit choice at a fork. Multiple scopes may consequently show different provenance in the same document revision. Document branches retain their original tips; new edits after a historic restore append to a new branch with explicit fork/source provenance. New descendant checkpoints group under a new or selected immutable ancestor checkpoint; they never change an older ancestor manifest retroactively.

### Restore example

`page` contains `sidebar` and `main`. At checkpoint C1 the sidebar is narrow. C2 makes the sidebar wide and edits main. Restoring `sidebar` to C1 creates revision C3: narrow sidebar plus the current main. C2 remains addressable. Forward to C2 restores its sidebar without reverting main. An edit to the C1-derived sidebar starts a new lineage; the UI asks which lineage to follow when forward is ambiguous.

### Restore rules

- Verify the target checkpoint belongs to this document and contains the selected scope ID. Root identity must match. Restore authored props, descendants, and internal ordering atomically.
- Keep unrelated nodes unchanged. Restore the selected root into its current parent/slot by default; ancestor placement is outside the selected scope. Restoring a deleted root requires an explicit valid insertion parent/anchor. Never resurrect a missing ancestor implicitly.
- A node moved outside the scope since the checkpoint creates an ownership conflict. Do not duplicate, steal, or silently delete it; offer expand-scope, clone-with-new-IDs, or cancel. Detect collisions before mutation.
- Preview external dependencies: component/module versions, shared tokens, fonts/assets, action bindings, cross-node references. Reuse immutable pinned dependencies when compatible. If a shared token or provider requires changes outside the scope, require explicit expanded scope or isolation; otherwise block with a concrete conflict.
- A restore carries expected current revision and scoped hash. Reject stale restores and return a fresh comparison; do not apply a silently recomputed restore while another actor changes the target.
- Preserve current compatible local state for surviving IDs and control types. A requested historical-state restore affects only explicitly captured serializable state. Never replay network requests, file writes, agent actions, or other external side effects.
- Record source checkpoint, affected IDs, before/after hashes, dependency resolution, state policy, and discarded incompatible state in the restore event. A subsequent restore can reverse this event.
- Comments survive rollback and remain tied to original revision and element ID. Deleted elements leave orphaned threads; resurfacing the same identity can make them visible again. Switching history does not erase feedback.

## Rendering and streaming

The canvas shell stays mounted inside WKWebView. A preview adapter renders inside an isolated frame so imported project styles do not overwrite history controls or annotation UI. Keep the frame document stable during incremental updates. The adapter exposes mount/apply/captureState/restoreState/resolveElement/dispose. Bind stable node IDs to preview elements. The native bridge accepts only schema-validated, size-bounded messages from its registered shell/frame, binds them to the owning canvas/session, and denies arbitrary file reads, navigation, or native command execution. Restrict bundle resource requests to an allowlist and keep preview-authored code away from privileged bridge capabilities.

HTML mode uses keyed DOM reconciliation; component mode uses the project's renderer/HMR and registered serializers. Preserve focus, caret/selection, scroll containers, expanded sections, local navigation, and compatible control values. Explicit authored resets and changes to control identity/type take precedence and report a reset. Composition/IME input must not be interrupted by a background patch.

The state adapter tracks dirty values separately from authored defaults. A change to a default preserves a dirty local value for a compatible surviving control; an explicit value reset/binding update overrides it. Compatibility includes stable node ID, control kind, serializer version and binding identity, plus validity under new constraints (for example selected option still present). Capture supported descendant state before reconciliation; restore it after applying the whole subtree, with a reset report for incompatible entries. Defer updates that replace an active composition target until composition ends; structural invalidation must have a visible reset policy. Deleted controls have no automatic state resurrection unless a checkpoint explicitly captured supported state. A WebKit process crash can recover authored history, but only previously captured compatible interaction state; do not promise recovery of every unsent keystroke.

Initial component operations use a registered catalog with values and action IDs, not executable handlers supplied as strings. The trusted shell mediates preview-local events; project scripts get neither the local-control token nor direct native handlers. In the spike, prove that a preview iframe cannot access the shell/bridge or fetch non-allowlisted resources, including after navigation. If this cannot be proven for a custom scheme/frame arrangement, use a separate unprivileged preview web view and a validated message channel; do not ship a shared privileged document as a shortcut.

Operations: insert/move/remove node, set/unset authored prop, replace text, register immutable asset/module, bind action, and create checkpoint. Accept complete NDJSON operations through `flightdeck canvas stream`; acknowledge accepted sequence/revision through the local control path. Verify existing CLI framing supports incremental commands before choosing its concrete extension; otherwise add a dedicated bounded local stream owned by the same control service and permission model. Batch sibling updates within a render frame, not across an entire agent turn. Show progress and last-good state; invalid operations leave it intact. Agent tool batching limits perceived streaming speed: runtime streaming does not expose model reasoning or tokens before the harness emits them.

Generation uses a compact project manifest, reusable components, fixtures, assets, and tokens. Query component interfaces on demand. Emit deltas against acknowledged revisions, not whole screens. HTML escape hatches are explicit managed subtrees; arbitrary full-document scripts require an adapter reload boundary and cannot promise preserved JS state.

## Fidelity

The built-in kit is a first-release deliverable, not deferred to native preview support. Its first catalog covers text/layout stacks, buttons, text/search/secure fields, checkboxes, radio groups, toggles, sliders, steppers, segmented controls, pop-up controls, progress, lists/tables, toolbars, sidebars, windows, popovers, and sheets. Required states include light/dark, accent, mini/small/regular/large where applicable, enabled/disabled, focused, pressed, selected, active/inactive window, reduced motion/transparency, and keyboard operation. Pin a target macOS appearance/version; do not silently mix a new OS theme into an older project.

SwiftUI-oriented names (`Button`, `Toggle`, `Picker`, `Form`, `NavigationSplitView`) and AppKit-oriented aliases (`NSButton`, `NSSegmentedControl`, `NSTextField`, `NSSplitView`) map into a common semantic catalog with documented limits. This is a visual/interaction vocabulary, not arbitrary Swift-to-JavaScript compilation. Unknown/custom views use project recipes or managed HTML escape hatches. Serialize values/actions separately from presentation so DOM reconciliation and checkpoint restore keep user state.

Use [the OSS research](2026-10-25-canvas-ui-kit-research.md) to choose the baseline. No candidate has been visually validated inside Flight Deck yet. Acceptance requires a native reference gallery and HTML gallery on identical OS/appearance/scale settings, with measured bounds, typography, alignment, and interaction checks. Calibrate missing or mismatched controls in Flight Deck-owned CSS; identify unsupported effects visibly. Test actual WKWebView as well as headless browser tooling. Fonts/icons carry their own permissions: a CSS library's license does not license Apple font files or symbol assets.

A project manifest records provenance, platform, component references, required providers, fonts, assets, tokens, viewport/device presets, and immutable version hashes. Discover candidates read-only; importing/running project code happens in an explicit preview process with fixture network/services. Do not install or execute arbitrary project code merely because discovery found it.

The web adapter renders real project components with styles/providers and mocked data. A token-only HTML preview has an approximation label. Native adapters have their own rendering/state/element-mapping capability declarations; screenshot-only capture cannot claim interactive per-control history. Shared resource edits invalidate affected previews and require visible dependency handling during restores.

## Interaction and annotations

Typed events include selection.changed, action.invoked, form.submitted, annotation.created/replied/resolved, checkpoint.created, restore.requested/applied/rejected, preview.error, and session.delivery.*. Local events and preview action handlers do not resume agents by default.

TypeScript owns feedback semantics and delivery presentation. Swift exposes native delivery capabilities and drains a durable outbox bound to the originating project/session. User actions such as Send comments or Revise selection send compact, revision-tagged context through supported agent channels; do not type into arbitrary terminals. If wake/resume is unavailable, retain an inbox for the agent's next turn. Record queued/delivered/acknowledged status, retry by stable message ID, and deduplicate at the receiving integration. End-to-end exactly-once execution is not promised without receiver support. On disconnect or a busy host, retain pending work; no repeated unsolicited prompts.

Annotation mode highlights an element without invoking its normal action. Store thread ID, element ID, revision, text, replies, status, screenshot crop hash, and fallback text/accessibility/source anchors. Stable identity wins; fallbacks produce suggested reattachment, never silent attachment. Handle iframe coordinates, scrolling, zoom, and device scale. Existing threads remain accessible when their anchor disappears.

## Delivery and validation

Release in working slices: app-owned replayable canvas and opt-in skill; built-in Apple-style kit; scoped history; annotations/session inbox; project design-system adapter; optimized generation; Flight Control v2 replacement integration. Preserve a legacy HTML import path and an explicit export path. Do not patch marketplace caches. Replace Visual Companion in Flight Control only after parity tests and an explicit v2 rollout flag; keep rollback to the previous provider available. Canvas document/session IDs attach to intake/round artifacts rather than relying on a temporary localhost URL. Closing a tab must not delete its canvas history. True native rendering can follow independently of the built-in HTML/CSS kit.

Targets are proposed budgets, not measured claims: render a complete accepted small operation within 100 ms p95 locally; 1,000 visible nodes, 10,000 events, and 100 retained checkpoints as the initial benchmark fixture; recover that fixture within 2 seconds excluding project module compilation. Measure agent tokens and first meaningful paint against identical legacy design tasks. Aim for at least 40% fewer emitted tokens on repeat component-based edits; report first-run manifest extraction and model/tool latency separately. Keep quality and functionality equal when comparing.

Measure latency as producer submission → durable commit → renderer applied → next animation frame, reporting each segment; receipt of a CLI reply alone is not proof of a visible update. Tag render acknowledgments with document revision and registered engine instance ID, and discard acknowledgments from a crashed/replaced instance. Report foreground visible rendering separately from hidden/suspended canvases. Legacy lacks selective restore, so benchmark that requirement as new capability, not a fabricated legacy speedup. Use repeated fixed tasks for token comparisons and record first-use versus warmed-cache costs independently.

Checkpoint resources include the UI-kit profile and immutable implementation version, not just its token values. An app update must either retain the required renderer/resource versions, migrate through an explicit recorded transformation with a comparison, or show the document read-only with a missing-version explanation. Never silently render an old checkpoint with whatever CSS the new app happens to ship. Export includes journal, referenced snapshots/resources, provenance and licenses; garbage collection traces all retained branch/checkpoint/export references before reclaiming blobs. No automatic history pruning is enabled in the first release; expose size and explicit archive/export actions.

Test deterministic replay, crash recovery, retries/reordering, branching, subtree restore, moved/deleted nodes, external dependencies, stale revisions, state preservation, comments across restore, reconnect, and session delivery. Browser tests run headlessly or on the dedicated test host; do not seize this Mac's foreground. No implementation, deployment, dependency installation, or live agent prompts are part of drafting these documents.
