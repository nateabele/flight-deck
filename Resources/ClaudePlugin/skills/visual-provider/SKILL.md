---
name: visual-provider
description: Write or check a Flight Deck visual provider, the folder that tells planning how to draw one kind of visual (a diagram, a comp, a chart). Use when asked to add a visual kind, make a provider from a description, or wrap an existing skill as a provider.
---

# Flight Deck visual provider

A provider is a folder with a `provider.toml`. Planning reads it to learn which kinds of visual
it can make. The agent that makes a visual follows the kind's instructions file and writes the
files itself, so a provider with no generator is only text.

## Write one

1. Put the folder in `.flightdeck/visual-providers/<id>/` (one repo, and it wins over a same
   `id` elsewhere) or `~/Library/Application Support/Flight Deck/visual-providers/<id>/`.
2. Copy `templates/provider.toml` and `templates/kinds/example.md` from this skill's folder.
   Set `id`, `name` and `version`. Keep `contract = 1`.
3. Write one `[[kind]]` per thing it can draw. `summary` is the one line the planning agent
   reads to choose a kind. `output` is `html`, `svg`, `png`, `mermaid` or `canvas`. `entry` is
   the file the agent writes. `pins`, `states`, `sizes` and `cost` are optional. `instructions`
   is the kind's Markdown file, and `assets` are provider files copied into every draft.
4. Write each instructions file to the agent that makes the visual: what goes in `entry`, what
   `visual.json` needs (`title`, `caption`, `states`), what is good and what is wrong, and one
   small example. State the draft rules: the `entry` file and every declared state exist, there
   are no external URLs (inline everything), and the folder is at most 10 MB.
5. Run the check and fix what it prints until it exits 0. Add `--run-samples` when the provider
   declares a `[generator]` and ships `samples/<kind>/` input, which also runs the generator in
   the sandbox against each sample:

```sh
flightdeck provider check <dir>
flightdeck provider check <dir> --run-samples
```

Exit 0 is valid, 1 is problems or a failed sample, 2 is wrong usage. Problems print as
`provider.toml:<line>: error: ...`. A warning about an unknown key is a typo.

## Wrap an existing skill

1. Read its `SKILL.md`. Each distinct output is one kind.
2. Copy its body (not the frontmatter) into `kinds/<kind id>.md`. Rewrite steps that ask the
   user questions or write outside the draft folder.
3. Copy its templates and scripts into the provider, and list the ones every draft needs
   under `assets`. Then write the `[[kind]]` entries and run the check.

## A generator (only when the agent cannot write the output itself)

`[generator]` takes `command`, `timeout` (such as `"60s"`, at most `"600s"`) and `network`
(default `false`). In `command`, `{source}` is the agent's source file, `{input}` its input,
`{kind}` the kind id and `{out}` the output folder. It runs sandboxed in the draft folder, never
in the agent. A repo provider with a generator needs one approval in Settings, Flight Control,
Providers, and any change to the folder asks again. Prefer no generator.

## Rules

- Every manifest path is relative and stays inside the provider folder: no `..`, no absolute
  paths, no links that leave it.
- A `contract` above 1 reads as "needs a newer Flight Deck".
- Do not tell the user the provider works until the check exits 0.
