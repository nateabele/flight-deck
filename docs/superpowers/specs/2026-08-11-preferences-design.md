# Preferences — Design

**Date:** 2026-08-11 · **Status:** design approved, ready for planning

## 1. Goal

Give Flight Deck a Preferences window (⌘,) with three tabs:

- **Claude** — every `claude` startup option that makes sense for an interactive session,
  as real controls, plus a freeform command field that stays in two-way sync with them.
- **Projects** — per-project overrides of those options, merged per-flag over the globals.
- **Shell & Environment** — the shell and environment that sessions are spawned into,
  currently hardcoded in `ShellResolver` and `SessionStore.insertSession`.

Terminal appearance is deliberately *not* a tab: `GhosttyApp` already loads the user's
`~/.config/ghostty/config`, and that file is the escape hatch (§10).

## 2. The spine: one catalog, three pure functions

Everything derives from a declarative table of the options Flight Deck models. Controls,
the parser, validation, merge, and the launch command all read from it, so adding a flag
later is one table entry — not five parallel edits across the UI, the parser, and the
serializer.

```swift
struct FlagSpec {
    let canonical: String        // "--allowedTools"
    let aliases: [String]        // ["--allowed-tools"]
    let kind: Kind
    let section: Section         // grouping in the UI

    enum Kind {
        case toggle                        // --verbose
        case negatable(off: String)        // --chrome / --no-chrome
        case choice([String], allowsCustom: Bool)  // --effort (fixed); --model, --autocompact (custom)
        case optionalValue(String?)        // --debug [filter], --worktree [name]
        case string, multiline, path       // --agent, --system-prompt, --debug-file
        case list                          // --add-dir, --mcp-config (repeatable)
    }
}

enum FlagValue: Equatable { case on, value(String), list([String]) }

struct FlagSet: Equatable {
    var values: [String: FlagValue]   // keyed by canonical name
    var passthrough: [String]         // verbatim tokens we do not model, in order
}
```

Three pure functions over it, each unit-testable with no window, no store, and no pty:

| Function | Signature | Notes |
|---|---|---|
| **parse** | `String -> (FlagSet, [Diagnostic])` | POSIX-ish tokenizer (single quotes, double quotes, backslash escapes), then catalog lookup. |
| **serialize** | `FlagSet -> String` | Canonical order by section, then the passthrough tail verbatim. Values quoted via `ClaudeSession.shellQuoted`. |
| **merge** | `(global: FlagSet, project: FlagSet) -> FlagSet` | Per-flag; the project's entry wins per key. |

**The load-bearing invariant is `parse(serialize(x)) == x`** for any `FlagSet`. That single
property is what makes the two-way sync trustworthy rather than hopeful, and it is the test
to write first.

`merge`'s one asymmetry: `passthrough` is unkeyed, so it cannot merge per-flag. Global's
tail is concatenated ahead of the project's. Two overlapping passthrough tails therefore
both appear on the command line and `claude`'s own last-wins parsing resolves them. Stated
here rather than discovered later.

### 2.1 Quoting is a security boundary, not a formatting detail

`--system-prompt` puts arbitrary user text onto a shell command line that is typed into a
live pty. `ClaudeSession.shellQuoted` (wrap in `'…'`, rewrite `'` as `'\''`) is correct and
sufficient, and every value must go through it.

The existing `ClaudeSession.sanitizedName` — which *strips* `;&|` backtick `$()<>` — must
**not** be reused here. Stripping `$` and backticks out of a system prompt corrupts
legitimate content. Quoting, not stripping, is the right tool once the value is guaranteed
to be a single argument. A test pins that a system prompt containing `'; rm -rf ~; '`
round-trips as literal text.

## 3. The Claude tab

### 3.1 Controls

Thirty-six options, grouped into collapsible sections. **The rows are rendered generically
from `FlagSpec.Kind`**, so the UI is about six row views rather than thirty-six hand-written
ones — a toggle row, a choice row, a string row, a multiline row, a path row, a list row.

`allowsCustom` is why `choice` is not a plain enum: `--effort` has a closed set, but
`--model` takes any full model name beyond the `opus`/`sonnet`/`fable` aliases, and
`--autocompact` takes either `auto` or a token count. Those render as a picker with a
*Custom…* entry that reveals a text field.

| Section | Options |
|---|---|
| Model & Effort | `--model`, `--effort`, `--autocompact` |
| Permissions & Tools | `--permission-mode`, `--dangerously-skip-permissions`, `--allow-dangerously-skip-permissions`, `--tools`, `--allowedTools`, `--disallowedTools`, `--disable-slash-commands` |
| Context & Prompts | `--system-prompt`, `--append-system-prompt`, `--add-dir`, `--agent`, `--exclude-dynamic-system-prompt-sections` |
| MCP & Plugins | `--mcp-config`, `--strict-mcp-config`, `--plugin-dir`, `--plugin-url`, `--settings`, `--setting-sources` |
| Integrations | `--ide`, `--chrome`/`--no-chrome`, `--remote-control`, `--remote-control-session-name-prefix`, `--worktree`, `--tmux`, `--brief`, `--prompt-suggestions` |
| Troubleshooting | `--bare`, `--safe-mode`, `--verbose`, `--debug`, `--debug-file`, `--ax-screen-reader`, `--betas` |

Excluded as `--print`-only or in direct conflict with Flight Deck's own session management:
`--print`, `--output-format`, `--input-format`, `--json-schema`, `--max-budget-usd`,
`--fallback-model`, `--include-partial-messages`, `--replay-user-messages`,
`--forward-subagent-text`, `--include-hook-events`, `--no-session-persistence`,
`--continue`, `--resume`, `--from-pr`, `--teleport`, `--cloud`, `--bg`, `--environment`,
`--file`, `--fork-session`. They remain reachable through passthrough (§2) — they are
excluded from the *catalog*, not forbidden.

`--session-id` and `--name` are app-managed and never controls (§3.2).

### 3.2 The command field: locked prefix, editable tail

The field shows the whole command, with the app-managed flags non-editable.

```
Launch command
┌──────────────────────────────────────────────────────────┐
│ claude --session-id ⟨generated⟩ --name ⟨session title⟩   │
│   --model opus --permission-mode plan --add-dir ../shared│
└──────────────────────────────────────────────────────────┘
  ^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^^ locked
```

**The simplification that makes this tractable:** the app-managed flags are always a
contiguous *prefix* of the command (`launchCommand` already emits them first). So this is
not arbitrary inline tokens needing attachment cells — it is an immutable prefix with an
editable tail. That is a much smaller `NSViewRepresentable`:

- Locked range rendered with a distinct attribute, de-emphasised.
- `textView(_:shouldChangeTextIn:replacementString:)` returns `false` when the range
  intersects the locked prefix.
- `textViewDidChangeSelection` clamps the caret out of the locked range so arrow keys and
  ⌘← skip it.
- In the **Claude** (global) tab there is no real session, so the prefix shows placeholders:
  `--session-id ⟨generated⟩ --name ⟨session title⟩`. In the **Projects** tab it is the same,
  since overrides are also templates.

### 3.3 Sync

Asymmetric, so text is never rewritten under a live cursor:

- **Controls → text:** immediate on every control change. Re-serialize and replace the
  editable tail only; the locked prefix is untouched.
- **Text → controls:** on blur (`textDidEndEditing`) or ⌘↩. The tail is parsed, controls are
  updated, and the tail is re-canonicalized from the resulting `FlagSet`.

A parse that fails outright (unterminated quote) keeps the last good `FlagSet`, shows the
error, and leaves the controls alone rather than clobbering them from garbage.

## 4. Diagnostics

Non-blocking. Warnings render in a row beneath the field; nothing prevents saving or
launching, because the catalog is a snapshot and the user may legitimately be ahead of it.

| Rule | Severity |
|---|---|
| Token looks like a flag but is not in the catalog | warning — kept in passthrough, still launched |
| Unterminated quote | error — controls not updated, last good state retained |
| `--chrome` together with `--no-chrome` | warning |
| `--tmux` without `--worktree` | warning (`claude` requires the pair) |
| `--dangerously-skip-permissions` enabled | confirmation alert on enable, then a persistent inline caution |

## 5. Persistence

Mirrors the existing `SessionPersisting` / `UserDefaultsSessionPersistence` pair, so there is
one storage idiom in the codebase rather than two.

```swift
protocol PreferencesPersisting { func load() -> Preferences?; func save(_: Preferences) }

struct Preferences: Codable, Equatable {
    var globalFlags: FlagSet
    var projectFlags: [String: FlagSet]   // keyed by standardized path
    var shell: ShellPreferences
}
```

Project keys are `url.standardizedFileURL.path`, matching `SessionStore.indexOfRepo`.

**A repo is not a durable object.** `SessionStore.closeSession` removes a `Repo` once its
last session closes, so overrides cannot live on `Repo` or be enumerated from `repos` alone.
They persist independently, keyed by path, and the Projects tab lists **open projects ∪
projects with saved overrides**, with an explicit *Remove Override* action. Without this the
override silently vanishes the moment you close a project's last session.

## 6. The Projects tab

Master/detail: project list on the left, the same generic control rows plus command field on
the right, showing the **merged** result.

Each row carries an inherited/overridden state. Inherited renders the global value
de-emphasised; overriding it makes the row normal-weight and reveals a *Revert to Global*
affordance that clears the key from the project's `FlagSet` (distinct from setting it to an
empty value, which is a real override meaning "off").

That distinction — absent key vs. present-but-empty — is the whole per-flag merge, so
`FlagSet.values` uses key presence, never a sentinel.

## 7. The Shell & Environment tab

| Control | Wires to |
|---|---|
| Shell: *Use `$SHELL`* (default) / explicit path | `ShellResolver.resolve(environment:override:)` — the existing pure function gains an override parameter, keeping it testable |
| Environment variables (key/value table) | `Ghostty.SurfaceConfiguration.environmentVariables`, already wired through to libghostty |
| **Clear `CLAUDE_CODE_CHILD_SESSION` for new sessions** (default **on**) | Same field. Fixes the documented footgun in `docs/FOLLOWUPS.md`: an inherited marker turns transcript saving off, which silently kills inbound rename sync |

That last toggle is the reason this tab earns its place — it converts a known
development-time trap into a setting, defaulted to the safe behaviour.

## 8. Wiring into launch

```swift
ClaudeSession.launchCommand(sessionID:title:flags:) -> String
ClaudeSession.resumeCommand(sessionID:title:flags:) -> String
```

`SessionStore.insertSession` resolves `merge(global, project)` at session-creation time and
passes the result. Two details that are easy to get wrong:

- **`resumeCommand` has two branches.** `claude --resume X || claude --session-id X --name Y`
  — flags must be applied to *both*, or the fallback path silently launches unconfigured.
- **Preferences affect new sessions only.** Running sessions are untouched; there is no
  live re-configuration of a `claude` already at a prompt. The tab says so explicitly
  ("Applies to new sessions").

## 9. Testing

Pure, no window required:

- **Property: `parse(serialize(x)) == x`** across generated `FlagSet`s covering every `Kind`.
- Tokenizer: single quotes, double quotes, backslash escapes, embedded spaces, empty values.
- Injection: `--system-prompt "'; rm -rf ~; '"` survives as literal text.
- Passthrough: an unknown flag and its value survive byte-identical and produce a warning.
- Merge: project key wins; absent key inherits; cleared key falls back to global; passthrough
  tails concatenate global-first.
- Each diagnostic rule, both firing and not firing.
- Persistence round-trip, and specifically that an override survives closing the project's
  last session.
- `ShellResolver` override precedence over `$SHELL`.
- `launchCommand` and `resumeCommand` with a non-empty `FlagSet`, asserting flags land on
  **both** branches of the resume fallback.

UITest:

- Open Preferences (⌘,), toggle `--verbose`, assert the command field text updates.
- Type `--model opus` into the field, blur, assert the Model control shows `opus`.

## 10. Out of scope

- Terminal appearance (font, theme, cursor, scrollback) — `~/.config/ghostty/config` is the
  escape hatch, already loaded by `GhosttyApp`.
- A third, per-session override layer.
- Import/export of preference sets.
- Editing `~/.claude/settings.json` — Flight Deck composes a command line, it does not manage
  Claude's own config files.
- Validating flag *values* against `claude`'s own validation (e.g. whether a model alias
  exists). Shape is validated; semantics are `claude`'s job.
- A **login-shell toggle.** libghostty already spawns sessions through `/usr/bin/login`
  (`FlightDeck → /usr/bin/login → -/bin/zsh`, per `docs/ARCHITECTURE.md`), so a toggle here
  would mean opting *out* of the default rather than into it, and the mechanism for doing so
  has not been established against `SurfaceConfiguration`. Left out rather than specified on
  a guess; the shell control is a path only.

## 11. Risks

- **The locked-prefix text view is the riskiest component.** Built standalone and first, with
  the prefix simplification of §3.2; if it proves troublesome the fallback is a read-only
  prefix `Text` above a plain editable `TextField`, which loses the single-field feel but
  nothing else.
- **The catalog drifts as `claude` ships new flags.** Absorbed by design: unknown flags are
  preserved and warned about, never rejected (§4). The catalog is documented as a snapshot of
  `claude --help` taken 2026-08-11.
- **Thirty-six controls is a lot of SwiftUI.** Mitigated by generic rendering from
  `FlagSpec.Kind` (§3.1); if rows are hand-written this becomes the bulk of the work and the
  bulk of the bugs.
