# Passing argv and helper scripts to `flightdeck run` without shell quoting (2026-10-27)

Asked by The Plan (Tessera) for testq (`Tessera/.testq/testq`). testq sends each remote job as one
command string: every argument shell-quoted, its helpers (deps guard, disk floor, Elm preflight,
Node helper) inlined, all of it wrapped in a base64 frame so m3's fish cannot mangle it. The frame
is about 67 KB per job. This note records how the command, the extra arguments and `--env` reach
the remote process today, what limits apply, how testq can stop quoting with today's features,
and what a Flight Deck feature would look like. No code was changed for it.

## 1. What happens today

All of it is in two places: `DelegationService.command(argv:recipe:routed:)` and `shellQuote`
([DelegationService.swift](../../../Sources/FlightDeck/Delegation/DelegationService.swift), near
line 1134), and `Spawner.spawn`
([Runner.swift](../../../Packages/HostKit/Sources/HostKit/Delegation/Runner.swift), near line 1139).

1. The CLI keeps the words after `--` as an array. `WireDelegateRun.command: [String]` goes to the
   app unchanged.
2. The app turns that array into **one string of shell text**, `RunSpec.command`:
   - **One word after `--`:** used as-is, as shell text. `-- 'make && make test'` works as it would
     over ssh. This is testq's form (`-- "$cmd"`), so the host's shell parses all 67 KB.
   - **Two or more words:** each word is quoted with POSIX single quotes (`'…'`, with `'` written
     as `'\''`). Words made only of `A-Za-z0-9@%_+=:,./-` stay bare. Then they are joined with
     spaces.
   - **A recipe:** `recipe.run` is used as shell text, and the EXTRA_ARGS are appended to it,
     quoted the same way. **EXTRA_ARGS are not real argv.** They are joined into the string.
   - **A route** (`[[route]]` matched the argv): the argv is the command, by the rules above. The
     recipe only supplies settings.
3. hostd runs `posix_spawn(shell, [shell, "-lc", command], env)`. `shell` is the host user's
   login shell: `$SHELL`, else the passwd entry, else `/bin/sh` (`Runner.loginShell()`). On m3
   that is fish.
4. **`--env K=V` and recipe `env` do not pass through any shell.** They are merged over hostd's
   own environment (the CLI's wins over the recipe's) and given to `posix_spawn` as `envp`. The
   value reaches the process byte for byte. One exception: the login shell's profile runs first
   (`-l`). A `config.fish` or `.bash_profile` that sets the same variable replaces the value.

### A bug this found: the quoting is POSIX, and fish is not

Inside single quotes, fish treats `\\` and `\'` as escapes. POSIX shells do not. The app quotes
without knowing which shell the host runs, so on a fish host a word that contains a backslash
can change or break. Measured with fish 4.8.0, quoting by the same rule as `shellQuote`:

| Word sent | `sh -c` receives | `fish -c` receives |
| --- | --- | --- |
| `a\\b` | `a\\b` | `a\b` (one backslash lost) |
| `a\'b` | `a\'b` | parse error: "quotes are not balanced" |
| `it's`, `$HOME`, `(echo hi)`, `x\y` | unchanged | unchanged |

This affects every multi-word `flightdeck run -- …` and every recipe's EXTRA_ARGS on a fish host.
It is listed in [FOLLOWUPS.md](../../FOLLOWUPS.md) under delegated execution. §4 removes it.

## 2. Size limits

| Limit | Where it applies | Size |
| --- | --- | --- |
| **One argv or env string** on a **Linux** host (`MAX_ARG_STRLEN`) | The whole `-lc` command is one string. So is each `K=V` from `--env`. | **131,072 bytes.** Over that, the spawn fails with E2BIG. A 67 KB frame is already half of it. |
| All argv plus all env (`ARG_MAX`) | Linux host | 1/4 of the stack rlimit, usually 2 MiB |
| All argv plus all env (`ARG_MAX`) | macOS host (m3), and the local `flightdeck` process itself | 1,048,576 bytes (`getconf ARG_MAX`), with no per-string limit |
| One CLI-to-app socket message | Local socket (`TimelineLimits.maximumMessageSize`) | 4 MiB of JSON |
| One host-link message | Linux hostd WebSocket (`PSKWebSocketServer.maxMessageBytes`) | 16 MiB |
| Files sent in the synced tree (`--include`, tracked files) | git bundle on the sync channel | No argv or env limit. Only objects the host does not already have are sent. |

So the tight limit is the exec, not the wire. `--env` does not avoid it. A large env value also
has a cost that a large argv does not: **every process the job starts inherits it**, and it uses
part of each child's `ARG_MAX`. A 60 KB `TESTQ_ARGV` follows every `make`, `node` and `elm`
the job runs.

## 3. The options, measured against today's Flight Deck

**1. Job file plus a fixed runner. Recommended, together with 2.** It works today and needs no
Flight Deck change.

- Write a git-ignored directory in the worktree, for example `.testq-remote/`. Put the runner,
  the helpers, and one job file per job in it.
- Send it with `--include .testq-remote`. `Snapshotter` runs `git add -f` on each include, so a
  directory works. A path that does not exist locally is refused in preflight.
- Run a fixed command, for example
  `flightdeck run --on m3 --include .testq-remote -- bash .testq-remote/run.sh .testq-remote/jobs/<id>`.
  Every word in it is from the bare-safe set, so the quoting in §1 changes nothing, on fish too.
- No value crosses a shell.
- Write the job's argv to the file **NUL-separated**, not as JSON, so the runner needs no parser.
  m3's `/bin/bash` is 3.2, which has no `mapfile -d`. This loop works in 3.2:
  `args=(); while IFS= read -r -d '' a; do args+=("$a"); done < "$1"; exec "${args[@]}"`.
  Put env and settings in a second file, or in `--env` while they are small.
- Give each job file a unique name. Concurrent jobs share the worktree, and each snapshot takes
  the files as they are at that moment. Delete the file after the run returns.
- The job file is new in the tree, so it is not in the run's results. `flightdeck diff` and
  `apply` do not show it.

**2. Helpers keyed by content hash. You get this for free with 1.** Sync is git, and the
controller sends "a bundle of only what is missing" ([ARCHITECTURE.md](../../ARCHITECTURE.md),
"Sync is git"). The blob of a helper the host already has is not sent again. A helper is sent
once, and again only when it changes. The job file is the only new blob per job, and it is a few
hundred bytes. No `~/.testq/<sha>/` directory to install, check or clean up is necessary. The
checkout is the host's copy.

**3. Base64 for each argument.** This works. The base64 alphabet (`A-Za-z0-9+/=`) is all in the
bare-safe set, so the words reach fish unchanged. The helpers stay inlined, and every job still
needs decoding code inlined in the command, which a shell must parse. This is better than
escaping, but option 1 makes it unnecessary.

**4. argv in `--env TESTQ_ARGV=<base64>` with a fixed command.** Confirmed: `--env` does not pass
through the remote shell (§1, step 4). It has the problems in §2: the 128 KiB string limit on
Linux, a 1 MiB limit on the local `flightdeck` command line, and the value goes to every child.
Use it for small settings, not for argv or helpers.

**5. A `delegate.toml` recipe (`flightdeck run testq-job -- args`).** Confirmed: EXTRA_ARGS **are
joined into the string** and parsed by the login shell. They are not real argv, and the fish bug
above applies to them. A recipe can hold only the fixed part of option 1
(`run = "bash .testq-remote/run.sh"`, `include = [".testq-remote"]`, `env`, `pool`, `fetch`),
with the job file's path as the one EXTRA_ARG. That is safe, because the path is bare-safe. The
cost is that the recipe lives in the repo. This is useful only if testq should stop passing its
flags each time.

**6. A Flight Deck feature.** Feasible and small. See §4.

**Recommendation for testq now:** option 1 with the snapshot doing the work of option 2. Use an
optional recipe (option 5) to hold the fixed flags. This removes the 67 KB frame, the quoting,
the fish breakage, and the E2BIG risk. The command that crosses a shell is under 100 bytes of
bare-safe words.

## 4. Option 6: how Flight Deck could remove the problem for every client

### 4a. Real argv to the remote process, through the login shell

Keep the login shell, so the profile's PATH (xcodebuild, docker, nvm) still applies. Give the
shell a **fixed** script, and give the words to it as positional arguments. The shell never
parses them:

| Login shell | argv hostd spawns |
| --- | --- |
| sh, bash, zsh, other POSIX | `[shell, "-lc", "exec \"$@\"", "flightdeck-run", word1, word2, …]` |
| fish | `[shell, "-lc", "exec $argv", word1, word2, …]` |

Measured 2026-10-27 on this Mac, with fish 4.8.0, bash and zsh: the words `a\'b`, `x y` and
`$(no)` each arrived as one unchanged argument.

Shape:

- `RunSpec` gets `argv: [String]?`. When it is set, `command` is only for display (`ps`, the
  run row). `Spawner.spawn` builds the table above from the shell's basename.
- **The multi-word form uses it by default.** `-- a b c` is already quoted word by word, so the
  shell only splits the words. Spawning the argv directly does the same thing, and it fixes the
  fish bug. One difference: a name that is only a shell function or alias on the host is no
  longer found. The one-word form stays shell text, as it works over ssh.
- `--argv` makes even one word an argv, for example a program path that contains spaces.
- **Recipes:** the EXTRA_ARGS become positional arguments of `run`:
  `[shell, "-lc", run + " \"$@\"", "flightdeck-run", extra…]`, or `run + " $argv"` on fish.
  `run` is still shell text. Recipes are already written for the host's shell.
- **Old hosts:** advertise `run.argv` in the hello capabilities. Preflight already refuses an
  op the host cannot do ("`<host>`'s hostd does not support … — update Flight Deck on `<host>`").
  When a multi-word command goes to an old hostd, the app falls back to today's quoting.
- The limits become `ARG_MAX` and, on Linux, 128 KiB **per word**, not per command. Each word
  is counted separately.

### 4b. Sending helper files without writing them into the user's tree

Today a helper must be inside the worktree for `--include` to send it. `--file LOCAL=PATH`
would add a file from anywhere on the controller to the snapshot at `PATH`.

- `Snapshotter` already builds the snapshot in a **temporary index**. It can run
  `git hash-object -w LOCAL`, then `git update-index --add --cacheinfo 100644,<sha>,PATH`
  (100755 for an executable).
- The user's worktree, index and `git status` are not changed.
- Dedup works as in option 2.
- The size limit is the bundle's, not `ARG_MAX`.
- `PATH` must be relative, must not contain `..`, and must not be a tracked path. These are the
  same rules that `fetch` globs are held to.
- Then testq needs no `.testq-remote/` directory in the Tessera tree. It runs
  `flightdeck run --on m3 --file ~/.testq/remote/run.sh=.fd/run.sh --file job.bin=.fd/job -- bash .fd/run.sh .fd/job`.

4a and 4b do not depend on each other. 4a is the fix that matters most: it fixes a real bug and
needs about one function in each of `DelegationService` and `Spawner`, plus a capability bit.
4b is a convenience.
