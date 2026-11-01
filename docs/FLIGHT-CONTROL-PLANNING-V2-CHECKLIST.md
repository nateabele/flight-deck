# Flight Control planning v2 checklist

Agents cannot drive the GUI. A person runs these on a real Mac and phone. Every entry is
unverified until someone has run it and written the date beside it.

## P0: structured questions

### Mac

- [ ] Unverified. A new intake asks choice questions, not only typed ones.
- [ ] Unverified. The recommended option is already selected.
- [ ] Unverified. "Other…" lets you type an answer that is not in the list.
- [ ] Unverified. ⌘↩ sends the answers.
- [ ] Unverified. A legacy intake (saved before P0) with an open round can still be answered.

### Phone

- [ ] Unverified. The form appears for an intake that needs answers.
- [ ] Unverified. Send shows "Sending…", then the next stage appears.
- [ ] Unverified. Answer on the Mac first, then send from the phone. The phone shows "These questions were answered or replaced." and then shows what the intake does next (new questions or the fidelity).
- [ ] Unverified. Choose some answers, force quit the app, and open the intake again. The answers you chose are still selected.
- [ ] Unverified. Against a Mac without this feature, the phone still says "Answer on your Mac for now".

## P3 core: visual providers

Needs a real Mac. Settings → Flight Control → Providers, a repo with `.flightdeck/visual-providers/`, a terminal and Codex.

### Settings pane

- [ ] Unverified. The Providers section lists bundled, user and repo providers, each with a name, a source caption and a switch.
- [ ] Unverified. With no providers, the pane says "No providers found."
- [ ] Unverified. A repo provider with a generator shows an orange "needs approval" line and an Approve button.
- [ ] Unverified. A provider that needs a newer Flight Deck (contract 2) shows that in orange and has no Approve.
- [ ] Unverified. A broken provider shows its reason, and the provider it would have replaced still shows.
- [ ] Unverified. The same id in a repo and in the user folder gives two rows. Turning one off leaves the other on.
- [ ] Unverified. The switch survives a relaunch. `defaults read` shows `visualProviders.disabled.v2` with `<source>:<id>` entries.
- [ ] Unverified. A Mac that had `visualProviders.disabled.v1` set keeps those providers off after the upgrade.
- [ ] Unverified. The pane looks right in light and dark.

### Approve

- [ ] Unverified. Approve on a repo generator provider changes the line to approved.
- [ ] Unverified. Edit any file in that provider folder. The row asks for approval again.
- [ ] Unverified. `chmod u+x` on the generator asks again.
- [ ] Unverified. Edit the folder while the pane is open, then press Approve. Approve refuses and the row refreshes.
- [ ] Unverified. A data-only repo provider needs no approval.

### Move damaged file aside

- [ ] Unverified. Put junk in `provider-trust.json`. The pane shows a banner, the Approve buttons are gone and "Move damaged file aside" shows.
- [ ] Unverified. Press "Move damaged file aside". The file is renamed, the banner goes, and Approve works again. Old approvals are gone.

### `provider check`

- [ ] Unverified. `flightdeck provider check DIR` on a good provider exits 0 and prints "generator not run (pass --run-samples to try it in the sandbox)".
- [ ] Unverified. A provider with a missing instructions file, a missing `entry` or a bad kind exits 1 with a line number.
- [ ] Unverified. A bad usage (no directory) exits 2.
- [ ] Unverified. With `--run-samples`, the argv prints first, then the generator runs on `samples/<kind>/`. Its output is checked. Exit 0 on a good sample.
- [ ] Unverified. With `--run-samples`, a generator that exits non-zero, times out, writes over 10 MB or tries the network makes `check` exit 1 with the reason.
- [ ] Unverified. A generator cannot read `~/.ssh` and cannot write outside its folders.

### Skill

- [ ] Unverified. `visual-provider` is installed in `~/.codex/skills/` after Codex support starts, with `SKILL.md` and `templates/`.
- [ ] Unverified. A Codex session lists the skill.
- [ ] Unverified. Edit the installed `SKILL.md`. A refresh leaves it alone. Delete the edit and it refreshes.
- [ ] Unverified. `git init` inside the installed folder freezes it.
- [ ] Unverified. `delegate` and `peer-messaging` still install and work as before.
- [ ] Unverified. A Claude session loads `visual-provider` from the bundled plugin.
