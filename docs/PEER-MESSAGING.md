# Cross-tab peer messaging

Flight Deck bundles `flightdeck-peer`, a Foundation-only native socket helper. It
runs no model, Node runtime, shell-command evaluator, or status polling loop. One
helper supplies each non-Claude tab's verified PID identity. Claude tabs keep their
real native inbox; a private, unadvertised relay is created only if a Claude tab
uses Flight Deck's CLI/MCP instead of native SendMessage.

## Use

Inside an agent tab:

```sh
flightdeck peer list
flightdeck peer send TAB_UUID 'Review this change and reply with findings.' --notify-when-idle
flightdeck peer receive --after 0
```

Exact names and native conversation UUIDs also work. Prefer the tab UUID when names
collide. A native `uds:` reply address works as a target. The sender comes from the
tab's existing authenticated control token, not text supplied by the model.
From a human shell, use `--from TAB_UUID` to select a sending tab.

Claude can continue to use native `ListAgents` and `SendMessage`; non-Claude Flight
Deck tabs appear as native peers. Other agents use the CLI. A bundled Claude skill
and an additive, managed Codex skill explain the interface. Edited or deliberately
deleted user copies of the Codex skill are never overwritten.

`flightdeck peer mcp` optionally exposes `ListAgents`, `SendMessage`, and
`ReceiveMessages` over MCP stdio. It uses the same authenticated local control
socket and runs no additional bridge daemon. Configure it in a client that can
launch Flight Deck's bundled `flightdeck` executable. Existing agents can use the
CLI without reloading MCP configuration.

## Delivery and permissions

`sent` means the native socket write completed, not that a model read the message,
completed a task, or started a turn. Inbox events have durable cursors. Native
held/denied/expired/released receipts and idle subscriptions retain their meanings.
An idle notice is not a successful task result.

Claude's native endpoint receives native frames. Other endpoints forward explicitly
labeled peer input through the agent's draft-preserving, dialog-aware text adapter.
Queued input stays pending until the store emits `promptTyped`. Queue expiry is
recorded as `host_failed`; the message remains readable in the durable inbox.
This is not exactly-once model execution: a crash after terminal submit but before
acknowledgement can replay input. Deduplicate logical requests by message ID.

Permission classes come from resolved launch options, not a model argument.
Prompting/bypass mismatches are held for a human decision in a Flight Deck sheet;
Deny is the default. Held bodies never enter agent-facing inbox results. No agent
tool or `peer` CLI subcommand approves a hold or changes inbound policy. Peer input
is never user consent. Claude retains its own native approval UI. Unspecified
options are conservatively prompting; custom permission overrides outside Flight
Deck's launch options can therefore require a human approval. Messaging never
relaxes execution permissions.

The existing Command Line scope applies: cross-tab sends need full scope; read-only
and own-session scopes cannot send to other tabs. Plain shell tabs can use the CLI
but do not autonomously consume or answer messages.

## Lifecycle, storage, and updates

The app starts helpers, sends event-driven title/status changes over private pipes,
and stops them when a tab closes. Pipe EOF stops them after an app crash. Restored
tabs republish under new helper PIDs, retaining the stable tab UUID and inbox.

Endpoints use mode-0600 `/tmp/cc-socks/<pid>.sock` sockets in a mode-0700 directory.
Registry records and keys are published into configured Claude account `sessions`
directories. Process-start fingerprints use UTC. Keys never enter journals.
Private journals live under the app state root at `peers/<tab-uuid>/events.jsonl`.
Debug uses an isolated registry/socket root and never installs skills into real
account homes.

Updates ship with Flight Deck: CLI, helper, protocol, and app service are built and
signed together. No separate npm install or bridge updater is needed. Follow the
ordinary verified Release swap and backup procedure; never launch another app
against the live state directory for testing. The standalone `claude-peer` package
remains usable outside Flight Deck, but do not run its daemon for a tab already
served by the built-in helper.

## Verification

- Remote `PeerMessagingTests`, `PeerCLIArgumentsTests`, and
  `PeerMessagingLoopbackTests` exercise framing, scope, real app/helper/socket
  routing, draft preservation, permission-dialog protection, and tab cleanup.
- `node Tests/peer-native.mjs PATH_TO_HELPER` uses temporary registries for native
  authentication, holds, receipts, idle controls, restart recovery, duplicate
  suppression, sender-PID checks, and cleanup.
- `node Tests/peer-footprint.mjs PATH_TO_HELPER 32` measures settled idle RSS/CPU
  and catches simultaneous shared-directory startup races.
- `node Tests/peer-claude-interop.mjs PATH_TO_HELPER DEDICATED_CLAUDE_TAB_UUID`
  is an opt-in real-model test. Create and close the dedicated tab with `flightdeck`;
  never point the test at someone's working conversation.

Measured 2026-10-23 UTC: 32 helpers averaged 8.52 MiB RSS each (272.70 MiB summed
RSS, which double-counts shared pages), with zero CPU seconds across a ten-second
settled-idle sample. Native discovery, bidirectional messaging, and correlated idle
notices were verified against installed Claude Code 2.1.309.
