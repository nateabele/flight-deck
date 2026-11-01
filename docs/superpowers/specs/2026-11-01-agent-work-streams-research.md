# Agent work streams: what the volume is, and a structure for tracking work

Status: research. Measured 2026-10-31 in the "Agent Streams" session, against the Tessera multi-agent work. Nothing here is designed for Flight Control yet. The "Flight Control Planning v2" session decides how much of it to fold in, and where.
Companion: [shared code index design](2026-11-01-shared-code-index-design.md). It is the spec for the largest lever found here (§3.3).

## 1. The problem

The maintainer runs many agent work streams across Tessera and `formula-editor`. Today these are:
- the planning controllers: The Plan (four sessions, "The Plan" and Parts 2–4) and Design;
- the execution lanes: Execute, and Execute 2/3/4, which are Codex streams working to Design's HANDOFF.

Work is already split into units with briefs, reports, reviews, gates and a merge queue. The streams still produce large amounts of prose. That prose costs tokens, and no one can follow it. The goal is a structure where state lives in small records, people and agents read views of those records, and prose is made only when asked for.

Flight Control is where this belongs. It already plans in rounds, releases tasks and runs agents on them. Most of what follows is a candidate shape for what Flight Control records and shows. It is not yet a spec.

## 2. How the Tessera work is run today

- **Units** have a brief, a report, a review package, a review, a re-review package and a re-review. That is 5–7 prose files per unit. For example, P4's B2B unit has a 26 KB `review-package.txt` and a 24 KB `rereview-package.txt`.
- **Ledgers** are append-only prose files. `2026-10-09-f5-m2/progress.md` is 598 KB, and `execute4/progress-execute4.md` is 245 KB. Near its end, the Execute 4 ledger starts dropping the spaces between words (`Recorddemosactual1:3pass(lunchpoll/…`): the agent is compressing prose to save tokens.
- **Rulings** (D-numbers) and follow-ups (U-numbers) are spread through ledgers, HANDOFFs and memory files. No list shows what is waiting on the maintainer.
- **Gates** are run through `testq`, a shared test queue that alternates between this Mac and m3. Merges go through `.merge-gates/queue.txt`.
- **Messages between sessions** go through flightdeck peer messaging as free prose.
- **Rules come in layers**: `RULES.md`, `codex-streams-brief.md`, `common.md` and HANDOFF additions. Every brief restates parts of them.
- **Memory has drifted.** `MEMORY.md` lists "No time-dependent tests" three times, and "Never git stash" and "Remote builds via testq" twice each.
- **`sdd/` is 1.2 GB.** It holds at least one copied worktree, `node_modules` included.

## 3. Measurements

These are characters of transcript content, not billed tokens. A character in a controller's context is re-read on every later turn until the next compaction, so the real cost is higher. The scripts are listed in §7.

### 3.1 The Plan's own context (all four sessions)

The four main transcripts total 347 MB, about 68.6M characters of content. They were compacted 46 times. Under them sit 2,309 subagent transcripts, about 2.5 GB.

| Source | Chars | Count | Avg | Share |
|---|---|---|---|---|
| Subagent results (task notifications) | 14.3M | 3,476 | 4.1K | ~21% |
| Messages from peer sessions | 4.1M | 2,049 | 2.0K | ~6% |
| Ledger appends through Bash heredoc (input plus echo) | 4.0M | 6,085 | 0.5K | ~6% |
| Fix-round and other instructions to subagents | 2.7M | 2,961 | 0.9K | ~4% |
| Messages out to peer sessions | 2.7M | 2,712 | 1.0K | ~4% |
| "Still waiting" interim notifications | 1.9M | 936 | 2.0K | ~3% |
| `git diff/show/log` read by the controller | 2.1M | 1,396 | 1.5K | ~3% |
| Plan and spec drafts through ExitPlanMode | ~2.9M | 45 | 33–68K | ~4% |

Most "user" turns are messages from other sessions, not the maintainer's typing.

### 3.2 Subagents

There were 1,190 review agents (716 review and 474 re-review) against 339 implementers and 209 fixers. Subagents made another 2,362 ledger appends of their own. A sample of 25 transcripts per role, extrapolated:

| Role | Agents | Avg chars each | Median turns | Est. total |
|---|---|---|---|---|
| implement | 339 | ~360K | 153 | ~122M |
| other (unclassified) | 456 | ~290K | 80 | ~133M |
| fix | 209 | ~300K | 119 | ~62M |
| review | 716 | ~136K | 34 | ~97M |
| re-review | 474 | ~84K | 15 | ~40M |
| gate/test | 115 | ~236K | 115 | ~27M |

- Subagents carry about **7×** the controller's volume: ~480M characters against ~69M.
- Re-reviews are about **8%** of subagent volume.
- Implementers re-read the same file 1.6 times each, on average. That is small.

### 3.3 Code reading is the largest cost

In every role, **45–58%** of the transcript is Bash read and search output. In a second pass over 150 random subagents (20.5M characters of Bash output):

| Kind | Share |
|---|---|
| `sed`/`cat` of source | 33% |
| `rg`/`grep` | 32% |
| `git` | 12% |
| briefs, reports, rules | 8% |
| review packages and diff files | 6% |
| the shared ledger | 1.5% |

Single outputs reach about 29K characters. Examples:
- a whole `cat Library.elm`, and a whole `LibraryTest.elm`;
- 500–1,000-line `sed` slices of `review-*.diff`;
- an unbounded multi-pattern `rg -i` across a worktree.

By language, **Elm was 27%** of all Bash output. Languages qartez supports were about 25%.

**Why the index is not used:** qartez fails in worktrees and has no Elm support. The causes, measured against v0.11.0, are listed in the companion spec, §3:
- the session starts with the wrong root;
- absolute paths are refused;
- `add_root` hits "database is locked" with 22 processes on one database;
- the database is 32.6 GB, 86% of it free pages;
- Elm is not supported;
- mutators write to the main checkout from a worktree.

That spec is the fix for this lever.

### 3.4 Not measured

- What the 456 "other" subagents were doing.
- Design's session (1,556 title entries).
- The Codex Execute streams' own transcripts.
- The `tessera` project directory (44 MB).

## 4. The proposed structure

Keep state in a few structured records, and render prose from them when someone asks. Agents write fields, and people read views.

### 4.1 One work registry: `units.jsonl`

Each unit is one line. When the unit's state changes, its controller rewrites that line:

```json
{"id":"P4.CHP","lane":"P4","owner":"exec-p4","state":"review","branch":"p4/checker-large-list",
 "head":"9d709b69c","gates":{"ts":"pass","elm":"pass","demos":"-","visual":"-"},
 "blocked_on":null,"needs_nate":[],"next":"Design review round 1","updated":"2026-10-31"}
```

The state machine is fixed:

`queued → briefed → impl → self-gated → review → fixing → merge-queued → merged | parked`

Ids are `<lane>.<unit>`. Each lane's controller is the only writer of its rows, so two agents never rewrite one row. All other sessions write only events.

### 4.2 An event log in place of ledgers: `events.jsonl`

Each transition or fact is one line:

```json
{"t":"2026-10-31T11:29","unit":"P4.CHP","ev":"gate","gate":"elm","result":"pass","log":"logs/chp-elm-2.log"}
{"t":"2026-10-31T11:40","unit":"P4.CHP","ev":"ruling","ref":"D96"}
```

- The event types are a closed set: `start`, `gate`, `review`, `finding`, `ruling`, `blocked`, `merged` and `note`.
- A `note` holds at most 200 characters. Anything longer goes in a file, and the event points to it.
- Logs, numbers and PNGs stay on disk and are referenced by path.
- A one-line CLI (`work ev …`) writes events and prints nothing on success. It replaces the ledger heredocs, which cost 4.0M characters plus 2,362 subagent calls.

### 4.3 One decisions register: `decisions.jsonl`

```json
{"id":"D96","q":"Reject legacy 14-counter stats docs or infer crosstab?","options":["reject","infer"],
 "rec":"reject","why":"D95 no backfill","cost_if_wrong":"lose pre-prod stats","status":"pending-me","units":["DM.WS1"]}
```

`status` is one of `pending-me`, `ruled`, `controller-ruled` or `superseded`. "What needs the maintainer" is a filter on this file. A ruling made in conversation becomes an entry here, and the message that carries it shrinks to "D96 ruled → register".

### 4.4 A fixed shape for each unit folder

- `brief.md` follows a template: goal, decided approach, files in scope, gates, done criteria. It links the rules and never restates them.
- `report.md` starts with a card of 15 lines or fewer: status, branch and sha, a gates table, deviations from the brief, open items. Detail goes below a `---` line.
- `findings.jsonl` holds one finding per line: `{id, sev, file, line, claim, status: open|fixed|disputed|wontfix}`. Review rounds append to and update this file. It replaces the package, review and re-review files.
- `evidence/` holds logs, PNGs and perf captures. Nothing in it is pasted into prose.

When a unit merges, its folder moves to an archive, and its registry row stays as `merged`.

### 4.5 Cards for anything an agent returns or sends

A subagent's final message, and any status message between sessions, is a card of about 600 characters (8 lines) or fewer, built from the registry row:

```
P4.CHP  review→fixing  9d709b69c  p4/checker-large-list
gates: ts✓ elm✓ demos– visual–
findings: 3 open (1 high) → units/P4/CHP/findings.jsonl
needs-me: —   next: fix F2 (traverseKeyedB order), rerun elm
```

A controller updates its registry from the card and never reads the prose behind it. Subagent results are the controller's largest channel, at 14.3M characters with an average of 4.1K. Cards would cut that channel by roughly 85%.

### 4.6 Views

- `board`: every unit in flight (lane, state, age, blocker, next).
- `me`: only pending decisions, items blocked on the maintainer, and merges ready for a look. This is the one thing the maintainer reads each day.
- `unit <id>`: the card, the last N events and the open findings.
- `digest --since 24h`: merges, new rulings and failures, as short prose, for when a narrative is wanted.

### 4.7 Rules, budgets, memory

- **Rules.** One rules file with sections (`all`, `codex`, `designer-gates`, `server-gates`). A brief names its sections, and a HANDOFF says only who the agent reports to and which sections apply.
- **Budgets** go in the `all` section:
  - a ledger entry is an event line;
  - a report header is 15 lines or fewer;
  - a message is a card;
  - logs, diffs and packages are passed by path and never pasted;
  - work folders never hold copies of worktrees or `node_modules`.
- **Reading budget**, the largest lever (§3.3), until the index works:
  - no whole-file `cat` of source;
  - `sed -n` only on line anchors the brief gives;
  - `rg -l` or `--max-count` first;
  - reviewers read the review package in pieces the size of a symbol.
- **Memory** holds pointers and lasting rules only. Status and lists of open items live in the registry.

## 5. Levers, ranked by measured volume

| # | Lever | Channel it cuts | Size |
|---|---|---|---|
| 1 | **A shared index that works in worktrees and knows Elm** (companion spec), plus the reading budget (§4.7) | subagent Bash reading | 45–58% of ~480M |
| 2 | Subagent returns as cards (§4.5) | controller task notifications | 14.3M |
| 3 | Rulings and status through the register and the registry (§4.1, §4.3) | messages between sessions, both directions | 6.8M |
| 4 | A one-line event CLI in place of ledger heredocs (§4.2) | ledger appends | 4.0M plus 2,362 subagent calls |
| 5 | Fix rounds cite finding ids (§4.4) | fix instructions | 2.7M |
| 6 | Subagents wait in the foreground on `testq` | "still waiting" notifications | 1.9M |
| 7 | The controller reads `--stat` and the review card, never the diff | controller git reads | 2.1M |
| 8 | Fewer re-reviews (§6, **done**) | re-review agents | ~40M (~8% of subagent volume) |
| 9 | A new controller part starts from `board` and `me` instead of prose | 46 compactions' re-summaries | not measured |

## 6. Already changed: fix rounds verify, they do not re-review

Lever 8 was put in place on 2026-10-31 at the maintainer's request.

- **Rule text:** `tessera/.superpowers/sdd/2026-10-20-consolidated/RULES.md`, section "Fix rounds: verify, don't re-review".
- **Hook:** `~/.claude/hooks/plan-gate.py` and `~/.claude-radify/hooks/plan-gate.py` (identical copies). The override for `subagent-driven-development` cancels the superpowers default, "every round ends with a scoped re-review".

The rule:
- A fix round is one fix dispatch, with no re-review agent.
- The fixer answers every finding by id: ADDRESSED with file:line and the test that covers it (command and result), or NOT ADDRESSED with the reason.
- The controller checks that every finding has an answer and that the tests ran, without reading the diff. That check closes the round.
- The final whole-branch review gets every findings list and fix report, and verdicts each fix.
- A scoped re-review still runs only when:
  - the round fixed a Critical finding or a security-review finding;
  - the fix changed approach, or touched files outside the reviewed diff;
  - the round fixed an Important finding on a unit that merges on its own, with no later whole-branch review.
- Minor-only and Nit-only rounds are never re-reviewed.
- Lanes with their own written review process keep it. Design's Codex streams are one ("the maintainer asked for extra care").

For Flight Control this is a policy its review loop can encode. A finding with an id, a severity and an answer is the record the controller check needs.

## 7. Notes for folding this into Flight Control

These are candidates, not decisions. The Planning v2 session owns the mapping.

- **Units are Flight Control's tasks.** The registry state machine (§4.1) and the event log (§4.2) are the record a swarm already keeps, or should keep, for each task. The `board` and `me` views are natural Flight Control screens, and the phone could show `me`.
- **The decisions register is close to Planning v2's structured questions and Ask threads.** A clarifying question answered by choosing, or a thread outcome, is a `decisions.jsonl` entry with options, a recommendation and a status. Rulings made during execution, not only during planning, would land in the same register.
- **Cards are an adapter-level contract.** Flight Control already sits between agents through the adapter layer and peer messaging. It could require card-shaped returns and status messages, and keep the full prose on disk.
- **Findings with ids** fit the review loop and the fix-round rule (§6) directly.
- **The shared index** (companion spec) is a dependency of the reading budget. It is also where a released task's context could come from, instead of agents reading files whole.
- **Flight Control Planning v2's own run (reported by that session, 2026-11-01):**
  - Its SDD already uses three of these levers: reports go to files, the final review is split across three area reviewers, and rulings are one-line entries.
  - Its largest cost was waiting on the single remote test-Mac lock, not context. Gate capacity may matter more than context volume once the levers in §5 are in place.
- **Not covered here:** Codex stream transcripts, and how Flight Control's own rounds compare in volume. Measuring one Flight Control intake the same way would show whether the same channels dominate.

Analysis scripts from the 2026-10-31 session (temporary; copy them if needed):
- `noise.py`, `sample.py` and `tally.py`: controller breakdown;
- `subs.py` and `subnoise.py`: subagents by role;
- `bigreads.py` and `bigreads2.py`: Bash output by kind.

They are in `/private/tmp/claude-501/-Users-me-Projects-Tessera-formula-editor/718852d7-af77-46af-884a-10a40adf6b21/scratchpad/`.
