# Native peer messaging implementation

1. Add hermetic transport/registry/framing/permission/idle/journal regression tests;
   record a failing run before implementation.
2. Implement the native helper and its private host pipe interface. Port protocol
   fixtures from the standalone bridge, preserving native identity and permission rules.
3. Add app-owned lifecycle/discovery/delivery, authenticated CLI requests, and bundled
   agent instructions. Isolate tests and debug builds from live account registries.
4. Verify helper footprint, native interop, targeted app tests and Release packaging.
5. Update operator docs, commit only feature changes, and activate a verified Release
   via the detached release script with rollback available.

Work is performed in an isolated worktree because the main checkout contains active
changes owned by other sessions. No concurrent user changes are incorporated or reverted.

## Verification and release status (2026-10-24 UTC)

- Implemented and committed on `feat/native-peer-messaging`, rebased onto master
  `85822a29` without changing the main worktree.
- 58 targeted app tests passed on the configured UI-test Mac, including real
  helper processes, automatic Codex discovery, the authenticated control socket,
  draft preservation, dialog veto, tab cleanup, and idle helper crash supervision.
- 22 hermetic native protocol assertions passed against the Release helper,
  including verified-PID authentication, receipt/idle correlation, pending-inbox
  recovery, and persisted duplicate suppression.
- Real native discovery/round-trip/idle messaging passed with Claude Code 2.1.309
  in a dedicated Flight Deck-created tab. The test tab was closed afterward.
- CLI/MCP smoke checks passed; the skill validator passed.
- 32 simultaneous helpers averaged 8.52 MiB RSS and accrued zero measured CPU
  seconds during a ten-second settled-idle sample. This test exposed, and then
  verified the fix for, a simultaneous private-directory creation race.
- Both Linux host architectures rebuilt. The local app release preserves the
  installed/published installer checksum instead of pointing at unpublished assets.
- Shared iOS frameworks built for simulator/device; phone app/tests compiled for
  arm64. The generic Intel simulator build has a pre-existing ARM stack-sampler
  compilation error unrelated to peer messaging.
- Release signing/team/flavor preflight passed. No app replacement was performed.

**Activation is blocked on selecting the release baseline.** The installed app's
binary contains `CodexNativeDialogs` and `CodexSharedConnection`, but those source
files are untracked in the main checkout, alongside additional unfinished cloud,
budget, CLI, and UI work. Rebasing onto committed master cannot preserve the
already-installed, uncommitted features. Installing the isolated bridge release
would roll them back; building the whole dirty checkout would ship other unfinished
changes. Ask the maintainer to choose either a combined working-tree build or a
commit/stable baseline from the concurrent work before activating the update.
