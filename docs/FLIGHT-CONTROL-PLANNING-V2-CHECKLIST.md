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

## P1: ask threads

Every item is unverified until the maintainer checks it in the GUI.

### Mac

- [ ] Unverified. Select a passage and press ✦ Ask (last on the selection toolbar). The panel opens on a new thread anchored there, composer focused. With no selection, the thread is on the whole plan.
- [ ] Unverified. The selection toolbar no longer offers the Question note kind; old Question notes still show.
- [ ] Unverified. ⌘↩ sends. The card and panel show live activity ("reading §3…", "thinking"), then the reply with citation chips that open what they name.
- [ ] Unverified. ⌘⇧↩ sends and resolves. A resolved thread moves to Resolved and refuses a message until Reopen.
- [ ] Unverified. ⌘[ and ⌘] move between threads while the panel has focus.
- [ ] Unverified. A proposed diff reads in place as prose with a green bar; hover shows the old text struck through with ✓ ✗ Edit ✦.
- [ ] Unverified. ✓ changes the plan as a human edit; the diff goes away. ✗ leaves the plan as it was.
- [ ] Unverified. Edit, change the words, Accept edited: the plan keeps your words. Edit then Cancel: the passage is as before. Edit then ⌘Z: the strip goes away.
- [ ] Unverified. The auto-accept switch applies the next diff without asking.
- [ ] Unverified. A grok or OpenCode thread's header says "reads files only".
- [ ] Unverified. Notes the agent made show "✦ from thread …" and can be withdrawn.
- [ ] Unverified. Quit Flight Deck mid-turn and relaunch: the reply arrives, and no turn runs twice.
- [ ] Unverified. After a round lands, the thread shows "Now reading <round>", and a diff whose passage the round rewrote is stale with Re-propose.
- [ ] Unverified. The next round after an accepted diff keeps the change (its prompt carries the thread's decision).
- [ ] Unverified. A Send of structured answers that the Mac refuses shows why under the form.

### Phone

- [ ] Unverified. Ask in the reader's selection menu opens a thread screen; the reply arrives while it is open.
- [ ] Unverified. A pending diff shows as a green bar beside the proposed text, in the plan's serif. Tapping shows the old text struck through, with Accept and ✗.
- [ ] Unverified. A stale diff is a tinted card under its passage.
- [ ] Unverified. An unsent note and an unsent ask both sit full width under their passage.
- [ ] Unverified. The fleet row shows a "needs you" count for a thread waiting on you.
- [ ] Unverified. A grok or OpenCode thread says "reads files only".
- [ ] Unverified. Pop the intake screen while answers are "Sending…", let the Mac move on, push it again: it is not stuck on "Sending…".
- [ ] Unverified. Against a Mac without threads, the reader offers no Ask.
- [ ] Unverified. ✓ a diff on the phone: the Mac's plan editor shows the new words, and typing there afterwards keeps them.
- [ ] Unverified. Send an ask with the Mac unreachable, wait over a minute, reconnect and tap Retry: only one thread opens and one turn runs.

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

