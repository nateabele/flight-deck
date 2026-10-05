# Delegation live probes (P1–P4)

Spec §10 lists four live probes for delegated execution (sub-project C). Each one settles a
question about an upstream tool that reading code cannot answer. P1 and P2 were run on
2026-10-05. P3 and P4 need a second Mac and are written here as procedures for the maintainer.

These are **version-pinned claims**. Re-run a probe after upgrading the tool it names, before
trusting anything built on it.

| Probe | Question | Verdict | Versions | Cost |
|---|---|---|---|---|
| P1 | Does a skill added to a `--plugin-dir` plugin after the session starts appear without a restart? | **No.** `/reload-plugins` makes it appear immediately. | Claude Code 2.1.289 | 0 model turns |
| P2 | Does codex-cli load SKILL.md skills, and from where? | **Yes**, from four roots. None of them is reachable from the launch line. | codex-cli 0.160.0 (`~/.local/bin`), 0.153.4 (`/opt/homebrew/bin`) | 0 tokens |
| P3 | Does an XCTest UI suite run from a hostd LaunchAgent, and fail from a plain SSH child? | Not run (second Mac) | — | — |
| P4 | Does `CGSessionCopyCurrentDictionary` report the lock state reliably from a LaunchAgent? | Not run (second Mac) | — | — |

## P1: `--plugin-dir` skills do not hot-reload

**Setup.** A throwaway plugin (`.claude-plugin/plugin.json` = `{"name":"p1probe"}`) holds one
skill, `skills/alphaprobe/SKILL.md`, as the control. A real interactive `claude --plugin-dir <plugin>`
runs in a pty (Python `pty.fork` + `pyte`, 160×50). It runs from a trusted directory, with the
parent session's markers cleared:

```sh
env -u CLAUDE_CODE_CHILD_SESSION -u CLAUDECODE -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_ENTRYPOINT \
    -u CLAUDE_CODE_MESSAGING_SOCKET -u CLAUDE_CODE_MESSAGING_TOKEN -u CLAUDE_CODE_EXECPATH \
    -u CLAUDE_PID -u CLAUDE_EFFORT claude --plugin-dir "$PLUGIN"
```

The driver waits for the composer box before sending any key, because a trust dialog defaults
to "No, exit". Skills are read off the TUI's own slash-command autocomplete: type `/p1probe:`,
read the screen, then `^U` to clear. That listing is local, so **no model turn is spent**.

| Step | `/p1probe:` autocomplete shows |
|---|---|
| T0, at launch | `alphaprobe` |
| `skills/betaprobe/SKILL.md` written, then 8 s pass | `alphaprobe` only |
| `/reload-plugins` ⏎ (prints `Reloaded: 5 plugins · 29 skills · …`) | `betaprobe` and `alphaprobe` |

**Why not `claude -p`.** A `-p` run is one turn. There is no "after the session started"
moment in which to add the skill, so `-p` cannot answer this question.

**Consequence.** Under fd-abduco, a tab's claude survives an app swap, and its `--plugin-dir`
still names the bundle path whose contents just changed. `PluginReload`
(`Sources/FlightDeck/Agents/PluginReload.swift`) fingerprints the bundled plugin, and finds
the adopted tabs that need `/reload-plugins` when that fingerprint differs from the previous
run's. `SessionStore` sends the command through the gated `inject`, while the tab is idle.

**Real skill check.** `claude --plugin-dir Resources/ClaudePlugin` (same driver) offers
`/flight-deck:delegate` with the skill's description in autocomplete.

## P2: codex loads SKILL.md skills, from four roots

**Cheapest check: the app-server, with no turn.** `codex app-server generate-json-schema
--experimental -o <dir>` lists `skills/list`, `skills/extraRoots/set` and `skills/config/write`
on both installs. Next, a throwaway `HOME`/`CODEX_HOME` gets one probe skill per candidate
root. Then `initialize` → `skills/list {cwds:[repo], forceReload:true}` over app-server stdio,
with `cwd` = a scratch repo:

| Root | 0.160.0 | 0.153.4 | Scope |
|---|---|---|---|
| `<repo>/.agents/skills/<name>/SKILL.md` | loaded | loaded | repo |
| `<repo>/.codex/skills/<name>/SKILL.md` | loaded | loaded | repo |
| `$CODEX_HOME/skills/<name>/SKILL.md` | loaded | loaded | user |
| `~/.agents/skills/<name>/SKILL.md` | loaded | loaded | user |
| a directory passed to `skills/extraRoots/set` | loaded after the call | loaded after the call | user |
| `-c 'skills.config=[{path="<abs>/SKILL.md",enabled=true}]'` outside every root | **not** loaded | — | — |

Plus codex's own `.system` skills under `$CODEX_HOME/skills/.system/`.

**Does the skill reach the model? A fake upstream, also zero tokens.** The sandboxed
`config.toml` points codex at a local HTTP server that records each POST body and answers 500:

```toml
model_provider = "fake"
[model_providers.fake]
base_url = "http://127.0.0.1:<port>/v1"
wire_api = "responses"
env_key = "FAKE_KEY"
request_max_retries = 0
stream_max_retries = 0
```

Then `codex exec --skip-git-repo-check "say hi"` runs with stdin closed. If stdin is left
open, `exec` waits on it until the timeout. On both installs, the request's
`<skills_instructions>` lists `- delegate: <description> (file: …/flightdeck-delegate/SKILL.md)`.
The body is **not** inlined; the model opens it on demand.

**Why not `developer_instructions`.** The fake upstream measured how it merges. With
`developer_instructions = "USER-MARK…"` in `config.toml` and `-c developer_instructions="FD-MARK…"`
on the command line, the request carried only FD-MARK. **The `-c` value replaces the user's
value; it is not appended.** Delivering the skill that way would silently delete a user's own
instructions from every codex tab. Escaped newlines, quotes and backticks did survive the
`-c` TOML round trip intact.

**Why not `extraRoots`.** It is an app-server RPC. A codex tab is its own `codex resume` TUI
process, which Flight Deck's app-server never reaches.

**Wiring chosen.** `CodexDelegateSkill` (`Sources/FlightDeck/Agents/Codex/CodexDelegateSkill.swift`)
copies the bundled `ClaudePlugin/skills/delegate/SKILL.md` to
`<CODEX_HOME>/skills/flightdeck-delegate/SKILL.md`, rewriting it only when the bytes differ.
`CodexProcessTransport.start()` calls it for the account's home just before spawning the
app-server. So nothing is written for a user who never opens a codex tab. Both agents read one
file. The `flightdeck-` prefix keeps it clear of a user skill named `delegate`.

**Not probed:** whether a codex TUI that is **already running** notices a newly installed skill.
`skills/list` has a `forceReload` flag, which implies a cache. New tabs certainly see it.

**Cost of P2:** zero model tokens. The work was about 10 app-server spawns and 6 `codex exec`
runs against the local fake server, each a few seconds.

## P3: XCTest UI suite from a LaunchAgent vs. SSH (procedure, needs the second Mac)

**Question.** Does `xcodebuild test` of a UI-test target succeed when hostd launches it, and
fail when a plain SSH session launches it? This is the reason spec §2.1 puts hostd in the GUI
login session.

**Host prerequisites.**
- The maintainer is logged in at the console and the screen is unlocked.
- Xcode is installed and `xcodebuild -runFirstLaunch` has been run.
- Remote Login is on, for the SSH half.

**Steps.**

1. Make a minimal UI-test project on the host, or use a Flight Deck checkout:
   `-scheme FlightDeck -only-testing:UITests`. The trivial `XCUIApplication().launch()` case
   is enough.
2. **LaunchAgent half, before C8 lands.** Emulate hostd with a throwaway agent:
   - Write `~/Library/LaunchAgents/dev.flightdeck.p3.plist`. Set `ProgramArguments` =
     `/bin/zsh -lc "cd <proj> && xcodebuild test -scheme <S> -destination 'platform=macOS' -derivedDataPath /tmp/p3dd > /tmp/p3-agent.log 2>&1; echo EXIT $? >> /tmp/p3-agent.log"`.
   - Run `launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/dev.flightdeck.p3.plist`, then
     `launchctl kickstart gui/$(id -u)/dev.flightdeck.p3`.
   - Wait for `EXIT` in `/tmp/p3-agent.log`.
   - Clean up with `launchctl bootout gui/$(id -u)/dev.flightdeck.p3` and remove the plist.
3. **LaunchAgent half, after C8.** From this Mac:
   `flightdeck run --on <host> --screen -- xcodebuild test -scheme <S> -destination 'platform=macOS'`.
4. **SSH half.** From this Mac:
   `ssh <host> "cd <proj> && xcodebuild test -scheme <S> -destination 'platform=macOS' -derivedDataPath /tmp/p3dd-ssh"; echo $?`.
5. Record, for each half, the exit code and the first error line. Typical SSH failures name
   `testmanagerd`, "Timed out while enabling automation mode", or a missing authorization.
6. If the LaunchAgent half also fails on automation authorization, check whether a one-time
   `sudo automationmodetool enable-automationmode-without-authentication` fixes it. Record
   that it is required: it is a pairing-time setup step, not a per-run one.

**Pass:** the LaunchAgent run exits 0 and the SSH run fails. Anything else reopens §2.1.

## P4: lock state from a LaunchAgent (procedure, needs the second Mac)

**Question.** Does `CGSessionCopyCurrentDictionary()`, called from a LaunchAgent in the
console user's GUI session, reliably report a locked screen? Preflight (§7 step 6) fails with
exit 125 on this answer.

1. On the host, save as `/tmp/p4.swift`:
   ```swift
   import CoreGraphics
   import Foundation
   let d = CGSessionCopyCurrentDictionary() as? [String: Any] ?? [:]
   let keys = ["CGSSessionScreenIsLocked", "kCGSSessionOnConsoleKey", "kCGSSessionUserNameKey", "kCGSessionLoginDoneKey"]
   print(Date(), keys.map { "\($0)=\(d[$0].map { "\($0)" } ?? "absent")" }.joined(separator: " "))
   ```
   Compile it with `swiftc /tmp/p4.swift -o /tmp/p4`.
2. Run `/tmp/p4` every 5 s from a throwaway LaunchAgent, set up as in P3 with
   `StartInterval` = 5. Log to `/tmp/p4-agent.log`.
3. Walk through these states for about 30 s each, noting the wall-clock time of each:
   1. unlocked;
   2. locked (⌃⌘Q);
   3. screen saver running but not yet locked;
   4. display asleep (`pmset displaysleepnow`), before and after the lock delay;
   5. fast-user-switched to the login window;
   6. unlocked again.
4. For comparison, run `ssh <host> /tmp/p4` in states 1 and 2. An SSH child is outside the GUI
   session and may see no dictionary at all.
5. **Pass:**
   - `CGSSessionScreenIsLocked=1` in states 2, 4-after-delay and 5;
   - the key is absent or 0 in state 1, and in 6 within one interval;
   - `kCGSSessionOnConsoleKey` is true whenever the user owns the console.

   Record state 3 whichever way it goes: it decides whether "screen saver up" must count as
   locked.
6. Tear down the agent and delete `/tmp/p4*`.
