---
name: delegate
description: Run a command on another machine paired with Flight Deck (a Mac mini, a Linux box) with `flightdeck run` — UI tests that need a screen, heavy builds, Docker stacks, anything this Mac cannot or should not run. Use when the user names a host or says "run it on …", when a recipe or route already covers the command, or when a local run would steal the user's screen.
---

# Delegating work to a paired host

`flightdeck run` syncs your uncommitted working tree to a host, runs the command there, streams the output, and exits with the remote exit code. If `flightdeck` is not on `PATH`, you are not inside Flight Deck: run things locally.

## Look before you run

Never guess host or recipe names. They change; ask every time.

- `flightdeck host ls` lists the paired hosts and whether each is online.
- `flightdeck host info <host>` shows the platform, Xcode and simulators, Docker, free disk and screen state.
- `flightdeck recipe ls` lists this project's recipes and routes.
- `flightdeck run --help` lists every flag.

## Run

- `flightdeck run <recipe>` runs a named recipe. Extra arguments go after `--`.
- `flightdeck run --on <host> -- <cmd…>` runs an ad-hoc command.
- `--include <path>` sends a git-ignored file (for example `.env`); ignored files are never sent otherwise. The project's `include` list in `.flightdeck/delegate.toml` is sent on every run.
- `--fetch <glob>` brings build outputs back (for example `build/**/*.xcresult`).
- `--env K=V` sets a variable on the host. Your local environment is never sent.
- `--screen` is for UI tests. It waits for the host's screen if another run holds it.
- `--pty` is for a command that needs a terminal.

Files the command changes on the host come back as a patch. Read it with `flightdeck diff <run>`, then `flightdeck apply <run>`. Apply merges against your current tree and leaves conflict markers rather than overwriting. A recipe with `apply = "auto"` applies its patch by itself; check `git status` afterwards.

## Long runs

A recipe marked `long`, or `--detach`, prints a run id and returns at once. Then:

- `flightdeck wait <run>` blocks until the run ends, then exits with the run's own exit code. It gives up after 9 minutes (`--timeout` to change) with exit 124, which means the run is still going: call `wait` again.
- `flightdeck logs <run>` replays the output.
- `flightdeck stop <run>` cancels it.
- `flightdeck ps` lists this session's runs and services.

## Inspect without syncing

`flightdeck exec --on <host> -- <cmd…>` runs in the host's existing checkout without sending anything. Use it to look around: `ls`, `git status`, `xcrun simctl list`.

## Services

- `flightdeck up <recipe>`, or `flightdeck up --on <host> --port <L:R> -- <cmd…>`, starts a background service. Its ports are forwarded to `127.0.0.1` here.
  - Port forms are `5432` (same on both ends), `15432:5432` (local:remote) and `auto:5432` (any free local port).
- `flightdeck down <service>` stops it, and `flightdeck restart <service>` restarts it.
- `flightdeck sync <service>` pushes your current tree into the running service's checkout.
- Services stop when this tab closes.

## Cloud machines

A host can also be a machine Flight Deck creates in the user's own AWS or GCP account, from an `[infra.<name>]` table in `.flightdeck/delegate.toml`. It costs real money by the hour.

- Every command aimed at a cloud host prints a cost line on stderr, like `<name> · <type> · $0.80/h est. · up 1h12m · ~$0.96 · TTL 2h48m · month ~$14.20 of $50`. Tell the user what it says before running long or repeated work there.
- `flightdeck infra ls` lists the cloud machines with their state, rate, spend and time left. `flightdeck infra doctor` checks the tools and accounts.
- A table with `auto_up = true` is created by the first `flightdeck run --on <name>`, which then waits for it (minutes). Without `auto_up`, the run is refused until someone runs `flightdeck infra up <name>`.
- Never run `flightdeck infra up`, `infra down` or `infra extend` unless the user asked: they create, destroy or keep paying for a machine. A refusal from the budget or a guardrail names the setting to change; it is the user's to change, never yours.
- A machine is destroyed by itself at its `ttl`, and after `idle` with nothing running, so a long gap between runs can mean the next one creates it again.

## Exit codes

- **125 with a stderr line starting `flightdeck:`** means delegation itself failed. Do exactly what that line says (another `--port`, `--include <path>`, wait for the host to come online); do not retry blindly. A failure in the checks before syncing changed nothing on either machine. A 125 without that line is the remote command's own exit code.
- **124** comes from `wait` and means the run is still going.
- **128+n** means the run was killed by signal n.
- Any other code is the remote command's own.

## Save what works

When an ad-hoc command works and will be needed again, save it with `flightdeck recipe add` (see `flightdeck recipe add --help`). It writes `.flightdeck/delegate.toml`; commit that file. Run `flightdeck recipe check` after editing the file by hand.
