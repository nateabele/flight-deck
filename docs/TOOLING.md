# Tooling Versions

This document records the exact versions of the toolchain used for the Flight Deck walking skeleton.

## Tool Versions

- **Xcode**: 26.6 (Build 17F113)
- **Swift**: 6.3.3
- **XcodeGen**: 2.45.4
- **Zig**: 0.16.0

## Important Build Instructions

Build commands must run with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (full Xcode installed but not the active xcode-select dir; do NOT sudo xcode-select).

## Notes

Ghostty MIT license to be confirmed at the pinned SHA in Task 1.

## Task 1: Ghostty vendoring and libghostty build

### Pinned version

- **Repo**: https://github.com/ghostty-org/ghostty, vendored as a git submodule at `vendor/ghostty`.
- **Pinned tag**: `v1.3.1` (latest stable release tag at time of vendoring; `.gitmodules` tracks `branch = main` for future `git submodule update --remote`, but the checked-out commit is pinned to the `v1.3.1` tag, not floating `main`).
- **Pinned SHA**: `332b2aefc6e72d363aa93ab6ecfc86eeeeb5ed28`
- **License**: Confirmed MIT. `vendor/ghostty/LICENSE` starts with `MIT License / Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors`.

### Zig version required to build libghostty

Ghostty's `vendor/ghostty/build.zig.zon` pins `.minimum_zig_version = "0.15.2"`, and `vendor/ghostty/src/build/zig.zig`'s `requireZig()` enforces an **exact major.minor match** (patch must be `>= 2`), so the Homebrew-installed **Zig 0.16.0** (recorded above, from Task 0) is rejected at comptime:

```
error: Your Zig version v0.16.0 does not meet the required build version of v0.15.2
```

This requirement is not specific to the `v1.3.1` tag — `origin/main` (`tip`) also pins `0.15.2` as of this writing.

To resolve, Zig **0.15.2** (`aarch64-macos` tarball) was downloaded directly from https://ziglang.org/download/0.15.2/zig-aarch64-macos-0.15.2.tar.xz (sha256 `3cc2bab367e185cdfb27501c4b30b1b0653c28d9f73df8dc91488e66ece5fa6b`, verified) and extracted to `vendor/.zig-toolchain/zig-aarch64-macos-0.15.2/` (git-ignored; NOT installed via Homebrew, so it does not disturb the pinned brew `zig 0.16.0`).

### BLOCKER: Zig 0.15.2 cannot link on this host (upstream Zig bug)

With the correct Zig version (0.15.2) in hand, `zig build -Demit-macos-app=false` still fails — not with a version error, but with dozens of Mach-O linker errors for basic libSystem symbols, e.g.:

```
error: undefined symbol: __availability_version_check
    note: referenced by ...libcompiler_rt_zcu.o:___isPlatformVersionAtLeast
error: undefined symbol: _abort
error: undefined symbol: _bzero
error: undefined symbol: _clock_gettime
error: undefined symbol: _dispatch_queue_create
... (24 undefined symbols total)
```

**Root-cause isolation performed:**

1. Retried with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` (full Xcode, not just Command Line Tools) — identical failure. Both the Command Line Tools SDK and the Xcode.app-bundled SDKs on this host report SDK version `26.5` (`SDKSettings.plist`); there is no older SDK available locally to fall back to.
2. Isolated the failure to the Zig toolchain itself, independent of Ghostty: compiling a trivial `hello world` with `zig build-exe` reproduces the exact same undefined-symbol errors under the downloaded **Zig 0.15.2**, while the same trivial program builds and runs fine under the Homebrew **Zig 0.16.0**. This confirms the break is in Zig 0.15.2's self-hosted Mach-O linker, not in Ghostty's build graph or this repo's environment setup.
3. Confirmed via web search this is a known, already-reported upstream issue: **ziglang/zig #31658**, "MacOS Builds Are Failing w/ XCode 26.4" (https://codeberg.org/ziglang/zig/issues/31658). Triggered by an SDK/toolchain change introduced in Xcode 26.4+ (this host has Xcode 26.6 / CLT 26.6). Affects Zig 0.15.2 and some 0.16.0-dev builds. Fixed by PR #31673 (https://codeberg.org/ziglang/zig/pulls/31673), **targeting the 0.16.0 milestone** — there is no confirmed 0.15.x patch release with the backport as of this writing.
4. Checked for an escape hatch via `-flld` (force LLD instead of Zig's self-hosted linker): rejected outright by Zig 0.15.2 — `error: using LLD to link macho files is unsupported` for Mach-O targets.
5. The one documented community workaround (installing older Xcode 26.3 Command Line Tools and running `sudo xcode-select --switch`) requires a system-wide developer-tools change and `sudo`, which is out of scope for this task (and would conflict with the Xcode 26.6 pin recorded above for later tasks) — not attempted.

**Status:** libghostty could not be built on this host as of 2026-07-09. `vendor/ghostty-artifacts/` was not produced. This is an environment/upstream-toolchain blocker, not a mistake in the submodule pin, Zig version selection, or build invocation.

**Unblock options (not executed, for whoever picks this up):**
- Wait for an official Zig 0.15.x patch release (0.15.3+) containing the PR #31673 backport, or for Ghostty to bump `minimum_zig_version` to 0.16.x (which already works on this host).
- Build a patched Zig 0.15.2 from source with PR #31673 cherry-picked (self-contained under `vendor/.zig-toolchain/`, no system changes needed, but untried here — see "do not thrash" guidance in the task brief).
- With explicit user approval: install Xcode 26.3 Command Line Tools and temporarily `sudo xcode-select --switch` to them for the libghostty build step only, then switch back.
