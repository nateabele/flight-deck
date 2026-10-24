# Native cross-tab peer messaging

Flight Deck owns a peer endpoint for each non-Claude agent tab. Claude's own endpoint
remains authoritative for Claude tabs. A bundled, Foundation-only helper owns each
endpoint: native verification binds a socket to a live PID, so a single app PID cannot
stand in for many agents. No model, Node runtime, or status polling runs in a helper.

The app owns helper lifetime and supplies lifecycle/status changes over pipes. Native
NDJSON frames, registry fingerprints (UTC), authentication keys, permission classes,
held-message receipts, and idle subscriptions remain compatible with Claude Code
2.1.305. Closing a tab closes its endpoint. EOF closes a helper after an app crash.

An authenticated local `flightdeck peer` request uses the existing control socket;
it does not require broader Codex sandbox access. Sender identity comes from the
caller's tab token, never a request's claimed name. Discovery joins native peers to
Flight Deck tabs. Input is explicitly labeled as agent-originated, never user consent.
Native Claude receives native frames; other agents receive through their existing
draft-preserving, dialog-aware input channel. Permission-class mismatches are held
for an operator decision, never silently reclassified or delivered to a model.

Durable inboxes retain cursors and deduplicate message IDs. Sending means a transport
write, not model receipt or completed work. Approval controls are not agent tools.
Registries, keys, sockets, and journals are private to the current OS user. Debug and
release helpers are isolated, and a test must never publish into real account homes.

Ship only after hermetic native transport tests, app/CLI tests, a Release build,
measured idle helper RSS/CPU, and a real Claude interop check. Release activation must
follow the existing detached swap ritual; unrelated checkout edits are excluded.
