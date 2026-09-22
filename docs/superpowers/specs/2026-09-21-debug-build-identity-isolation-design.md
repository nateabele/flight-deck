# Debug-build identity isolation

**Status:** design
**Date:** 2026-09-21

Stop a debug Flight Deck from being the same app as the installed one.

## 1. Problem

A Debug build and the installed Release build are **literally the same app
identity**. `project.yml` has no `configs:` block and sets no per-configuration
`PRODUCT_BUNDLE_IDENTIFIER`, so both are `dev.flightdeck.FlightDeck`. Everything
that namespaces off that identity is therefore shared:

- the `UserDefaults` domain, and with it `preferences.v1` — which holds
  `pairedDevices` (every phone's key), `installID`, and the remembered fleet port;
- the derived Bonjour **instance name**. `FleetService.derivedServiceName` is
  `<hostname>-<first 4 of installID>`, and `installID` comes out of that shared
  blob — so two simultaneously-running builds advertise the *same* instance name
  on `_flightdeck._tcp`, and `FleetConnector` filters on exactly that name
  (`FleetConnector.swift:518-521`). A phone cannot tell them apart;
- the TCC / local-network grant, which is keyed on the designated requirement.

Consequences, in rising order of severity: a debug run cannot be tested against a
phone without disturbing the real pairing; two running builds clobber each other's
remembered port; and a debug build holds — and can rewrite — the real fleet's
paired-device secrets.

`docs/FOLLOWUPS.md` already flagged the sessions/daemon half of this ("a debug
build already reads and writes the same `sessions.json` as the real installed app
… for the identical reason (no salting)"). **The pairing half was never flagged.**

## 2. Approach

Give the Debug configuration its own bundle identifier on both platforms. Every
identity-derived surface then namespaces itself, with no further code:

| Surface | Namespaced by | Result |
|---|---|---|
| `UserDefaults` domain → `preferences.v1` | bundle id | separate `pairedDevices`, `installID`, port |
| Bonjour **instance** name | `installID`, now separate | debug advertises a distinct instance |
| macOS TCC / local-network grant | designated requirement | independent grant |
| iOS Keychain (`dev.flightdeck.pairedMac`) | default access group ← bundle id | phone can hold both pairings |

### The Bonjour service type does not change, and that is the point

`PairingChannel.bonjourType` is `_flightdeck-pair._tcp` — **exactly 15
characters, RFC 6763's maximum service label**. Any suffixed variant
(`_flightdeck-pair-dbg._tcp`) fails registration *silently*, which is the worst
possible failure for a discovery bug.

Isolating by instance name instead of by type avoids that entirely: the types
stay `_flightdeck._tcp` and `_flightdeck-pair._tcp`, so
`Sources/FlightDeckMobile/Info.plist`'s `NSBonjourServices` array is untouched —
which also dodges the fact that the repo has no precedent for a per-configuration
plist value.

### 2.1 The mechanism, verified

xcodegen emits per-configuration identifiers from a target's own `settings`
block, with **no** top-level `configs:` block required. Confirmed against a
throwaway project on 2026-09-21 — both values reached the generated `pbxproj`:

```yaml
    settings:
      configs:
        Debug:
          PRODUCT_BUNDLE_IDENTIFIER: dev.flightdeck.App.debug
        Release:
          PRODUCT_BUNDLE_IDENTIFIER: dev.flightdeck.App
```

So this is a small `project.yml` change per target, not a project restructure.
Note the Release value must be stated **explicitly** rather than left to
xcodegen's `bundleIdPrefix` derivation, so the shipping identifier is written
down where a reader can see it cannot drift.

### The iOS app needs a Debug identifier too

`PairedMacStore` keeps exactly **one** `PairedMac`, at Keychain service
`dev.flightdeck.pairedMac`, account `"primary"`. One installed iOS app therefore
pairs with exactly one Mac. Without a second iOS identity, pairing the phone to a
debug Mac *destroys* its pairing to the real one — which fails the goal. So
`FlightDeckMobile` gets a Debug bundle id as well, and the two apps install
side by side.

### Non-goals

- **No change to the pairing protocol, the wire format, or the transport.** This
  is an identity-namespacing change; SPAKE2, TLS-PSK and the frame vocabulary are
  untouched.
- **No new test infrastructure.** Prompt, answer and abort behaviour is already
  covered end to end in-process by `FleetTestHarness` and the `*LoopbackTests`
  family, which synthesize a `PairedDevice` and dial `loopbackEndpoint()`. This
  design does not duplicate that, and does not add simulator↔Mac automation.
- **Not a `#if DEBUG` switch in application code.** The isolation is a build
  identity, not a runtime branch. `AnswerTrigger`'s doc comment states the reason
  this codebase prefers that direction: a debug-only entry point cannot reach a
  failure that reproduces only on the installed Release build.

## 3. The path surfaces, and why they are in scope

Bundle id does **not** namespace file paths. Current state:

| Path | Isolated? | By what |
|---|---|---|
| `/tmp/flight-deck-<uid>` daemon sockets | **yes** | `SessionDaemon.isDebugBuild` |
| `hook-events-<tag>/events.ndjson` | **yes** | `ClaudePluginLocation.buildTag` |
| `~/Library/Application Support/Flight Deck/sessions.json` | **no** | literal folder name |
| `~/Library/Logs/flight-deck-*.log` | **no** | literal names |

Two build-salting precedents already exist in the tree, so the pattern is
established rather than invented. `sessions.json` is the one that matters: a
debug build reading and writing the real fleet's session state is a strictly
worse collision than the pairing one, because it mutates state the installed app
is actively using.

**Decision: salt `FileSessionPersistence.defaultDirectory()` by build
configuration, following `SessionDaemon.defaultDirectory(debug:)` exactly** —
same `isDebugBuild` value shape, same injectable-parameter seam so tests can
force either answer. `-FlightDeckStateDir` continues to override it, unchanged.

Logs stay shared. They are append-only diagnostics with a session id on every
line; interleaving is legible, and salting them would split the one artifact a
person greps when reproducing across builds.

## 4. What this costs

- **A second local-network permission prompt** on the first debug run, and a
  second one on the phone for the second iOS app. Unavoidable and correct — they
  are different apps now.
- **`scripts/deploy-phone.sh` hardcodes `BUNDLE_ID=dev.flightdeck.FlightDeckMobile`**
  and must learn which configuration it is installing.
- **`scripts/answer-trigger.sh` writes `defaults write dev.flightdeck.FlightDeck`**
  and must target the right domain.
- **A debug build starts with no paired devices**, which is the intended
  behaviour and also means the first debug phone test requires a real pairing.
- Existing debug builds lose their preferences once, at the cutover. Acceptable:
  a debug build's preferences are not precious, and the alternative (migrating
  them) would copy the real fleet's paired secrets into the new domain, which is
  the opposite of the goal.

## 5. Error handling and degradation

- **A debug build that has never paired** simply advertises and is found by
  nothing. No error state; the pairing UI already handles "no Macs found".
- **Both builds running at once** now advertise distinct instance names and
  remember distinct ports, so neither clobbers the other. This is the property
  to test.
- **`-FlightDeckStateDir` still wins** over the salted default, so the existing
  isolated-launch recipe keeps working unchanged.
- **The Release build is unaffected in every respect.** Its bundle id, domain,
  paths and grants are exactly what they are today — verifying that is a test
  obligation, not an assumption.

## 6. Testing

Unit-testable without a GUI or a phone:

- `FileSessionPersistence.defaultDirectory(debug:)` returns distinct paths for
  each answer, and `-FlightDeckStateDir` still overrides both — the same shape
  `SessionDaemon`'s own tests already use.
- `FleetService.derivedServiceName` differs for two `PreferencesStore`s holding
  different `installID`s, which is the mechanism the whole design rests on.
- A build-configuration guard test: assert the Release identifiers are exactly
  `dev.flightdeck.FlightDeck` and `dev.flightdeck.FlightDeckMobile`, so a future
  edit cannot silently rename the shipping app.

Requires a person (recorded as a checklist, not automated):

- Run both builds at once; confirm the phone lists two distinct Macs.
- Pair the debug phone app with the debug Mac; confirm the release app's pairing
  to the release Mac still works afterwards.
- Confirm the debug build's `sessions.json` is a different file and the real
  fleet is undisturbed.

`./scripts/test-unit.sh` ignores `-only-testing:` and runs the whole macOS suite
(~100s). Touching `Sources/FlightDeckMobile` or its plist means `./scripts/test-ios.sh`
must run too.

## 7. Risks

| Risk | Handling |
|---|---|
| A suffixed Bonjour **type** would fail registration silently | Not done — isolation is by instance name; types unchanged |
| xcodegen may not support per-configuration `PRODUCT_BUNDLE_IDENTIFIER` | **Settled by experiment — it does.** See §2.1 |
| iOS code signing is pinned per-SDK in `project.yml` and `deploy-phone.sh` assumes one id | Both must learn the configuration; `deploy-phone.sh` already exits 0 on failure, so verify the install rather than trusting it |
| Release identity drifts by accident | Pinned by the guard test above |
| A developer confuses the two installed phone apps | Give the Debug iOS app a distinct display name, not just a distinct id |

## 8. Open questions

1. Should the Debug Mac app also get a distinct display name and icon treatment?
   Purely ergonomic; deferred unless the two windows prove confusable.
