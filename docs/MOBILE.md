# Flight Deck — the phone companion

`FlightDeckMobile` is the iOS client for the fleet the Mac replicates over `FleetKit` (see the
"Fleet replication" section of [ARCHITECTURE.md](ARCHITECTURE.md)). This doc is what only a
device on a network can prove, plus how to get a build onto one.

**Some of it now runs.** `FlightDeckMobileTests` is an app-hosted unit suite on the simulator —
`./scripts/test-ios.sh` — and it covers the phone's decision-making: the typed-code field, the
two orderings `FleetModel` imposes on the keychain, and the status vocabulary the phone shares
with the Mac. What it cannot reach is everything below. A unit test in the app process has no
window, no camera and no second device, so SwiftUI layout, the caret, AVFoundation and the wire
itself are exactly as unrun as they were, and installing on hardware still needs a development
team and a provisioning profile this build machine does not have. Read each checklist item as
"still nobody has seen this", because that is what it means.

## Running it at all

Neither is configured in this repo, deliberately:

- **Install an iOS Simulator runtime** (Xcode → Settings → Components, or `xcodebuild
  -downloadPlatform iOS`), then `xcodebuild -project FlightDeck.xcodeproj -scheme
  FlightDeckMobile -sdk iphonesimulator build`. One is present on this build machine — which is
  why `build-ios.sh` takes its real-build branch below — but it is machine state, not something
  the repo pins, so the script is written to survive its absence. A simulator has no camera, so
  pairing by scanning is unavailable there — pairing by typing the code (checklist item 2) is
  not a fallback for this case, it is the *only* route that works on a simulator at all.
- **Or set `DEVELOPMENT_TEAM` and a bundle id you own**, then build for `-sdk iphoneos` and
  install on hardware. Neither is hard-coded into `project.yml`: this build machine has no
  provisioning profile to build against, and a real team id checked into a shared repo is a
  merge conflict waiting to happen the moment a second person's Apple ID touches it.

`./scripts/build-ios.sh` does neither of these. It builds `FleetKitiOS` for the simulator and
for a real device, and then builds `FlightDeckMobile` and its test bundle — **a real build, on this machine,
not the type-check fallback**: the script only falls back when no iOS platform is installed to
resolve a destination against, and it says which one it took (`** FlightDeckMobile BUILD
SUCCEEDED **` versus `TYPE-CHECK PASSED`; on the fallback the test bundle is skipped
entirely, because a test bundle cannot be type-checked without the host module it imports).
The difference is not cosmetic. A type-check runs no SIL passes, so Swift 6's region-based
isolation checking never fires — the first real build of this target found an error
`swiftc -typecheck` had been passing over for the life of the branch
(see `QRScannerController.metadataOutput`'s comment). Read the line the script prints rather
than assuming. See its own comments for the rest, and the note in `AGENTS.md`.

## Running the unit suite

```bash
./scripts/test-ios.sh    # 116 tests, ~45s including creating and booting the simulator
```

It creates a throwaway simulator, runs `FlightDeckMobileTests` inside `FlightDeckMobile`, and
deletes the device however it exits. It never uses a simulator you already have booted, and
that is deliberate: `xcodebuild test` INSTALLS the app onto its destination, so a run pointed
at a device someone is testing on would overwrite the build under their hands.

**What it covers**, and each of these guards a defect the phone actually shipped:

- `TypedCodeField` — that the field rewrites what is typed through `PairingCode.grouped`
  (uppercase, `XXXX-XXXX-XXXX`, `O`→`0` and `I`/`L`→`1`), that a failed checksum produces a
  verdict instead of a `PairingCode`, and that the Pair button enables on twelve symbols
  whether or not the checksum passes.
- `FleetModel` — that a keychain refusal aborts the adoption on both paths rather than leaving
  a pairing that exists only in memory, and that the four `PairingInitiator.Failure` cases map
  to four distinct messages with `.wrongCode` and `.attemptsExhausted` not swapped.
- `SessionStatusGlyph.label(for:)` — the accessibility vocabulary, string for string against
  what `SessionStatus.tooltip` produces on the Mac for the same state.
- `SessionTimelineModel` — which fetch is in flight, that a second one is refused while it is,
  that a fetch nobody answers fails on its own deadline instead of spinning forever, and that a
  late answer to a dead request changes nothing.
- `TimelineStyle` — everything the timeline decides about *what text appears at all*: that a
  tool result arriving without its call supplies the output panel rather than a command line
  (the defect the renders found), that a command line skips the bare delimiter a pretty-printed
  input opens on, that both agents' ISO-8601 spellings parse and anything else renders as
  nothing, that truncation is said with its size and only when something was cut, and that a
  VoiceOver label is capped so one row is not a quarter hour of speech.
- `JSONTree` — which tool bodies are drawn as a tree at all, and what a row of one says.
  The three gates (kind, parses whole, has structure) with a **real truncated
  `AskUserQuestion` input** proving the fallback, plus the VoiceOver vocabulary: a container's
  size and open/closed state, array positions spoken one-based, and a 300-character option
  description capped rather than read out. The parser and the flattening are `FleetKit`'s and
  run in `FlightDeckTests/JSONValueTests` on macOS — key order, number lexemes, every prefix of
  a real body refused, and the two-levels-then-stop default expansion.
- `TimelineStyle.proseLineLimit` / `.opensDetail` — **how much of a message the row shows,
  and whether tapping it leads anywhere.** One decision with three consequences, asserted as
  one: prose is drawn whole, so its row carries no chevron and offers Copy instead; a tool
  body, a thinking block, a `.prompt` and an `.unknown` keep their clamps and their way in.
  The ceiling is asserted against a **real 6,775-character answer** that runs to 201 lines in
  the row's column — cut at the ceiling, and still leading somewhere. And the invariant
  underneath both, stated once so it cannot drift: clamped and tappable are the same fact, so
  there is no whole body with a chevron and no cut body with nowhere to go. `exceeds` is
  asserted to count what *wraps* rather than what was typed, on a 2,400-character paragraph
  with no newline in it at all — the shape a real answer takes.
- `TimelineStyle.rendersMarkdown` / `.spoken` — **which parser touches which body.** Prose
  (`.assistantText`, `.userTurn`) is drawn as the Markdown it was written in; a tool call, a
  tool result and an `.unknown` never are. That boundary has a sharp edge worth stating: cmark
  reads a diff's leading `-` as a bullet, so `- removed line` comes back out of it indented and
  folded into a list with the `+` line, and `***` in a stack trace becomes a horizontal rule.
  The suite asserts a tool result is spoken **byte-identical** for that reason. It also asserts
  the flattening the VoiceOver label now does — a raw body announced `**Fixed**` with its
  asterisks, and a listener cannot skim past those.
- `SessionTimelineScreen` — the decisions the session screen makes that are not layout:
  *where* a failure is said (at the top, with the conversation still under it — the bottom of a
  list is where nobody is looking fifteen seconds after a "Load earlier" tap), that an empty
  state never appears while a fetch is running, that a codex session never claims a number of
  sub-agents, that a tool call is paired with its output by `callID` rather than by position,
  that folding a result into its call never swallows a result whose call is off the page and
  never swallows prose, and *when* an arriving page scrolls the list — always on the first one,
  never over a reader who has scrolled up.
- `PromptComposer` — the composer's two decisions, which are the only parts of a SwiftUI view a
  test in this process can reach: **whether this tab can take a message at all**, and whether
  this draft can be sent. The first has three refusals with their exact copy (codex and any
  agent this build has never heard of; a `"shell"` tab *and* a statusless one, which are
  different values and not the same check; a session the fleet no longer lists) and three
  negative controls — `idle`, `busy` and `waiting` are all **available**, because a prompt
  arriving mid-turn is the ordinary case and the Mac queues it. The second is the Send button's
  rule: refused for whitespace, refused for text the Mac's own `PromptText` would refuse, and
  refused while an earlier message is still in flight, which is the double-tap guard that stops
  one tap becoming two messages in an agent's queue.

**What it structurally cannot cover.** Every one of these is on a checklist below instead, and
none of them should ever grow an assertion here that merely re-reads the source:

- Anything SwiftUI renders or measures — layout, wrapping, the disabled button's *appearance*,
  where the caret lands when `text` is reassigned mid-string. There is no window in a unit-test
  process and no UI-test target on this side.
- Whether a modifier does anything at runtime. `.textInputAutocapitalization(.characters)` is
  a hint to the software keyboard; a unit test can only observe that the source contains it,
  which is not a test.
- The camera. A simulator has none, so `QRScannerController` — the least-proven code on this
  branch — is unreachable from here in full.
- The wire. Pairing and replication need a second process on a real network; see "The
  cross-process check" at the end.

## The manual checklist

Each item is stated as an observable outcome, not "check it looks right". None of these are
run by anything on this machine.

1. Pair by scanning; the Mac's Devices tab shows the phone as Connected.
2. Pair by typing the twelve-character code instead of scanning; same outcome. This is not a
   lesser path — it is what a user falls back to when they decline the camera, and it is the
   only pairing route that works at all on a simulator.
3. Rename a session on the Mac — the phone's row changes within a second.
4. Let a session finish while looking elsewhere — the unread dot appears on both.
5. Tap the row on the phone — the dot clears on the Mac. Unread is one fleet-wide fact (spec
   §8), not a per-device one.
6. Close a project on the Mac — its section leaves the phone.
7. Put the phone on cellular, then back on Wi-Fi — it reconnects without re-pairing.
8. Quit Flight Deck — the phone shows "Not connected", dimmed, not a frozen live-looking fleet.
9. Leave the phone off the network for ten minutes, then return — it resumes rather than
   re-downloading (check the Mac's log for a replay rather than a snapshot).
10. Revoke the device on the Mac — the phone disconnects and cannot reconnect.
11. Let a pairing code expire unscanned, then scan it — it is refused.
12. Arm a code, quit Flight Deck before it is scanned, relaunch, then wait out the window and
    scan it — it is refused. Item 11 never restarts the app, so it cannot exercise this: a
    provisional pairing row that outlives the process it was armed in must be revoked at the
    next launch, not merely re-timed against a clock that reset when the app relaunched.
13. **Type a code with one character wrong.** The phone says "That code doesn't look right"
    *without* contacting the Mac — and the Mac's next three attempts are still available, so
    the correct code entered immediately afterwards pairs. A checksum that had stopped working
    would show up here as a generic pairing failure and a spent attempt.
14. **Type a wrong-but-well-formed code three times, then the correct one.** The third failure
    burns the window: the Mac's sheet closes, and the correct code afterwards is refused. Arm
    again and it works.
15. **Arm two Macs at once and type the second one's code into the phone.** It pairs with the
    second. Then, on the *first* Mac, enter its own correct code — it still has all three
    attempts minus the one the phone spent on it. The budget is per-Mac (spec §7); a global
    counter would have left the first Mac short.

16. **Tap any session row — it opens.** Every row, read or unread, connected or not. This is
    the item that came back three times as "tapping sessions does nothing", and it was true:
    until Task 4 the row was a `Button` only when it was unread and there was nothing to open.
17. **Tap an unread row and watch both things happen**: the screen pushes *and* the dot clears
    on the Mac. One gesture, two effects — the mark rides the same tap (spec §8), and a
    `simultaneousGesture` on a `NavigationLink` is the only untested part of that pairing.
18. **Scroll to the top of a long conversation and tap "Load earlier".** Older messages arrive
    above the reader without moving what they were reading. Do it twice more, to the top of the
    transcript, and the row goes away rather than re-fetching the first page forever.
19. **Open a session, go back, and open it again.** The conversation is still there, and no
    fetch runs for what the phone already holds — the model is cached per session, so this is
    where a rebuilt-on-every-update model would show up as a screen that empties itself.
20. **Quit Flight Deck on the Mac with a session screen open, then tap "Load earlier".** The
    reason appears at the TOP of the list, above the button, with the conversation still under
    it — never a blank screen, and never a message at the bottom where the reader is not.
21. **Rename a session on the Mac while its screen is open** — the title in the navigation bar
    changes. The session is read live out of the fleet rather than captured when the screen was
    pushed.
22. **Open a session and check where it lands.** On the NEWEST message, not the oldest one of
    the most recent page. A `List` draws oldest-first, so this is a programmatic scroll
    (`SessionTimelineScreen.follow`) and the only part of it a test can reach is the rule about
    *whether* to scroll — that the scroll itself happens is this item. It must not visibly
    animate from the top.
23. **Open a session, scroll up into the history, and let the agent keep working.** New rows
    land below without moving what is being read. Then scroll back to the bottom: from there
    on, arriving rows are followed. This is the one behaviour the 1.5s poll can ruin, and it
    ruins it continuously rather than once.
24. **Give an open session a multi-step task on the Mac** — new rows land on the phone
    throughout the turn, not all at once at the end. Item 3 does not cover this: a rename fires
    an event and a long busy turn fires none, which is exactly the case the poll exists for.
25. **Leave the session screen** — the Mac's log shows the timeline requests stop. An idle
    session's screen never issues one at all.
26. **Tap a `Bash` row.** The full command and its full output, each with a working Copy button,
    and the text is selectable as well. Then tap a row for a tool result whose call is NOT on
    screen (page back until one is orphaned): it must show the OUTPUT, not the first line of it.
27. **Open a **codex** session and a **claude** session side by side while both are working.**
    Claude's footer may read "Working — 2 subagents"; codex's says only "Working", **never
    "0 subagents"** — codex writes no sub-agent record of any kind, so its count of 0 means
    unknown, not none.
28. **Neither agent shows a cursor, a caret, or a typing animation, at any point.** Both are
    read from files that carry whole records, so a live cursor would be a fiction.
29. **Look at a long conversation at the largest accessibility text size.** Rows grow; the
    symbol column, the timestamp and the tool cards do not collide or clip. Rendered offscreen
    at `.accessibilityExtraExtraExtraLarge` and it holds, but a render is not a device.
30. **Tap an `AskUserQuestion` row and open its options.** The input opens as a TREE, two levels
    deep, with `options: [3]` collapsed; tapping that row opens the three options and tapping
    an option opens its `label`, `description` and `preview`. Then tap **Raw** — the same
    ninety lines of pretty-printed JSON that were there before, and **Copy** puts that text on
    the clipboard in either mode. Go back and open the row again: it is on the tree, because
    the mode is per-screen and is deliberately not remembered.
31. **Tap a tool call whose input the Mac CUT** (a `Bash` heredoc past 64 KB is the one shape
    observed doing it). There must be **no tree toggle at all**, the monospaced text must be
    there, and the scissors notice must still say both byte counts. A parse error where the
    content should be, or a tree drawn from a fragment, is the failure this whole path is
    shaped around. Rendered offscreen (`.superpowers/sdd/ui-renders/json/truncated-*.png`) and
    it holds; nobody has tapped it.
32. **Look at a tree with a very long string value at the largest accessibility text size.** A
    300-character `description` wraps under its key rather than clipping, and the indent — which
    is capped at five levels — has not eaten the column.

Items 33-38 are the composer, and they matter more than their position at the bottom of this
list suggests: **nobody can automate a real tap**, and this is the one feature on the phone
that ends with text going into a live terminal. Everything a test could settle about it is
settled (see `PromptComposer` under "Running the unit suite") and every one of these is
something a person passes or fails by *watching the Mac*, not by watching the phone.

33. **Type a message on the phone with the Mac's session idle.** It appears in the terminal's
    input box and submits, and the outbox row above the field disappears once the message
    comes back in the transcript. Nothing on the phone claims it landed before then — while it
    is in flight the row says "Sending…", and after the ack it says "Waiting for your Mac to
    type this", which is all an `ack` entitles anyone to say.
34. **Type a message while the session is mid-turn.** The row says "Waiting for your Mac to
    type this" and stays there; when the turn ends the text is typed and the row goes. This
    is the ordinary case, not the edge one — it is when a person reaches for their phone — and
    a composer that greyed itself out for the length of a turn would be a feature that stops
    working exactly when it is wanted. The field must stay live throughout.
35. **Type into the Mac's input box, leave the draft there, then send from the phone.** The
    draft is killed, the phone's message is submitted, and the draft is yanked back —
    unsubmitted, and character for character what it was. Nothing the user half-wrote is sent,
    and nothing is lost. This is the item that protects work nobody else can see.
36. **Open a codex session on the phone.** There is no field at all, and the line under the
    conversation says Flight Deck can only type into a Claude session from here. Nothing is
    typed into the codex TUI — **verify by watching the codex tab, not by trusting the phone**.
    Its tab holds the thread's writer lock, and the terminal route has no input box that can be
    found safely: `InputBar.read` locks onto a line beginning `❯`, which a plain shell draws
    too. Do the same for a tab sitting at a shell prompt: same absence, different sentence.
37. **Send from the phone, then quit Flight Deck before the ack.** Within fifteen seconds the
    row turns orange and says the Mac didn't confirm it. It does **not** retry — a timeout
    cannot tell "never arrived" from "arrived and the ack was lost", and a silent retry is how
    a message gets typed twice — and tapping Dismiss removes the row without sending anything.
38. **Tap Send twice as fast as you can, on a slow link.** One message reaches the agent, not
    two. The button is disabled from the first tap until the first ack lands, which is the only
    thing standing between an impatient thumb and a duplicated instruction.

39. **Open a session and read an answer without leaving it.** A `Claude` row draws the whole
    message — headings, lists, fenced code — and has **no chevron**. The tool cards above and
    below it still do. This is the item the whole change exists for, and the failure it guards
    is the one the user reported: an answer clamped to a few lines with a drill-down onto the
    same words.
40. **Long-press an answer.** Copy appears, and the clipboard holds that message. This is the
    only way to take an answer off the phone now that the row does not push a screen, and it is
    the one capability the drill-down was still carrying. **Text selection is gone with it** —
    check whether you miss it; if you do, the fix is on the row, not back in the chevron.
41. **Find an answer long enough to hit the ceiling** (120 lines in the row's column — a long
    architecture write-up does it; a pasted file in your own turn certainly does). It stops
    **mid-line**, with "Read the whole message" under the cut, and tapping the row opens the
    whole thing. A cut with no line under it, or a line under a message that was *not* cut, are
    the two ways this can be wrong.

## A second checklist: the iOS plumbing

The forty-one items above test the *feature* — that pairing, replication, resume, revocation
and now typing into a live agent behave. These fifteen test the *app*, and they are separated because they have a different
character: each one was identified during review or execution as something no amount of reading
or type-checking on the build machine could settle, and each has a specific observable outcome.
Everything reviewers *could* settle by reading has already been settled and is deliberately
absent here — a checklist that lists the answerable alongside the unanswerable is one nobody
finishes.

The camera lifecycle — items 1 and 2 — is the least-proven code on this branch, and it is
worth knowing why before deciding what to check first. That path went through three review
rounds, and each one found a real defect the previous had introduced or missed: first it never
stopped the capture session at all; then a fix that cleared the delegate raced its own
assignment; then a `deinit` fallback that could never run, because it captured `[weak self]`
and `self` is always nil by the time a deinit-scheduled block executes. None of the three
defects was catchable by anything available on this machine — not the unit suite, not
`build-ios.sh`'s type-check, nothing. `QRScannerController.stop()` and its `deinit` are the
result of that third round, and this checklist is how the fourth defect, if there is one, gets
found.

1. **Dismiss the pairing screen and watch the camera indicator go out.** The definitive test
   for the teardown path, and the single highest-value item here — see above. If the orange
   dot stays lit, the chain `dismantleUIView` → `QRScannerContainerView.teardown()` →
   `QRScannerController.stop()` → `stopRunning()` is broken somewhere along its length.
2. **Confirm `QRScannerController.deinit` actually runs** — a breakpoint or a print in a debug
   build. `AVCaptureMetadataOutput` may retain its delegate (its header declares the property
   with no ownership qualifier, so this is genuinely unknown), which would mean the controller
   never deallocates and the camera runs for the life of the process. Clearing the delegate in
   `stop()` is what is supposed to prevent that; this is how you find out whether it did.
3. **Time the pairing screen's first appearance.** `startRunning()` now runs off the main
   thread; the check is that there is no visible hitch, especially on a cold launch while the
   camera warms.
4. **The first-launch camera prompt**: it appears over the pairing screen, and granting it
   transitions to a live preview without needing a relaunch.
5. **Scan a real code from a real Mac screen**, at the distance someone would actually hold a
   phone. Nothing on the build machine can test this — a simulator has no camera — so the
   decode, the dedup-by-last-string, and the preview layer's sizing are all unexercised until
   this runs.
6. **Watch the keychain write on the first successful scan.** `KeychainPairedMacStore.save`
   traps via `assertionFailure` on any unexpected status, and a debug build on hardware
   without the right keychain entitlement will hit that the instant pairing succeeds. It is
   the first thing that runs after a scan, so it is the first thing that can fail.
7. **Adopt and unpair, and watch the root view re-route both ways.** `FlightDeckMobileApp`
   picks `PairingScreen` vs. `FleetListScreen` by reading `@Observable` state directly in a
   `Scene`'s content closure — a known-fragile spot; this is the one item flagged in review as
   plausible-but-unproven rather than merely unverified.
8. **Look at the layout.** The status glyph column lining up down the list, failure copy
   wrapping rather than truncating, and the toolbar button and confirmation dialog landing
   sensibly. (The manual-entry field no longer holds ~300 characters of base64; what to look
   for there is item 12.)
9. **Background and foreground the pairing screen.** AVFoundation's interruption handling is
   untested here and interacts with the teardown path above.

Items 10-15 are the typed path, and what is unproven there has narrowed since they were
written: `FlightDeckMobileTests` now runs the field's own rewriting and the failure-message
mapping (see "Running the unit suite"). What remains is everything a test process cannot see.
`screencapture` is denied on this machine, and no assertion on this side has ever looked at a
keyboard or at a network.

**A pixel is now reachable, though, and the earlier claim here that it was not is wrong.** The
offscreen `layer.render(in:)` technique that proved the Mac's sheet *does* transfer to the
simulator, on one condition the first attempt missed: the hosting controller's view must be in
a `UIWindow` that has been made key and visible, with a run-loop turn before the render.
`drawHierarchy(in:afterScreenUpdates:)` yields a blank image there whatever you do, which is
what the "renders blank without a window" note above was really recording.

That is how `SessionTimelineScreen` was checked at Task 4 — a real list, in a real window,
drawing "Load earlier", three monospaced rows with their disclosure chevrons, and a
"Working — 2 subagents" footer. It is deliberately not a committed test: what it proves is that
something rendered, and the assertion that would guard it is a count of collection-view cells,
which is exactly the brittle shape this file warns against. Reach for it when a screen changes
shape and you want to *look* at it, not to hold it in place.

**And it is how the Markdown work was judged.** MarkdownUI's theme was chosen against four
*real* assistant messages pulled out of this machine's own transcripts — a heading with a
bulleted list, a fenced block, a paragraph of inline code and bold, and one long unbroken
paragraph — rendered before and after in both themes at 402×874. The PNGs are in
`.superpowers/sdd/ui-renders/markdown/`. Three things only the renders could settle: that a
2em `heading1` is a banner on a phone column and had to come down to 1.28em; that the row's
height clamp cutting **mid-line** is what makes it read as "there is more below" rather than as
the end of the message; and — the one that matters most — that a screen of rendered prose sat
directly above the tool cards leaves them untouched, `** TEST FAILED **` still literal in a
result panel and a `Read`'s numbered lines still numbered lines rather than an ordered list.

**And it is how prose came out of the drill-down and onto the timeline.** The row used to cut
every message at fourteen lines' worth of height with a chevron into a screen that repeated it
word for word — and 75.7% of the 7,987 real assistant messages on this machine are shorter than
that clamp, so three times in four the chevron led to nothing new. Before and after, both
themes, five scenes drawn from real transcripts, in
`.superpowers/sdd/ui-renders/prose-full/`: a four-line reply, a heading-and-list answer, a
fenced-code answer, an answer past the ceiling, and the whole fixture conversation with prose
among the tool cards. Four things only the renders could settle:

- **The chevron had to go, and the render is the argument.** A `List` floats its disclosure
  indicator at the row's vertical centre. Unclamped, the heading-and-list answer is 970pt tall
  and the long one 2,804pt — so the chevron ends up a screenful or two from anything, pointing
  at a screen with the same words on it. Prose rows are no longer `NavigationLink`s; Copy moved
  onto the row as a long-press, since that was the only thing the detail screen still offered
  them. Rows that really do hide something — tool cards, thinking, `.prompt`, `.unknown` — keep
  both the link and the chevron.
- **A ceiling is worth having, and 120 lines is where it went.** `unbounded-light.png` is one
  real 201-line answer with nothing bounding it: 4,067pt, six screenfuls, the conversation
  nowhere in sight — and the worst case is not that answer but a 64 KB paste in a user turn,
  which is around a thousand lines. At 120 the same message still reads for four screenfuls
  before it stops. 98.8% of real assistant messages never reach it.
- **The ceiling has to say so at the cut, not at the row's centre.** With the chevron two
  screenfuls up, the only signal left was the mid-line cut. `after/very-long-*.png` is the cut
  with "Read the whole message" directly under it, legible in both themes — the dark one
  checked, because that is where this branch has already lost a control to vibrancy once.
- **The tool cards are untouched.** `after/mixed-*.png` is the whole fixture conversation:
  answers set whole in the system font, `** TEST FAILED **` still literal in a red result
  panel, a `Read`'s numbered lines still numbered lines.

Two notes on the method. The blank-render trap bit twice and both times the harness caught it
rather than a human: the screen scrolls to its newest row on the first page, so any scene whose
content passes the window height comes back an empty PNG — the fix is a canvas taller than the
content, and the guard is a check that no two of the ten PNGs are byte-identical, which is what
reported it. And the harness was deleted before the commit, as every harness on this page has
been.

**And it is how the tree and the Markdown were merged into one detail screen.** The two landed
independently and each rewrote the same block, so what had to be looked at was not either
feature but the seam: that the three ways a body is drawn stay mutually exclusive and that the
grey panel goes exactly where it belongs. Six screens in both themes at 402×874 —
`.superpowers/sdd/ui-renders/merged/` — a heading-and-list answer and a fenced-code answer
(Markdown, no outer panel, the fence's own fill standing off the page in BOTH themes), an
`AskUserQuestion` input as a tree and the same body switched to Raw (`showsRaw:` exists for
this: there is nothing to tap in a `layer.render(in:)` pass), a cut 64 KB `Read` with no toggle
and its scissors notice intact, and a `Bash` call whose JSON input is a tree directly above a
result that is not JSON and is therefore monospaced text. That last one is the whole merge in a
single screen.

**And it is how the composer's surface was settled — by finding a defect that only exists in
the dark.** Six states in both themes at 402×874, in `.superpowers/sdd/ui-renders/composer/`:
an empty field on a live claude session, a typed draft with Send enabled, a message in flight,
one accepted and waiting on the Mac, a failed one with its reason and its Dismiss, and a codex
session showing the sentence and no field. The first construction was `.background(.bar)`, and
the light render looked fine. The dark one was the evidence: a `Material` background makes
SwiftUI blend `.secondary` content over it **vibrantly**, and the outbox row's own message text
and the Send glyph both went to invisible against black — three of the dark PNGs came back
byte-identical, which is what a state that draws nothing looks like. A `Divider` over
`systemBackground`, and a two-layer `.palette` Send glyph with the arrow punched out in the
page's colour, is what replaced it; it also gave the bar the top edge it never had in *either*
theme, since a `.plain` list and a bar material are the same colour. Two caveats on the method:
the seeded-draft states are rendered against a rebuilt mount rather than the real screen —
there is nothing to type into in a `layer.render(in:)` pass, which is what `PromptComposer`'s
`draft:` parameter is for, exactly as `TimelineBodyBlock.showsRaw` is — and the harness was
deleted before the commit, as every harness on this page has been.

**It is also how the timeline's design was chosen**, rather than argued. Three whole screens —
a dense monospaced transcript, a chat thread, and the structured feed that shipped — were built
against one fixture conversation holding a real `Bash` call with multi-line output, a long
assistant message, a thinking block, a 64 KB truncated file read, a failed command and an
`.unknown` kind, and rendered in both themes at 402×874. The renders settled two things reading
the code did not: monospaced prose fits about 38 characters to the line on a phone and turns a
long answer into a grey wall, and a `.toolResult` rendered through the command slot showed the
*first line* of that 64 KB read and dropped the rest. The PNGs are in
`.superpowers/sdd/ui-renders/`. Two traps, both cost a round of confusion:

- **A programmatic `scrollTo` renders BLANK offscreen.** Every target tried — a 1pt trailing
  sentinel, an 8pt one, the last row's own id — produced the same empty PNG, with and without a
  `CATransaction.flush()`. `layer.render(in:)` does not see a scrolled `List`. This is a limit
  of the technique, not a bug in the screen: the same scroll captured through
  `xcrun simctl io <udid> screenshot` shows it working (that grab is
  `ui-renders/verify-opens-on-newest.png`).
- **For a framebuffer grab, the window must be attached to the app's `UIWindowScene`** and sit
  above the host's own window (`windowLevel = .alert + 100`). A `UIWindow(frame:)` in a
  scene-based app belongs to no scene and is never composited — the screenshot comes back
  showing `PairingScreen` instead, which is the host app underneath. The camera prompt in that
  grab is the host app's pairing screen behind the harness window; it is not part of the
  design.

10. **Type with a hardware keyboard, and paste a lowercase code.** Both come out
    `XXXX-XXXX-XXXX` in uppercase, with `O` read as `0` and `I`/`L` as `1`. The rewrite itself
    is now covered — `TypedCodeFieldTests.testTypingIsUppercasedGroupedAndDisambiguatedAsItGoes`
    runs exactly that string — so what this item still tests is the wiring around it: that
    `.onChange` fires for a paste and for a hardware keyboard at all.
    `.textInputAutocapitalization(.characters)` is only a hint to the *software* keyboard and
    unobservable from a test either way, and `.autocorrectionDisabled()` is the other half:
    twelve arbitrary symbols are exactly the shape autocorrect turns into a word, and a field
    that quietly "corrects" one produces a checksum failure whose cause is invisible.
11. **Insert a character into the middle of a complete code and watch the caret.** The
    `.onChange` handler reassigns `field.text` on almost every keystroke, and SwiftUI moves the
    insertion point to the end of the string when `text` is reassigned — so a mid-string
    correction may strand the caret at the end and scatter the rest of the fix. The re-entrancy
    guard is the other half of that line: `TypedCodeField.reformat()`'s `if formatted != text`
    is what stops the rewrite re-firing itself, and a loop shows up as a field that freezes or
    eats every second keystroke, not as a crash. That guard is *unfalsifiable* by a unit test —
    removing it produces the identical string, and it only loops once SwiftUI re-fires
    `.onChange` — which is why a test for it was written and then cut.
12. **Look at the pairing screen on the smallest phone you have.** Three outcomes, none
    observed: the typed-code section sits below the square QR without the screen scrolling or
    the QR being squeezed; the Pair button reads as *disabled* until a full-length code is in
    (the *rule* is covered by
    `TypedCodeFieldTests.testThePairButtonEnablesOnTwelveSymbolsEvenWhenTheChecksumFails`; what
    is unseen is whether the disabled state reads as disabled); and a failure message renders
    in the red slot and
    **wraps** rather than truncating, which is what
    `.fixedSize(horizontal: false, vertical: true)` is there for.
13. **Burn a Mac's three attempts, then type its code once more and read the message.**
    `.wrongCode` says check what you typed; `.attemptsExhausted` says show a new code on the
    Mac. Those send the user in opposite directions, and swapping them spends one of three
    tries teaching them nothing. `FleetModel.message(for:)`'s mapping is now asserted by
    running (`FleetModelTests`), so what this item adds is the half a test cannot reach: that
    the Mac really reports `.attemptsExhausted` at the third failure and that the right string
    arrives on the right screen.
14. **Double-tap Pair, and unpair while a search is running.** `pair(code:)` opens with
    `runner?.cancel()` and `unpair()` cancels and drops the runner. Without both, an orphaned
    `PairingRunner` keeps walking its candidate list and can complete a pairing the user has
    already moved on from — which presents as the app pairing itself to a Mac nobody chose.
    Neither the compiler nor the unit suite covers it, and a regression is silent.
15. **Watch a real `_flightdeck-pair._tcp` browse from the phone**, including the local-network
    permission prompt on first use. `PairingRunner`'s candidate walk is covered against real
    sockets on macOS; the browse has never run on iOS, where that prompt is a gate the Mac side
    does not have. Note what a declined prompt looks like: no results, so `.noMacsFound`, so
    "Can't find that Mac on this network. Scan the QR code instead." — the same message an
    unarmed Mac produces. If this checklist ever finds a user stuck there, the prompt is the
    first thing to check, not the code.

## The one item on the Mac

**Open Settings → Devices → Pair a Device and look at the sheet in a real Preferences window.**
The sheet asks for **596pt on a 560pt window**. That was measured, not guessed, and it does not
clip: rendered offscreen onto the Preferences window's real 720×560 geometry, AppKit reports
`sheet=(360.0, 596.0)` and draws the Cancel button and the "Only works on this Wi-Fi network."
caption in full, and a deliberately overlong 629pt sheet came back at its full height too. So
the observable outcome here is not "is anything missing" — it is whether a sheet overhanging its
parent by 36pt reads as deliberate or as broken. Nobody has seen it in a real window, only in a
bitmap. The cheapest 40pt, if it reads badly, is the QR at 200pt rather than 240 — which is
also the 40pt the QR work was spent making scannable, so shrink it knowingly.

## The cross-process check, and exactly what it proves

**Run a pairing from a real `FlightDeckMobile` (simulator or device) against a real Flight
Deck on the Mac, using the typed code.** Both apps built from this tree, two processes, a real
network. It is an acceptance criterion for the pairing work, not a unit test — and it stays one
now that `FlightDeckMobileTests` exists, because what it checks is two *processes* agreeing, and
a unit test is one process with no wire in it.

**What it catches: caller-side asymmetry.** The two ends disagreeing about which of them is
the SPAKE2 initiator, about the two names they pass to `SPAKE2Session`, or about the order in
which they assemble the transcript. Those are decisions made in `PairingListener.handle` and
`PairingInitiator.start` — one file each, written by different hands at different times — and
a disagreement in any of them produces confirmations that never match. The Mac then reports
"wrong code" for a correctly typed one and spends an attempt saying so, three times, until the
user is locked out with every log line insisting they made a typo. A cross-process run is a
real check on that.

**What it does NOT catch: a consistent role or name swap inside `SPAKE2Session`.** Both ends
compile the same `FleetKit`, so a swap applied in the wrapper is applied identically on both
sides of the wire and survives a cross-process test exactly as it survives an in-process one.
This was demonstrated rather than argued: two mutants — roles swapped, and the two name
arguments swapped — each passed all seventeen SPAKE2 and `PairingSecrets` tests.

What closes *that* is a second implementation of the **caller**, not a second process.
`SPAKE2SessionTests.testTheWrapperAgreesWithTheRawCAPIAboutRoleAndNameOrder` drives one side
through BoringSSL's raw C API with a literal `spake2_role_alice` and the argument order
`curve25519.h` declares, the other through `SPAKE2Session`, and requires the derived keys to
agree. Both mutants fail it. That is in place, in process, and it is the check that matters
for the wrapper. `docs/FOLLOWUPS.md`'s "Pairing crypto foundation" entry previously claimed
the cross-process run was what closed this gap; that was wrong and is corrected there. Do not
reintroduce the stronger claim here.

**Status: not run.** The phone's own logic is executed now (see "Running the unit suite"), but
nothing on this page is: every checklist item above, and this one, needs a screen, a camera, a
keyboard or a network, and none of those exist in a test process. This item is the one meant to
stop being unrun first.

## The trust model, restated

A code on an unlocked Mac — a QR, or twelve characters typed — a 2-minute window, single use,
and a paired phone is fully privileged until revoked. There is no separate login or permission
tier on top of the TLS-PSK handshake — pairing *is* authorization, in full, forever, until the
Mac deletes that device's slot.

The typed path adds SPAKE2 and a three-guess limit, and adds them for one purpose: to make 55
bits safe to put on a wire. It does not raise this boundary. Anyone who can read the code off
the screen can pair, on either path, which is the same sentence as before.
