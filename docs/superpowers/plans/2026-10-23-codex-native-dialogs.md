# Native Codex dialog implementation

1. Add bidirectional RPC regression tests, prove the id-collision failure, then fix dispatch.
2. Connect to the managed per-account daemon using its private Unix WebSocket; keep it alive
   when Flight Deck disconnects. Version-gate the migration and preserve legacy behavior.
3. Track native pending requests and statuses; subscribe attached threads and replay on rejoin.
4. Map approvals, explicit permissions, questions and MCP elicitations to phone offers and
   validate answers against the current native request. Add local-menu screen fallback.
5. Test request replacement, duplicate answers, resolution, reconnect and account separation.
6. Run focused unit tests, the isolated live protocol probe, macOS/iOS build gates and release
   preflight. Update docs and install the validated release with a detached swap.

## Live regressions, October 24

- A screen approval containing a Python heredoc exposed only `PY` on the phone.
  The screen fallback now preserves the entire approval block: reason, environment and
  multi-line command. All of that context contributes to the prompt identity.
- Execute's answer moved the cursor but did not submit. The diagnostic recorded
  `post-move-landing` at the old row before the repaint arrived. Codex screen answers now
  wait up to ten 120 ms settle cycles, never resend arrows, and require the same prompt,
  selected row and exact label before Enter. Claude's existing drive is unchanged.
- Both regressions were reproduced before the fix: 39 focused tests, six assertion
  failures across the two new cases.

## Sidebar status follow-up, October 24

A live read-only daemon audit found Execute 3 active while Flight Deck reported idle;
Execute 2 and Execute 4 were idle on both sides. Runtime attachment could issue its
subscription before the account's initialize handshake completed, then never rejoin.
The repair defers native observation until handshake completion, rejoins existing
attachments, and reconciles metadata periodically without loading standalone threads
or replaying their history. The screen approval override remains in force.

Status repair validation: the pre-fix runtime run executed 12 tests with one failure
(the late connection never published busy). The repair also verifies recovery from a
missed idle notification, no polling after detach, and no resume for `notLoaded` threads.
Native metadata reconciliation runs at most once per thread every five seconds, with
bounded requests and one in-flight reconciliation per thread.

Final review caught two additional cases, both reproduced before fixing (15 runtime
tests, two failures): joining a source already busy must replay its activity to the new
subscriber, and `notLoaded` must relinquish native authority to cached rollout activity.
Rollout activity is now retained while native status is authoritative for that handoff.
The isolated broad run executed 7,540 cases; only PortForwarderTests.testAutoPicksFreePort
failed (post-release port rebind assertion). The menu-bar lane passed.

Final focused run: 134 tests passed, including all 15 runtime attachment tests and
the full PortForwarderTests class (the broad-run failure passed in isolation).
Independent review found no remaining blockers in the late-subscriber and ownership
handoff corrections.
