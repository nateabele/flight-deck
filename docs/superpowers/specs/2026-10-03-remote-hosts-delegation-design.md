# Remote hosts and delegated execution — design

Date: 2026-10-03. Status: design approved section by section in brainstorming; spec under review.

## 1. Goal and scope

Flight Deck runs on one Mac (the **controller**). Other machines (**hosts**, macOS or Linux,
x86_64 or arm64) run a small Flight Deck daemon, `flightdeck-hostd`. The work divides into four
sub-projects:

| | Sub-project | In this spec | Depends on |
|---|---|---|---|
| **A** | Host foundation: hostd, pairing, transport, host identity | **Yes** | — |
| **C** | Delegated execution: run a command from a session on another host, with git-based sync, streamed output, artifacts, change patches, background services with port forwards, and serialized screen use | **Yes** | A |
| **B** | Remote sessions: agent sessions in fd-abduco on a host, a mirrored terminal, host-side status, sleep, ⌘K, Flight Control | Outline only (§11) | A |
| **D** | Peer-agent delegation: a session hands a task to an agent session on another host | Outline only (§11) | A, B, C |

Build order: **A → C → B → D**. B and D get their own specs.

**Use cases this spec must serve:**
- A session on the laptop runs a screen-taking XCTest UI suite on a Mac mini.
- A session runs a heavy test suite on a bigger machine.
- A session brings up a Docker stack on a Linux box, and local code reaches it on `localhost`.

**Success criteria:**
1. You pair a Mac host and a Linux host from the GUI. Linux needs exactly one pasted command.
2. An agent in any Flight Deck session runs `flightdeck run --on mini -- xcodebuild test …`. It sees streamed output and the real exit code, as if the command ran locally. The run uses the session's uncommitted working tree.
3. Declared artifacts come back into the local tree. Tracked files the run changed come back as a reviewable patch.
4. `flightdeck up` keeps a Docker stack running on the host, with ports forwarded to the Mac's `localhost`.
5. Two screen runs on one host queue rather than collide.
6. The agent learns all of this from a skill bundled with Flight Deck, with no setup by you.

**Locked decisions from brainstorming:**
- Native pairing, not SSH.
- On a Mac target, hostd is part of Flight Deck.app in host mode.
- On Linux, hostd is installed with one pasted command.
- Delegation is a remote *command*, not a peer agent.
- Sync is git-based, cloned from the controller.
- Untracked files go automatically; ignored files go only when declared.
- Results that come back: streamed output and exit code, declared artifacts, changed files.
- Routing is explicit commands plus named recipes, with optional transparent routing rules.
- Services run in the background, with port forwards.
- The host owns its sessions (applies to B).
- Multiple viewers of one session are all live (applies to B).
- New remote sessions pick their project in a remote folder browser (applies to B).

**Non-goals for A+C:**
- Windows hosts.
- Reaching a host off the LAN without a tunnel. Tailscale is the answer there, as for the phone.
- Git LFS repos. They are refused with a clear error.
- Screen runs on Linux.
- Host-to-host trust.
- Forwarding the controller's environment or credentials to a host.

## 2. Architecture

```
 Controller Mac (Flight Deck.app)                  Target host
 ┌──────────────────────────────┐                 ┌──────────────────────────────────┐
 │ HostRegistry (paired hosts)  │                 │ flightdeck-hostd                 │
 │ HostLink ──────────────────── TLS-PSK + WS ──── HostServer                        │
 │   control frames (JSON)      │  one connection │   control: run/stop/sync/fs/info │
 │   channels (byte streams)    │  per host       │   channels: exec I/O, ports,     │
 │ SyncEngine (git snapshots)   │                 │             bundles, artifacts   │
 │ DelegationService ◄── control.sock ◄── `flightdeck …` in a session shell         │
 │ PortForwarder (localhost:N)  │                 │ Workspace store (§4)             │
 └──────────────────────────────┘                 │ Runner, ScreenLease              │
                                                  └──────────────────────────────────┘
```

### 2.1 Units

- **`HostKit`** is a new SwiftPM package that builds for macOS and Linux. It is Foundation-only, Swift 6, with no Network.framework, Security or CryptoKit. It contains:
  - `HostWire`: the control-frame types and their versioning.
  - `ChannelMux`: numbered byte-stream channels over one framed connection, with credit-based flow control per channel.
  - `Workspace`: the object store, the checkout pool, applying a snapshot, and creating the result commit.
  - `Runner`: spawn in a process group, a pipe or pty for I/O, signal escalation, and exit-status mapping.
  - `ScreenLease`.
  - `DelegateConfig`: parses and validates `delegate.toml`, and matches routing rules.
  - Process and peer-credential helpers behind `#if os(macOS)` and `#if os(Linux)`: `proc_listchildpids`/`LOCAL_PEERPID` on macOS, `/proc`/`SO_PEERCRED` on Linux.

  The app links HostKit as well, so `DelegateConfig` and the wire types have one implementation.
- **`flightdeck-hostd`** is an executable target. It is HostKit plus a socket layer:
  - **macOS:** the existing FleetKit TLS-PSK listener and WebSocket framing. The binary is bundled in `Flight Deck.app/Contents/Library/LoginItems` and registered with `SMAppService` as a login item, so it runs **inside the GUI login session** (required for XCTest UI runs; §6.3).
  - **Linux:** the same wire protocol on SwiftNIO, swift-nio-ssl and swift-nio-websocket, as a systemd **user** service with linger enabled.
- **App side** (`Sources/FlightDeck/Hosts/`):
  - `HostRegistry`: paired hosts, each with slot, key reference, name, platform and last addresses. Stored in `Application Support/Flight Deck/hosts.json`; secrets go in the Keychain, as for phone slots. It is never stored in `sessions.json`.
  - `HostLink`: one connection per host, with discovery, reconnection and the channel mux.
  - `SyncEngine`: the controller half of §4.
  - `DelegationService`: runs and services, and per-session ownership.
  - `PortForwarder`.
  - Settings → **Hosts** (paired hosts and Add Host) and Settings → **Hosting** (this Mac as a host).
- **CLI** (`flightdeck`): new subcommands (§5) that go over the existing control socket. A session shell never connects to a host itself. `DelegationService` authenticates the calling session with the existing `FLIGHT_DECK_CALLER` HMAC.

### 2.2 Trust boundaries

- A host accepts control frames only on connections whose TLS-PSK identity is a paired slot.
- The pairing listener is open only while a pairing code is on screen.
- Hosts never trust each other. If B later needs host → host delegation, it goes host → controller → host.
- hostd runs as the user who enabled it. Nothing runs as root.
- The controller's environment is never sent. Only `--env` values and recipe `env` values are sent.

## 3. Pairing, discovery, connectivity

### 3.1 Pairing a Mac host
1. On the target, open Settings → Hosting and turn on "Let other Macs use this Mac". This registers the login item.
2. Choose "Pair a controller…". The target shows a code and QR, valid for 2 minutes, and opens the pairing listener.
3. On the controller, open Settings → Hosts → Add Host. Hosts advertising `_flightdeck-host._tcp` appear through Bonjour. Choose one and enter the code.
4. The existing SPAKE2 exchange (`FleetKit/Pairing`, `SPAKE2`) derives a key. Both sides store a TLS-PSK slot, and the target closes the pairing listener.

### 3.2 Pairing a Linux host
1. Add Host → Linux shows one command: `curl -fsSL <release-asset-url> | sh -s -- --sha256 <digest>`. The asset is a pinned GitHub release built per architecture, and the script verifies the digest before it installs anything.
2. The script installs `~/.local/bin/flightdeck-hostd`, writes a systemd user unit, runs `loginctl enable-linger $USER`, starts the service, and prints a pairing code.
3. You type the code into the sheet. Pairing then continues as in §3.1, step 4. Avahi advertises the service when it is present; otherwise you type the address into the sheet.

**Gate:** before any other Linux work, a test must show that the Darwin `Network.framework` TLS-PSK client negotiates `TLS_ECDHE_PSK_WITH_CHACHA20_POLY1305_SHA256` (0xCCAC) over TLS 1.2 with the swift-nio-ssl (BoringSSL) server and exchanges WebSocket frames. If that fails, the spec returns to brainstorming for the Linux transport. Do not paper over it.

**Host connections use 0xCCAC; the phone link stays on 0x00A8.** The gate's first run (2026-10-04) found that swift-nio-ssl's BoringSSL has no `TLS_PSK_WITH_AES_128_GCM_SHA256` (0x00A8). The only PSK suites it has are 0x008C, 0x008D, 0xC035, 0xC036 and 0xCCAC. Darwin's default PSK offer is 0x00A8/A9/AF/AE, so a host and the Linux server had no suite in common, and the handshake failed with `NO_SHARED_CIPHER`. Darwin does offer and negotiate an appended 0xCCAC. It is also the stronger choice: ECDHE gives forward secrecy, and the cipher is an AEAD. So every host connection (`HostTransport`) pins it, Mac hosts included, which keeps one transport for both kinds of host. The Mac↔phone fleet and pairing channels keep 0x00A8 unchanged.

### 3.3 Connectivity
- **Address order:** Bonjour, then the last-known address, then the Tailscale address. This reuses the phone's ranking.
- **Reconnects:** `HostLink` reconnects with exponential backoff (1 s to 30 s). An `NWPathMonitor` change restarts the backoff immediately.
- **Liveness:** a WebSocket ping every 15 s. Three missed pings mark the host offline.
- **Offline display:** the host shows greyed in Settings → Hosts, and `flightdeck host ls` shows `offline (last seen …)`.

### 3.4 Versioning
- On connect, both ends send `hello {protocol: major.minor, capabilities: [...]}`.
- **Minor mismatch:** works. A feature the other side doesn't list is refused with a clear message.
- **Major mismatch:** the connection is refused. The controller shows "Update Flight Deck on mini" (Mac) or offers `flightdeck host update linuxbox` (Linux).
- **Linux updates:** `host update` pushes the binary that matches the controller's version over the existing connection. hostd swaps it in and restarts through systemd.

### 3.5 Revocation
- Unpairing on either side deletes the slot.
- Unpairing on the host also deletes `workspaces/<slot>/` (§4.1), including every included secret.
- The controller can also run "Forget host" while the host is offline. The host's slot then stays until someone removes it on the host.

## 4. Sync

### 4.1 Host storage

Root: `~/Library/Application Support/Flight Deck Host/` on macOS, `~/.local/share/flightdeck-hostd/` on Linux.

```
workspaces/<controller-slot>/<repo-root-commit>/
  store.git/                        bare repo: the object store
    refs/fd/heads/<wt-key>          the local HEAD each worktree last sent
    refs/fd/snapshots/<wt-key>/<n>  last K snapshot commits per worktree (K=5)
    refs/fd/results/<run-id>        result commits until fetched or 24h old
  checkouts/<wt-key>-<slot>/<worktree-basename>/   one `git worktree` per pool slot
runs/<run-id>/                      output spool, metadata, result
```

- `<repo-root-commit>` is the repo's root commit, so two local clones of one repo share objects. When a repo has more than one root, the oldest one is used.
- `<wt-key>` is a stable hash of the controller's absolute worktree path.
- The innermost checkout directory carries the local worktree's basename. That keeps the derived `docker compose` project names identical to the local ones.
- The **object store** holds real history (only as far back as needed), snapshot commits and result commits. Snapshot trees contain the content of untracked files and of declared ignored files. It never holds build output or undeclared ignored files.

### 4.2 Snapshot (controller)
Every run, on the session's current worktree:
1. A temporary `GIT_INDEX_FILE` is seeded from `HEAD`. Then `git add -A` runs (it honors `.gitignore`), followed by `git add -f` for each `include` path. `git write-tree` and `git commit-tree -p HEAD` produce the snapshot commit.
2. The user's index, stash, reflog and branches are never touched.
3. The snapshot is kept under `refs/flightdeck/snapshots/<host>/<n>` so `gc` can't prune it. Older ones are trimmed to K.
4. Submodules are handled recursively. Each submodule is its own workspace, and the snapshot pins its gitlink.
5. A repo that uses LFS (a `filter=lfs` attribute on any tracked path) fails with `flightdeck: LFS repos are not supported for delegation yet`.

### 4.3 Transfer
1. The controller sends `sync.begin {repoRoot, wtKey, snapshot, treeHash}`. The host replies with the tips it holds for that workspace.
2. The controller runs `git bundle create - <snapshot> --not <tips the controller also has>` and streams it on a channel. On a first sync it sends the full history. On the same `HEAD`, it sends only the working-copy delta since the last snapshot. After a rebase, git finds the merge-base itself.
3. The host fetches the bundle into `store.git` and updates `refs/fd/heads/<wt-key>`.

### 4.4 Apply (host)
1. The host picks a checkout slot (§4.6).
2. It runs `git checkout --force --detach <snapshot>` and then `git clean -fd`, never with `-x`. Non-ignored files now match the snapshot exactly. Ignored files (DerivedData, `node_modules`, `.build`) are kept, so builds stay incremental.
3. It verifies `git rev-parse HEAD^{tree} == treeHash`. On a mismatch, the run fails before anything executes.
4. Unchanged files keep their mtimes, and the checkout path is stable per slot.
5. Git carries content, the executable bit and symlinks. Other permissions, xattrs and empty directories are not carried. The spec documents this rather than working around it.

### 4.5 Results (host → controller)
- **Changed files.** After the run, the host stages non-ignored changes in a temporary index and commits them as a child of the snapshot (`refs/fd/results/<run-id>`).
  - When something changed, the controller fetches a bundle of that one commit.
  - The controller stores it as a pending result for the run.
  - `flightdeck diff <run>` shows the result. `flightdeck apply <run>` applies it with a three-way merge (the snapshot as base) against the **current** working tree, so edits you made during the run produce conflict markers, never overwrites.
  - A recipe with `apply = "auto"` applies on completion, unless a conflict comes up; then it falls back to review and says so.
- **Artifacts.** `--fetch` globs and recipe `fetch` lists are matched in the checkout after the run. They are streamed back as tar, to the same relative paths in the local worktree.
  - A glob that matches a **tracked** path is refused at preflight, because the patch is how tracked files come back.
  - An artifact replaces an existing local file only if that file is ignored.

### 4.6 Checkout pool
- Each worktree gets up to `pool = 2` checkout slots (configurable).
- A run locks a slot. Runs with the same snapshot share a slot. A run with a different snapshot takes a free slot, or queues when all are locked.
- A service (§6.1) pins its slot for as long as it lives.

### 4.7 Growth
- hostd keeps K snapshots per worktree and expires result refs. Then it runs `git gc --auto`.
- `flightdeck host ls --disk` reports workspace sizes.
- `flightdeck host prune <host> [--repo …]` deletes the checkouts, and with them their build output.

## 5. CLI surface

All subcommands go through the session's control socket.

| Command | Purpose |
|---|---|
| `flightdeck host ls [--disk]` | Paired hosts: status, platform, tools, workspace sizes |
| `flightdeck host info <host>` | Platform, Xcode versions and simulators, Docker, disk free, screen state |
| `flightdeck run [--on H] [--include P]… [--fetch G]… [--env K=V]… [--pty] [--screen] [--detach] -- cmd…` | Sync, run, stream output; exit with the remote code |
| `flightdeck run <recipe> [overrides] [-- extra args]` | Run a named recipe |
| `flightdeck exec --on H -- cmd…` | Run in the existing checkout **without syncing** (inspection) |
| `flightdeck up <recipe>` / `up --on H --port L:R … -- cmd…` | Start a background service |
| `flightdeck down|restart|sync <service>` | Stop, restart, or re-apply the current snapshot to its pinned checkout |
| `flightdeck ps` | This session's runs and services, with port mappings |
| `flightdeck wait|logs|stop <run>` | Attach to, replay or cancel a run |
| `flightdeck diff|apply <run>` | Review or apply a run's changed-file patch |
| `flightdeck recipe ls|add|check` | List, add, or validate recipes in `delegate.toml` |

**Host resolution order:** `--on`, then the recipe's `host`, then the matched routing rule, then the project's `default_host`. When none of these gives a host, the command fails with a list of the paired hosts.

**Exit codes:**
- A completed run exits with the remote command's code.
- A run killed by signal `n` exits `128+n`.
- If delegation itself fails, the exit code is **125**, with a single stderr line that starts `flightdeck:`, names the host, and says what to do next. Examples:
  - `mini is offline (last seen 4m ago)`
  - `mini's screen is locked`
  - `sync rejected: tree hash mismatch`
  - `.env is ignored locally and wasn't sent — rerun with --include .env or add it to delegate.toml`

  The last one comes from a missing-file heuristic: the run fails, and its output names a path that exists locally but is ignored and wasn't sent.

## 6. Execution

### 6.1 Runs
- **Working directory:** the checkout path plus the same relative subdirectory as the CLI's own working directory.
- **Shell:** the host user's login shell, `$SHELL -lc '<cmd>'`.
- **Environment:** the host's login environment, plus `--env` and recipe `env`.
- **I/O:** each run gets its own process group. stdout and stderr go over two pipe channels. `--pty` gives the run one pty channel, sized from the CLI's terminal when there is one.
- **Cancel:** the CLI forwards SIGINT. If the run is still alive after 10 s, it gets SIGTERM to the group, and after another 10 s SIGKILL.
- **Disconnects:** if the controller drops, the run continues. Output spools to `runs/<run-id>/` (capped at 64 MiB per run, with the oldest output dropped first and a marker line written). A live CLI reconnects and resumes from its last offset. `flightdeck logs <run>` replays and follows.
- **Long runs:** a recipe with `long = true` (or `--detach`) prints the run id and `flightdeck wait <run>`, then exits 0 straight away. This keeps it under agent tool timeouts. `wait` blocks for up to `--timeout` (default 9 min) and exits with the run's code, or 124 on a timeout while the run continues.
- **Power:** every run holds an idle-sleep assertion on a macOS host. On Linux it uses a `systemd-inhibit` sleep lock when one is available.

### 6.2 Services
- A service is a long-lived run **owned by its session** and pinned to a checkout slot.
- `ports = [5432, "8080:80", "auto:3000"]` uses local:remote notation, where `N` means `N:N` and `auto` means a free local port.
- A CLI `--port L:R` replaces the recipe's entry for the same remote port R.
- **Forwarding:** `PortForwarder` holds a `127.0.0.1:L` listener for each port. Each accepted connection becomes a channel, and hostd dials `127.0.0.1:R` on the host.
- **Lifecycle:**
  - The session's tab closing runs `down`.
  - `down` sends SIGTERM to the group, then runs the recipe's `down` command (for example `docker compose down`) when one is set.
  - If no controller has been connected for `orphan_timeout` (default 30 min), hostd runs `down` itself.
  - A service that dies unexpectedly emits an event. The session's status shows it, and `flightdeck ps` reports it with its exit code.
- `flightdeck sync <service>` re-applies the current snapshot to the pinned checkout in place. A recipe may also set `restart_on_sync = true`.

### 6.3 Screen runs
- With `screen = true` or `--screen`, the run must acquire the host's **single screen lease** before it starts. While it waits, the CLI prints `waiting for mini's screen — held by <run> (session "<title>")`.
- **macOS preflight:** a console user must be logged in and the screen unlocked (`CGSessionCopyCurrentDictionary`). A failure exits 125 right away.
- **While the lease is held:** hostd holds a display-awake assertion and shows a small floating "UI tests running — don't touch" panel. This is why hostd lives in the GUI session.
- **On Linux,** `screen` is refused in v1.

## 7. Preflight (fail early)

Every `run` and `up` performs these steps **in order, before any sync or remote work**. A failure releases anything reserved so far and exits 125, with nothing changed on either machine.
1. Resolve the host and the recipe. Validate `delegate.toml` (`DelegateConfig`).
2. Check that the host is connected and that the protocol supports what's needed (screen, services, pty).
3. Check that every `include` path exists locally, and that no `fetch` glob matches a tracked path.
4. **Local ports:** bind and hold every requested local port. A conflict error names the holder: the Flight Deck session that owns it, or the process from `lsof`. It also suggests a free alternative, for example `localhost:5432 is held by postgres (pid 812); try --port 15433:5432 or --port auto:5432`.
5. **Remote ports:** hostd checks that each remote port is free. A conflict error names the holder on the host, including the Docker container when Docker holds the port.
6. **Screen:** the console-session and lock checks (§6.3). The lease itself is queued, not failed.
7. **LFS:** the check from §4.2, step 5.

Sync (§4) and execution (§6) begin only after every step passes.

## 8. Configuration: `.flightdeck/delegate.toml`

Checked in, per project. `flightdeck recipe add` writes it, and `flightdeck recipe check` validates it.

```toml
default_host = "mini"
include = [".env"]                  # declared ignored files, every run

[recipe.ui-tests]
host = "mini"
run = "xcodebuild test -scheme FlightDeck -only-testing:UITests"
screen = true
long = true
fetch = ["build/**/*.xcresult"]
apply = "review"                    # or "auto"

[recipe.stack]
host = "linuxbox"
run = "docker compose up"
down = "docker compose down"
ports = [5432, "8080:80"]
service = true

[[route]]                           # transparent routing
match = "xcodebuild test *"         # glob over the joined argv
recipe = "ui-tests"
```

**Routing shims:**
- At session launch, Flight Deck puts a per-session shim directory at the front of `PATH`, holding one shim for each command name that a `route` names.
- A shim matches its argv against the routes. On a match, it runs `flightdeck run <recipe> -- <argv>`. Otherwise it `exec`s the real binary, found by searching `PATH` without the shim directory.
- `FLIGHTDECK_NO_ROUTE=1` bypasses all routes.
- The shim directory is rebuilt when `delegate.toml` changes.

## 9. Agent integration

- **Claude:** a `delegate` skill (`Resources/ClaudePlugin/skills/delegate/SKILL.md`) is added to the plugin that Flight Deck already passes with `--plugin-dir`, so every session has it.
  - The skill is **static**. It never lists hosts or recipes; it tells the agent to run `flightdeck host ls`, `flightdeck recipe ls` and `flightdeck run --help`. Pairing a host or adding a recipe therefore never makes it stale.
  - It covers running commands, inspecting with `host info` and `exec`, adding recipes, reading the 125 hints, using `wait` for long runs, and reviewing patches with `diff`/`apply`.
- **Sessions already running:** if `--plugin-dir` skills do not hot-reload (probe P1), Flight Deck injects `/reload-plugins` through the existing gated `inject` path the next time the composer is idle, after an app update.
- **Codex:** it gets the same skill through its skills mechanism if probe P2 confirms that current codex supports SKILL.md skills. Otherwise it uses `developer_instructions` in the launch config. Per the adapter rule, shipping this for Claude only would be a defect.

## 10. Testing

**Unit (headless):**
- `HostKit`'s `swift test` runs on macOS and in a Linux container. It covers:
  - `ChannelMux`: flow control, credit starvation, close ordering;
  - the `HostWire` round-trip;
  - `Runner`: exit and `128+n` mapping, group kill, signal escalation;
  - `ScreenLease` queueing;
  - `DelegateConfig` parsing and route matching.
- **Sync, against real temporary git repos:**
  - the snapshot leaves the index, stash and reflog unchanged;
  - an `include` path gets force-added;
  - the bundle is delta-only on a shared base;
  - the bundle is correct after a rebase;
  - a tree mismatch rejects the run;
  - ignored build output survives an apply;
  - the result patch three-way merges cleanly, and gives conflict markers when you edited during the run;
  - an LFS repo is refused;
  - submodules round-trip.
- **Preflight:**
  - a held local port fails before any sync;
  - `auto` picks a free port;
  - `--port` replaces the recipe's entry;
  - listeners are released after any later failure;
  - a tracked-path `fetch` glob is refused.

**Integration (real processes, no GUI):**
- **Loopback harness:** hostd runs in a temp root, and a `HostLink` connects over real TLS-PSK. It drives `run`, `exec`, `up`/`down`, forwarding, reconnection and `logs` replay, with stub `xcodebuild`/`docker` scripts on `PATH`.
- **Linux interop:** hostd runs in a Docker container. The Mac client pairs with it and runs a command. This is the §3.2 gate, and it comes first.
- **Disconnect:** kill the client mid-run. The run must continue, `logs` must reattach with complete output, and the service must stop after a shortened `orphan_timeout`.

**Live probes (recorded as unverified until run):**
- **P1:** do skills under `--plugin-dir` hot-reload in Claude Code 2.1.288, or does a running session need `/reload-plugins`?
- **P2:** does the current codex-cli load SKILL.md skills, and from which directory?
- **P3:** does an XCTest UI suite run from a hostd login item, and fail from a plain SSH child? This confirms the reason for §2.1's placement.
- **P4:** does `CGSessionCopyCurrentDictionary` report the locked state reliably from a login item?

**Manual (the maintainer's, per AGENTS.md rule 2):** GUI pairing of a second Mac, a real UI test on the mini (the "don't touch" panel and queueing), and a Linux pairing from the pasted command.

## 11. Follow-on sub-projects (outline only)

**B — Remote sessions.** Agent sessions in fd-abduco on a host, with the terminal over a mux channel to `fd-abduco -a`.
- The host owns the session list. Multiple viewers are all live, and the last resize wins.
- **Moves to hostd:**
  - the status registry and its pid filter, transcript, rollout and session-index tailing, and the hook-event feed (with a host copy of the Claude plugin);
  - `codex app-server`;
  - daemon control, sleep and reconcile;
  - ⌘K corpus enumeration (the SQLite index stays on the controller);
  - the intake runner.
- **Already works unchanged over a mirrored terminal:** prompt answering, `inject`, Claude `/rename`, the dialog drivers and the screen parsers.
- **Other work:** the wire types gain a host identity, so identical paths on two hosts stay distinct, and new remote sessions pick their project in a remote folder browser.

**D — Peer-agent delegation.** A session hands a task to an agent session on a host (B), through a message channel that hostd relays. The peer's edits come back through C's result-patch path.

## 12. Risks

- **Linux TLS-PSK interop** (§3.2 gate). If it fails, the Linux transport must be re-decided.
- **Swift on Linux.** HostKit must stay off Darwin-only frameworks. CI must build it in a Linux container, or it will break without anyone noticing.
- **Login-item hostd stops when the user logs out.** That is accepted, because screen runs need a login anyway. Settings → Hosting states it.
- **Secrets on hosts.** Included files persist in the host's object store until unpairing. Settings → Hosts says so next to `include`.
