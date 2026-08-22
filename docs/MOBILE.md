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
./scripts/test-ios.sh    # 16 tests, ~25s including creating and booting the simulator
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

## A second checklist: the iOS plumbing

The fifteen items above test the *feature* — that pairing, replication, resume and revocation
behave. These fifteen test the *app*, and they are separated because they have a different
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
`UIHostingController` renders blank without a window, so the offscreen `layer.render(in:)`
technique that proved the Mac's sheet does not transfer, and `screencapture` is denied on this
machine — so no assertion on this side has ever looked at a pixel, at a keyboard, or at a
network.

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
