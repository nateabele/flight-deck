# Debug-build identity isolation — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop a Debug build of Flight Deck from being the same app identity as the installed Release build, so it cannot share paired-device secrets, advertise as the same fleet, or rewrite the real fleet's session state.

**Architecture:** Give the Debug configuration its own `PRODUCT_BUNDLE_IDENTIFIER` on both targets. Everything identity-derived then namespaces itself with no further code — the `UserDefaults` domain (and so `preferences.v1`, `pairedDevices`, `installID`, the remembered port), the derived Bonjour *instance* name, the macOS local-network grant, and the iOS Keychain item. Separately, salt `sessions.json`'s directory by build configuration, because bundle id does not namespace file paths.

**Tech Stack:** Swift 6 / macOS + iOS, XcodeGen (`project.yml`, no SwiftPM), XCTest, bash scripts.

**Spec:** `docs/superpowers/specs/2026-09-21-debug-build-identity-isolation-design.md` — read it first.

## Global Constraints

- **Bonjour service TYPES must not change.** `PairingChannel.bonjourType` is `_flightdeck-pair._tcp` — exactly 15 characters, RFC 6763's maximum service label. A suffixed variant fails registration **silently**. Isolation is by *instance* name only, which falls out of a separate `installID`.
- **`Sources/FlightDeckMobile/Info.plist`'s `NSBonjourServices` must not change**, for the same reason — and the repo has no precedent for a per-configuration plist value.
- **Release identifiers are exactly `dev.flightdeck.FlightDeck` and `dev.flightdeck.FlightDeckMobile`.** State them explicitly rather than leaving them to xcodegen's `bundleIdPrefix` derivation.
- **Tests are XCTest**, flat in `Tests/FlightDeckTests/`, `@testable import FlightDeck`, `@MainActor` where the type under test is.
- **`./scripts/test-unit.sh` silently ignores `-only-testing:`** and runs the whole macOS suite (~2760 tests, ~100s). Run it in the FOREGROUND. Touching `Sources/FlightDeckMobile` or its plist also requires `./scripts/test-ios.sh`.
- **This checkout is shared with other sessions.** Never `git add -A`; stage only the files a task names. Never revert or stash other work.
- Commit trailer: `Co-Authored-By: Claude Opus 5 (1M context) <noreply@anthropic.com>`

---

## Assumptions this plan rests on

Every one is spiked before the plan is presented; findings are recorded in
"Spike results" at the bottom and any that fail rewrite the affected task.

| # | Assumption | Task at risk |
|---|---|---|
| A1 | xcodegen emits per-configuration `PRODUCT_BUNDLE_IDENTIFIER` from a target's own `settings.configs` block | 1 |
| A2 | A different bundle id gives a different `UserDefaults` domain, so `preferences.v1` (and `pairedDevices`, `installID`, remembered port) separates | 1 |
| A3 | `FleetService.derivedServiceName` varies with `installID`, so a separate domain yields a distinct Bonjour *instance* name | 2 |
| A4 | `FleetConnector` filters discovered services by instance name, so a phone can distinguish two Macs | 2 |
| A5 | The iOS Keychain item (`dev.flightdeck.pairedMac`) namespaces by bundle id via the default access group | 3 |
| A6 | `FileSessionPersistence.defaultDirectory()` is a literal path with no build salt, and `SessionDaemon.defaultDirectory(debug:)` is the pattern to copy | 4 |
| A7 | Nothing else in `Sources/` hardcodes `dev.flightdeck.FlightDeck` in a way a rename breaks | 1, 5 |
| A8 | `scripts/answer-trigger.sh` and `scripts/deploy-phone.sh` are the only scripts that hardcode a bundle id | 5, 6 |

**Spiked 2026-09-24 — A8 was refuted and added Task 5. See "Spike results" at the bottom
before executing; two tasks were corrected by what the spikes found.**

---

### Task 1: Per-configuration bundle identifiers

**Files:**
- Modify: `project.yml` (targets `FlightDeck`, `FlightDeckMobile`)
- Test: `Tests/FlightDeckTests/BundleIdentityTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: a Debug build whose `Bundle.main.bundleIdentifier` differs from Release's; Release pinned to `dev.flightdeck.FlightDeck`.

- [ ] **Step 1: Write the failing test**

`Tests/FlightDeckTests/BundleIdentityTests.swift`:

```swift
import XCTest
@testable import FlightDeck

/// Pins the shipping identifier so a future edit cannot silently rename the app the
/// user has already granted local-network and TCC permission to — those grants key on
/// the designated requirement, so a rename revokes them without any visible error.
final class BundleIdentityTests: XCTestCase {
    /// The app bundle, not the test runner: under `scripts/test-unit.sh` the tests are
    /// hosted by `Flight Deck.app`, so its identifier is what we can see from here.
    private func appBundleIdentifier() throws -> String {
        let id = Bundle(for: SessionStore.self).bundleIdentifier
        return try XCTUnwrap(id, "the app bundle must carry an identifier")
    }

    func testDebugAndReleaseDoNotShareAnIdentifier() throws {
        let id = try appBundleIdentifier()
        #if DEBUG
        XCTAssertEqual(id, "dev.flightdeck.FlightDeck.debug")
        #else
        XCTAssertEqual(id, "dev.flightdeck.FlightDeck")
        #endif
    }

    /// The whole design rests on this: a different identifier is what separates the
    /// UserDefaults domain, and with it `preferences.v1` and every paired device key.
    func testTheIdentifierIsWhatNamesTheDefaultsDomain() throws {
        let id = try appBundleIdentifier()
        XCTAssertNotNil(
            UserDefaults(suiteName: id),
            "a domain must be addressable by the identifier the build actually carries"
        )
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: FAIL — Debug currently reports `dev.flightdeck.FlightDeck`, not `…debug`.

- [ ] **Step 3: Add the per-configuration identifiers**

In `project.yml`, on the **FlightDeck** target's `settings:`:

```yaml
    settings:
      configs:
        Debug:
          PRODUCT_BUNDLE_IDENTIFIER: dev.flightdeck.FlightDeck.debug
        Release:
          PRODUCT_BUNDLE_IDENTIFIER: dev.flightdeck.FlightDeck
```

And on **FlightDeckMobile** (which today sets `PRODUCT_BUNDLE_IDENTIFIER: dev.flightdeck.FlightDeckMobile` unconditionally — replace that line):

```yaml
    settings:
      configs:
        Debug:
          PRODUCT_BUNDLE_IDENTIFIER: dev.flightdeck.FlightDeckMobile.debug
        Release:
          PRODUCT_BUNDLE_IDENTIFIER: dev.flightdeck.FlightDeckMobile
```

Preserve every other setting on both targets — in particular `FlightDeckMobile`'s `DEVELOPMENT_TEAM[sdk=iphoneos*]` and `CODE_SIGN_IDENTITY[sdk=iphonesimulator*]`, which are `[sdk=…]`-conditional and unrelated to configuration.

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test-unit.sh`
Expected: PASS. `test-unit.sh` runs `xcodegen generate` itself, so no extra step.

- [ ] **Step 5: Commit**

```bash
git add project.yml Tests/FlightDeckTests/BundleIdentityTests.swift
git commit -m "Give Debug builds their own bundle identifier"
```

---

### Task 2: Prove the fleet identity actually separates

**Files:**
- Test: `Tests/FlightDeckTests/FleetIdentityIsolationTests.swift`

**Interfaces:**
- Consumes: Task 1's separate identifiers.
- Produces: nothing — this task is proof, not mechanism.

This task adds no production code. It exists because the *entire* design rests on a chain nobody has asserted: separate identifier → separate defaults domain → separate `installID` → distinct Bonjour instance name → a phone can tell the two Macs apart. If any link is only true by accident, that must fail here rather than in a pairing session.

- [ ] **Step 1: Write the failing test**

`Tests/FlightDeckTests/FleetIdentityIsolationTests.swift`:

```swift
import XCTest
@testable import FlightDeck

/// The chain the isolation design depends on, asserted end to end.
@MainActor
final class FleetIdentityIsolationTests: XCTestCase {
    private final class MemoryPersistence: PreferencesPersisting {
        var stored: Preferences?
        func load() -> Preferences? { stored }
        func save(_ preferences: Preferences) { stored = preferences }
    }

    /// Two stores with independent persistence stand in for two builds with
    /// independent `UserDefaults` domains — which is exactly what a separate bundle
    /// identifier produces.
    func testTwoIndependentDomainsMintDifferentInstallIDs() {
        let a = PreferencesStore(persistence: MemoryPersistence())
        let b = PreferencesStore(persistence: MemoryPersistence())
        XCTAssertNotEqual(
            a.installSuffix, b.installSuffix,
            "installID is minted per domain; equal suffixes would mean two builds "
                + "advertise the same Bonjour instance name and a phone cannot tell them apart"
        )
    }

    func testADifferentInstallSuffixYieldsADifferentServiceName() {
        let a = PreferencesStore(persistence: MemoryPersistence())
        let b = PreferencesStore(persistence: MemoryPersistence())
        XCTAssertNotEqual(
            FleetService.derivedServiceNameForTesting(preferences: a),
            FleetService.derivedServiceNameForTesting(preferences: b),
            "the advertised instance name is the only thing distinguishing two Macs; "
                + "the service TYPE is deliberately shared"
        )
    }

    /// Guards the constraint that makes instance-name isolation necessary in the first
    /// place: the pairing service label is at RFC 6763's 15-character maximum, so a
    /// suffixed TYPE would fail Bonjour registration silently.
    func testThePairingServiceLabelIsStillAtItsLimit() {
        let label = PairingChannel.bonjourType
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ".tcp", with: "")
        XCTAssertLessThanOrEqual(label.count, 15, "RFC 6763 caps a service label at 15")
        XCTAssertEqual(PairingChannel.bonjourType, "_flightdeck-pair._tcp")
        XCTAssertEqual(FleetSocketServer.bonjourType, "_flightdeck._tcp")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: FAIL — `derivedServiceNameForTesting` does not exist yet.

- [ ] **Step 3: Expose the derivation as a test seam**

`FleetService.derivedServiceName` is `private static`. Add a seam beside it, mirroring the `…ForTesting` convention already used ~20 times in `SessionStore`:

```swift
    /// The advertised instance name, for tests that must prove two builds differ.
    /// A pure read of the same derivation production uses — no second expression to drift.
    static func derivedServiceNameForTesting(preferences: PreferencesStore) -> String {
        derivedServiceName(preferences: preferences)
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test-unit.sh`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/Fleet/FleetService.swift Tests/FlightDeckTests/FleetIdentityIsolationTests.swift
git commit -m "Assert the identity chain the fleet isolation rests on"
```

---

### Task 3: The iOS side

**Files:**
- Modify: `scripts/deploy-phone.sh`
- Test: `Tests/FlightDeckMobileTests/PairedMacStoreIsolationTests.swift`

**Interfaces:**
- Consumes: Task 1's `FlightDeckMobile` identifiers.
- Produces: a `deploy-phone.sh` that installs the right identifier for the configuration it built.

The phone's Keychain item namespaces itself by the app's default access group, which derives from the bundle id — so Task 1 already separates it. What still needs doing is the script that installs and launches by a hardcoded id.

- [ ] **Step 1: Write the failing test**

`Tests/FlightDeckMobileTests/PairedMacStoreIsolationTests.swift`:

```swift
import XCTest
@testable import FlightDeckMobile

/// The phone keeps exactly one `PairedMac`, at Keychain service
/// `dev.flightdeck.pairedMac`, account `"primary"`. One installed app therefore pairs
/// with one Mac — which is why the debug app needs its own bundle id, so pairing it to
/// a debug Mac does not destroy the release app's pairing to the real one.
final class PairedMacStoreIsolationTests: XCTestCase {
    func testTheKeychainCoordinatesAreNotBuildDependent() {
        XCTAssertEqual(KeychainPairedMacStore.serviceForTesting, "dev.flightdeck.pairedMac")
        XCTAssertEqual(KeychainPairedMacStore.accountForTesting, "primary")
    }

    /// Separation comes from the ACCESS GROUP, which derives from the bundle id — not
    /// from these coordinates. Asserting they are constant is what proves the isolation
    /// story is "two apps", not "two keys in one app".
    func testTheAppIdentifierIsWhatSeparatesTheItem() {
        let id = Bundle(for: FleetModel.self).bundleIdentifier
        #if DEBUG
        XCTAssertEqual(id, "dev.flightdeck.FlightDeckMobile.debug")
        #else
        XCTAssertEqual(id, "dev.flightdeck.FlightDeckMobile")
        #endif
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test-ios.sh`
Expected: FAIL — the seams do not exist, and Debug still reports the Release id.

- [ ] **Step 3: Add the seams**

In `Sources/FleetKit/PairedMacStore.swift`, beside the existing private constants:

```swift
    /// Exposed so the phone's suite can assert these coordinates are build-independent —
    /// the isolation comes from the access group, not from these strings.
    static var serviceForTesting: String { service }
    static var accountForTesting: String { account }
```

- [ ] **Step 4: Teach `deploy-phone.sh` the configuration**

`scripts/deploy-phone.sh` hardcodes `BUNDLE_ID=dev.flightdeck.FlightDeckMobile`. It already knows whether it is building `--release`; derive the id from that same decision rather than adding a second source of truth:

The script's configuration variable is **`CONFIG`** (spiked: set to `Release` by `--release`, Debug otherwise). Replace line 18's unconditional assignment with:

```bash
# The debug build is a DIFFERENT APP with a different identifier — see
# docs/superpowers/specs/2026-09-21-debug-build-identity-isolation-design.md.
# Installing a debug build under the release id would replace the real app.
if [ "$CONFIG" = "Release" ]; then
  BUNDLE_ID="dev.flightdeck.FlightDeckMobile"
else
  BUNDLE_ID="dev.flightdeck.FlightDeckMobile.debug"
fi
```

Place it after `CONFIG` is resolved from the arguments, not at line 18 where `CONFIG` may not be set yet — check the ordering before moving it.

- [ ] **Step 5: Run to verify it passes**

Run: `./scripts/test-ios.sh`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/FleetKit/PairedMacStore.swift Tests/FlightDeckMobileTests/PairedMacStoreIsolationTests.swift scripts/deploy-phone.sh
git commit -m "Separate the phone's debug identity and teach deploy-phone which one it built"
```

---

### Task 4: Salt `sessions.json` by build configuration

**Files:**
- Modify: `Sources/FlightDeck/SessionPersistence.swift` (`FileSessionPersistence.defaultDirectory()`, ~line 239)
- Test: `Tests/FlightDeckTests/SessionPersistenceDirectoryTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `FileSessionPersistence.defaultDirectory(debug:)` — an injectable seam defaulting to the build's own answer.

Bundle id does not namespace file paths, so Task 1 leaves `sessions.json` shared. A debug build rewriting the real fleet's session state is a worse collision than the pairing one. `SessionDaemon.defaultDirectory(debug:)` is the established pattern — copy its shape exactly.

- [ ] **Step 1: Write the failing test**

`Tests/FlightDeckTests/SessionPersistenceDirectoryTests.swift`:

```swift
import XCTest
@testable import FlightDeck

/// A debug build must not read or write the installed app's `sessions.json`. Bundle id
/// namespaces defaults and keychains, but not file paths — so this one is salted by
/// hand, the same way `SessionDaemon.defaultDirectory(debug:)` already is.
final class SessionPersistenceDirectoryTests: XCTestCase {
    func testDebugAndReleaseResolveDifferentDirectories() {
        XCTAssertNotEqual(
            FileSessionPersistence.defaultDirectory(debug: true).path,
            FileSessionPersistence.defaultDirectory(debug: false).path
        )
    }

    /// The release path is the one the installed app has been using all along; changing
    /// it would strand every existing session.
    func testTheReleaseDirectoryIsUnchanged() {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        XCTAssertEqual(
            FileSessionPersistence.defaultDirectory(debug: false).path,
            base.appendingPathComponent("Flight Deck").path
        )
    }

    func testTheDebugDirectoryIsDistinctAndNamed() {
        let path = FileSessionPersistence.defaultDirectory(debug: true).path
        XCTAssertTrue(path.hasSuffix("Flight Deck (Debug)"), "got \(path)")
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `./scripts/test-unit.sh`
Expected: FAIL — `defaultDirectory` takes no argument.

- [ ] **Step 3: Add the salt**

In `SessionPersistence.swift`, replacing the current no-argument form:

```swift
    /// True in a Debug build, false in Release — the `-D DEBUG` flag the Debug
    /// configuration compiles with. Exposed as a value (not just `#if`) so
    /// `defaultDirectory(debug:)` can be exercised for both builds from a single test
    /// run. Same shape as `SessionDaemon.isDebugBuild`, deliberately.
    #if DEBUG
    static let isDebugBuild = true
    #else
    static let isDebugBuild = false
    #endif

    /// Salted by configuration: a debug build must not read or write the installed
    /// app's session state. Bundle id namespaces the defaults domain and the keychain
    /// but not file paths, so this one is salted by hand. `-FlightDeckStateDir` still
    /// overrides it — see `FlightDeckApp.stateDirectory()`.
    static func defaultDirectory(debug: Bool = isDebugBuild) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        // "Flight Deck" (two words) matches the product name on disk, as in `Flight Deck.app`.
        return base.appendingPathComponent(
            debug ? "Flight Deck (Debug)" : "Flight Deck", isDirectory: true
        )
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `./scripts/test-unit.sh`
Expected: PASS, and the whole suite green — every existing caller uses the defaulted form.

- [ ] **Step 5: Commit**

```bash
git add Sources/FlightDeck/SessionPersistence.swift Tests/FlightDeckTests/SessionPersistenceDirectoryTests.swift
git commit -m "Salt sessions.json by build configuration"
```

---

### Task 5: The scripts that reset the wrong app

**Files:**
- Modify: `scripts/smoke.sh:32,34`
- Modify: `scripts/screenshot.sh:47`

**Interfaces:**
- Consumes: Task 1's identifiers.
- Produces: GUI scripts that reset the build they actually drive.

**This task is a correctness fix, not housekeeping — the spike found it.** `smoke.sh`
builds and launches the **Debug** app (`…/Build/Products/Debug/FlightDeck.app`) but
resets window geometry in the **Release** domain:

```bash
defaults delete dev.flightdeck.FlightDeck "$key"
rm -rf ~/Library/Saved\ Application\ State/dev.flightdeck.FlightDeck.savedState
```

Before this plan that was harmless — one identity. After Task 1 it breaks both ways: the
app under test keeps its stale window frames (so a UITest asserting on layout inherits
whatever the last run left, which is exactly the flake class `AGENTS.md` warns about), and
the *installed* app the user is running has its window state deleted underneath it.
`screenshot.sh:47` has the identical line.

- [ ] **Step 1: Point both scripts at the Debug domain**

In `scripts/smoke.sh`, replace the hardcoded domain in the `for key` loop and the
saved-state removal:

```bash
# The Debug build is a separate app identity (2026-09-24) — resetting
# dev.flightdeck.FlightDeck here would leave the app under test with stale window
# frames AND delete the installed app's window state. Reset the one we launch.
APP_DOMAIN="dev.flightdeck.FlightDeck.debug"
for key in \
  "NSWindow Frame main" \
  "NSWindow Frame com_apple_SwiftUI_Settings_window" \
  "NSSplitView Subview Frames main, SidebarNavigationSplitView"
do
  defaults delete "$APP_DOMAIN" "$key" 2>/dev/null || true
done
rm -rf ~/Library/Saved\ Application\ State/"$APP_DOMAIN".savedState 2>/dev/null || true
```

Apply the same substitution at `scripts/screenshot.sh:47`. Read each script first to
confirm which configuration it actually builds — if either drives Release, it keeps the
Release domain and gets a comment saying so.

- [ ] **Step 2: Verify by inspection, not by running**

Do **not** run `./scripts/smoke.sh` to check this. It seizes the foreground for ~70s and
captures the operator's keystrokes as phantom test failures; it is throttled to one run
per 120s deliberately. Confirm instead that no `dev.flightdeck.FlightDeck` literal remains
in either script except in a comment explaining the split:

```bash
rg -n 'dev\.flightdeck\.FlightDeck\b' scripts/smoke.sh scripts/screenshot.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/smoke.sh scripts/screenshot.sh
git commit -m "Reset the app the GUI scripts actually launch, not the installed one"
```

---

### Task 6: Scripts and docs catch up

**Files:**
- Modify: `scripts/answer-trigger.sh`
- Modify: `docs/ARCHITECTURE.md`, `docs/FOLLOWUPS.md`

**Interfaces:**
- Consumes: Tasks 1, 4 and 5.
- Produces: nothing code-facing.

- [ ] **Step 1: Teach `answer-trigger.sh` which domain**

Its header instructs `defaults write dev.flightdeck.FlightDeck FlightDeckAnswerTrigger -bool YES`. That now enables the trigger for the *Release* app only. Document both, so someone enabling it for a debug run does not silently enable it for the installed app instead:

```bash
#   # Release (the installed app):
#   defaults write dev.flightdeck.FlightDeck FlightDeckAnswerTrigger -bool YES
#   # Debug (a locally-built app — a DIFFERENT identity since 2026-09-24):
#   defaults write dev.flightdeck.FlightDeck.debug FlightDeckAnswerTrigger -bool YES
```

Also note in the same block that the socket path follows `-FlightDeckStateDir`, and that a debug build's default state directory is now `Flight Deck (Debug)` — so the socket a debug run opens is not the one a bare `answer-trigger.sh` finds.

- [ ] **Step 2: Update the architecture doc**

Add a short subsection under the fleet/pairing material recording: Debug and Release are separate app identities; what that separates (defaults domain, `preferences.v1`, `pairedDevices`, `installID`, the derived Bonjour instance name, the iOS Keychain item, the local-network grant); what it does **not** separate (file paths — hence the `sessions.json` salt, and logs, deliberately shared); and that the Bonjour service *types* are identical by design because the pairing label is at RFC 6763's limit.

- [ ] **Step 3: Update FOLLOWUPS**

The existing entry says a debug build "already reads and writes the same `sessions.json` as the real installed app … for the identical reason (no salting)". That is now false. Rewrite it to record what this change fixed and what it did not: logs remain shared, and a debug build still starts with no paired devices by design.

- [ ] **Step 4: Run the suites**

Run: `./scripts/test-unit.sh` then `./scripts/test-ios.sh`
Expected: both green.

- [ ] **Step 5: Commit**

```bash
git add scripts/answer-trigger.sh docs/ARCHITECTURE.md docs/FOLLOWUPS.md
git commit -m "Record the debug identity split in the scripts and docs that assumed one app"
```

---

## Verification

Automated (no GUI, no phone): Tasks 1–4's tests, plus the full macOS and iOS suites.

Needs a person, and cannot be automated — recorded as a checklist:

1. Build Debug, launch it alongside the installed Release app. Confirm the phone's Mac list shows **two** entries.
2. Pair the debug phone app with the debug Mac. Afterwards confirm the release phone app is still paired to the release Mac.
3. Confirm `~/Library/Application Support/Flight Deck (Debug)/sessions.json` exists and the Release one is untouched.
4. Confirm a **second** local-network permission prompt appeared on first debug launch — its absence would mean the grant was inherited, i.e. the identities did not actually separate.

## Spike results

Run 2026-09-24, before this plan was presented. Seven assumptions held; **one was
refuted and added a task**; one bonus finding.

| # | Verdict | Evidence |
|---|---|---|
| A1 | **holds** | xcodegen emits both values from a target's own `settings.configs` block, no top-level `configs:` needed — confirmed against a throwaway project; both reached the generated `pbxproj`. |
| A2 | **holds** | `UserDefaultsPreferencesPersistence.init(defaults: UserDefaults = .standard)` (`PreferencesStore.swift:20`). `.standard` resolves to the app's own bundle-id domain, so `preferences.v1` follows the identifier. This is the linchpin and it is solid. |
| A3 | **holds** | `derivedServiceName` is `"\(hostname)-\(preferences.installSuffix)"` (`FleetService.swift:325`); `installSuffix` is the first 4 of `installID`, minted on first launch in a domain and persisted on that same launch (`PreferencesStore.swift:96-99`). A new domain therefore mints a new suffix. |
| A4 | **holds** | `FleetConnector.swift:520` filters discovered services on `name == self.mac.serviceName`. Instance name is genuinely the discriminator. |
| A5 | **holds, with a caveat** | No `kSecAttrAccessGroup` is set anywhere, so the item takes the default group from the signing identity — which follows the bundle id. **Caveat:** simulator builds are ad-hoc signed (`CODE_SIGN_IDENTITY[sdk=iphonesimulator*]: "-"`), and an unsigned app has no access group at all, so Keychain writes there already fail `errSecMissingEntitlement (-34018)`. The separation is real on device; on simulator the Keychain story was already special and this change does not alter it. |
| A6 | **holds** | `SessionDaemon.swift:41-57` is exactly the shape to copy (`#if DEBUG static let isDebugBuild`, then `defaultDirectory(debug: Bool = isDebugBuild)`). Task 4's code was corrected to match it rather than use a closure form. Only two production callers of `FileSessionPersistence.defaultDirectory()` exist (`AppDelegate.swift:64,73`), both already `FlightDeckApp.stateDirectory() ?? …`, so a defaulted parameter is safe. |
| A7 | **holds** | Every `dev.flightdeck.FlightDeck` literal in `Sources/` is a `Logger(subsystem:)`, and all but two already read `Bundle.main.bundleIdentifier ?? …` so they follow the new id automatically. The two literals (`AppDelegate.swift:21`, `FlightDeckApp.swift:11`) affect log subsystem naming only. Nothing functional hardcodes the identifier. |
| A8 | **REFUTED** | It is not just `answer-trigger.sh` and `deploy-phone.sh`. **`scripts/smoke.sh:32,34` and `scripts/screenshot.sh:47` also hardcode the domain — and they *delete* from it.** `smoke.sh` builds Debug but resets the Release domain's window frames and saved state, which after Task 1 would both leave the app under test with stale geometry and reach into the installed app. **Added as Task 5.** Also: `deploy-phone.sh`'s configuration variable is `CONFIG`, not `CONFIGURATION` — Task 3 corrected. |

**Bonus finding, no action needed.** Session state lives in *two* places: `sessions.json`
and a `UserDefaults` blob at key `sessions.snapshot.v1`, which `FileSessionPersistence`
migrates from once (`SessionPersistence.swift:169-193`). The defaults half separates for
free with the bundle id, and a fresh Debug domain has no blob, so the migration simply does
not fire. That also retires a known hazard: the note that "an overridden store allowed to
migrate would consume the real user's `sessions.snapshot.v1` as a side effect" stops being
reachable for a plain debug run, because there is no longer a shared blob to consume.

**Not spiked, and honestly cannot be without running the built apps:** that macOS issues a
*second* local-network permission prompt for the new identity (A-implied by TCC keying on
the designated requirement, but only observable live), and that two builds can hold their
fleet listeners simultaneously without fighting over a port. Both are in the manual
checklist above; item 4 exists precisely because the absence of that second prompt would be
the visible symptom of the identities not having separated.
