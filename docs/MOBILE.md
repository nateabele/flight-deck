# Flight Deck — the phone companion

`FlightDeckMobile` is the iOS client for the fleet the Mac replicates over `FleetKit` (see the
"Fleet replication" section of [ARCHITECTURE.md](ARCHITECTURE.md)). This doc is what only a
device on a network can prove, plus how to get a build onto one. Nothing here has been run —
installing on hardware needs a development team and a provisioning profile this build machine
does not have, and setting that up is the user's decision, not this branch's.

## Running it at all

Neither is configured in this repo, deliberately:

- **Install an iOS Simulator runtime** (Xcode → Settings → Components, or `xcodebuild
  -downloadPlatform iOS`), then `xcodebuild -project FlightDeck.xcodeproj -scheme
  FlightDeckMobile -sdk iphonesimulator build`. A simulator has no camera, so pairing by
  scanning is unavailable there — pairing by typing the code (checklist item 2) is not a
  fallback for this case, it is the *only* route that works on a simulator at all.
- **Or set `DEVELOPMENT_TEAM` and a bundle id you own**, then build for `-sdk iphoneos` and
  install on hardware. Neither is hard-coded into `project.yml`: this build machine has no
  provisioning profile to build against, and a real team id checked into a shared repo is a
  merge conflict waiting to happen the moment a second person's Apple ID touches it.

`./scripts/build-ios.sh` does neither of these — it type-checks the app's sources against a
freshly built `FleetKitiOS.framework` with no destination and no signing at all. See its own
comments for why, and the note in `AGENTS.md`.

## The manual checklist

Each item is stated as an observable outcome, not "check it looks right". None of these are
run by anything on this machine.

1. Pair by scanning; the Mac's Devices tab shows the phone as Connected.
2. Pair by typing the code instead of scanning; same outcome. This is not a lesser path — it
   is what a user falls back to when they decline the camera, and it is the only pairing route
   that works at all on a simulator.
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

## A second checklist: the iOS plumbing

The twelve items above test the *feature* — that pairing, replication, resume and revocation
behave. These nine test the *app*, and they are separated because they have a different
character: each one was identified during review as something no amount of reading or
type-checking on the build machine could settle, and each has a specific observable outcome.
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
8. **Look at the layout.** The status glyph column lining up down the list, a ~300-character
   base64 code in the manual-entry field, failure copy wrapping rather than truncating, and
   the toolbar button and confirmation dialog landing sensibly.
9. **Background and foreground the pairing screen.** AVFoundation's interruption handling is
   untested here and interacts with the teardown path above.

## The trust model, restated

A QR on an unlocked Mac, a 2-minute window, single use, and a paired phone is fully privileged
until revoked. There is no separate login or permission tier on top of the TLS-PSK handshake —
pairing *is* authorization, in full, forever, until the Mac deletes that device's slot.
