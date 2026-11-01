---
name: visual-provider
description: Write or check a Flight Deck visual provider, the folder that tells planning how to draw one kind of visual (a diagram, a comp, a chart). Use when asked to add a visual kind, make a provider from a description, or wrap an existing skill as a provider.
---

# Flight Deck visual provider

A provider is a folder with a `provider.toml`. Planning reads it to learn which kinds of
visual it can make and how. The agent that makes the visual follows the kind's instructions
file and writes the files itself, so a provider with no generator is only text.

## Write one

1. Choose the folder. Use `.flightdeck/visual-providers/<id>/` in the repo for one project, or
   `~/Library/Application Support/Flight Deck/visual-providers/<id>/` for all of them. A repo
   provider with the same `id` wins in that repo.
2. Copy `templates/provider.toml` and `templates/kinds/example.md` from this skill's folder.
   Rename the example kind, and set `id`, `name` and `version`. Keep `contract = 1`.
3. Write one `[[kind]]` per thing the provider can draw:
   - `id` is dotted and specific, such as `diagram.sequence`.
   - `summary` is one line the planning agent reads to choose a kind. Say what the kind shows
     and when to use it.
   - `output` is `html`, `svg`, `png`, `mermaid` or `canvas`.
   - `entry` is the file the agent writes in the draft folder, such as `visual.html`.
   - `pins` is optional: `nodes`, `canvas`, `dom` or `xy`.
   - `states` lists named states the visual can show.
   - `sizes` defaults to `["default"]`. `cost` is an honest `{ seconds = N, tokens = N }`.
   - `instructions` is the kind's Markdown file, for example `kinds/diagram.sequence.md`.
   - `assets` lists files from the provider folder copied into every draft.
4. Write each instructions file for the agent that will make the visual, in the second person.
   Say what to put in `entry`, what `visual.json` needs (`title`, `caption`, `states`), and
   what makes the visual good or wrong. Show one small example.
5. Run the check, and fix what it prints until it exits 0. If the provider declares a
   `[generator]` and ships `samples/<kind>/` input, add `--run-samples`, which also runs the
   generator in the sandbox against each sample. Otherwise run it plain:

```sh
flightdeck provider check <dir>
flightdeck provider check <dir> --run-samples
```

Exit 0 means the provider is valid. Exit 1 means problems or a failed sample, and exit 2 means
you used the command wrongly. Each problem prints as `provider.toml:<line>: error: ...`.
Warnings about unknown keys mean a typo.

## Wrap an existing skill

When the user names a skill that already knows how to draw something:

1. Read the skill's `SKILL.md` and list what it makes. Each distinct output is one kind.
2. Copy the skill's body (not its frontmatter) into `kinds/<kind id>.md`. Rewrite any step that
   asks the user a question, or that writes outside the draft folder, so it writes to the draft
   folder and asks nothing.
3. Copy the skill's templates, fonts and scripts into the provider folder, and list the ones
   every draft needs under `assets`.
4. Write the `[[kind]]` entries as above, and run the check.

## Rules every visual must pass

The planner validates each draft before it is final. State these in every instructions file:

- The `entry` file exists, and so does every state listed in `states`.
- No external URLs: no CDN scripts, web fonts or remote images. Inline or bundle everything.
- The whole folder is at most 10 MB.

A failure goes back to the agent, with up to 2 retries.

## A generator (only when the agent cannot write the output itself)

A `[generator]` turns the agent's source into the final file, for example a renderer for PNG.
It adds `command`, `timeout` (such as `"60s"`, at most `"600s"`) and `network` (default
`false`). In `command`, `{source}` is the agent's source file, `{input}` its input, `{kind}` the kind id
and `{out}` the output folder. Put sample input in `samples/<kind>/` and check with
`--run-samples`.
Paths must stay inside the provider folder. It runs in a sandbox in the draft folder, never in
the agent. A repo provider with a generator needs one approval in Settings, Flight Control,
Providers, and any change to the folder asks again. Prefer no generator.

## Rules

- `contract` is always `1`. A higher number reads as "needs a newer Flight Deck".
- Every path in the manifest is relative and stays inside the provider folder. No `..`, no
  absolute paths, no links that leave the folder.
- Do not tell the user the provider works until `flightdeck provider check` (with `--run-samples` when it applies) exits 0.
