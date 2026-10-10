# Handoff: delegated submodules, what is still open

**When every item below is resolved, delete this file in the commit that resolves the last
one** (`git rm docs/HANDOFF-submodules-followups.md`), and move anything that stays a known
limitation into [FOLLOWUPS.md](FOLLOWUPS.md) first. This file is a checklist for open work,
not a record: the reasoning lives in the commit messages and in ARCHITECTURE.md's
"Submodules" paragraph. When you resolve one item but not all, tick it here (`[x]`), say how
it was checked, and commit that edit.

Context: submodule support for delegated runs landed in PR #1
(`cloud/delegation-submodules`, merged into `infra-hosts` as `da06a48`). The follow-ups
branch `cloud/submodules-followups` (`9a627a6`..`e606f4f`) was built and tested on Linux only:
HostKit 428/428 and HostDaemonLinux 37/37 in `swift:6.3-noble`. Nothing under `Sources/`
changed on that branch.

## Needs a Mac (nothing here has been compiled or run on Darwin)

- [ ] **Build the app on the follow-ups branch.** `./scripts/build.sh`. HostKit's
  `GitRunner` now starts git with `posix_spawn` through `Spawner.spawnProcess` (Runner.swift)
  instead of `Process`. The app's own `Snapshotter` and `ResultApplier` calls go through it,
  so every controller-side git call takes the new path on Darwin. It uses the same calls
  Runner's spawner already compiles there (`posix_spawnattr_setpgroup`,
  `POSIX_SPAWN_CLOEXEC_DEFAULT`, `posix_spawn_file_actions_addchdir_np`).
- [ ] **HostKit on macOS.** `./scripts/test-hostkit.sh`. Watch for:
  - `GitRunnerSpawnTests` skips on Darwin (it reads `/proc`), so the process-group behavior
    of item 2 has no Darwin test. Confirm by hand once: start a long `git fetch` over a fake
    `GIT_SSH_COMMAND`, cancel it, and check with `ps -o pid,pgid,command` that git and its
    ssh shared a group and both are gone.
  - `SubmoduleFixtures.swift` has `#if canImport(Darwin)` branches for `posix_spawn` and
    sockets that have only been compiled on Linux.
  - The daemon-based tests need `git daemon` (Xcode's git ships it); they skip without it.
- [ ] **App unit suite.** `./scripts/test-unit.sh`, in particular `DelegationServiceTests`,
  `LiveAdapterTests`, `DelegationLoopbackTests` and `LiveHostLinkTests`.
- [ ] **The guard in `DelegationService.push`** (from PR #1, commit `d132f5b`, never compiled
  or tested anywhere). A snapshot with submodule pins sent to a live link whose capabilities
  are still nil (mid-reconnect) must be refused as `host_unavailable`, "reconnecting to
  <host> — try again". It has no test; add one with a `LiveHostLink` over a fake transport
  whose `capabilities` is nil.
- [ ] **Interop gate.** `./scripts/test-hostd-linux-interop.sh run` (one at a time; turn
  Settings → Hosting off first, per AGENTS.md).

## Needs a real second machine

- [ ] **A delegated run of a repo with submodules, across two machines.** Everything so far is
  real git in temp dirs on one machine. Then try this repo itself: its `vendor/boringssl` is
  on googlesource.com, so the host must reach that as well as GitHub.

## Known limits to carry into FOLLOWUPS.md before deleting this file

- [ ] Confirm FOLLOWUPS.md's "Submodules are refused — FIXED" entry still lists what remains
  true: dirty and unpushed submodules refused, the unpushed check reads local refs only,
  changes inside a submodule stay on the host, the host fetches with its own credentials,
  and caches are not `gc`ed.
- [ ] Record there, if still true: Foundation on Linux never reports a `Process` exit while a
  descendant still holds a descriptor inherited from that spawn (measured; why `GitRunner`
  and the test daemon no longer use `Process`). Other `Process` callers in HostKit and the
  app are still exposed.
