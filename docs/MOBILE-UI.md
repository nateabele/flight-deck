# Working on the phone's UI

`Sources/FlightDeckMobile/` — the screens, and how to change one without shipping something
nobody looked at. For what a device has to confirm once you have changed it, see
[MOBILE.md](MOBILE.md), which is the checklist this document keeps feeding.

## The constraint that shapes everything here

**The unit suite has no window.** `FlightDeckMobileTests` runs inside the app process on a
simulator, so it can build a view — and it cannot lay one out, draw one, measure one, tap one,
or read a pixel of it. Nothing in that suite has ever seen a screen.

That single fact produces the whole shape of this code:

- **Decisions are pure functions, held apart from the views that draw them.** `TimelineStyle`
  is one enum of them — which kind renders as Markdown, how much of a body a row shows, what a
  row's accessibility label says, whether a row leads anywhere. `TimelineSegmenter` is another.
  Those are testable to the last edge case, and they are where the arguments live.
- **Appearance is not asserted, ever.** Whether a heading reads as a banner, whether a cut looks
  deliberate, whether a gap is too wide — none of that is reachable, and a test that claimed to
  check it would be re-reading the source in a costume. It goes in MOBILE.md's checklist, or it
  goes in a render.
- **A test that can only pass is worse than no test.** The pattern to watch for is an assertion
  whose expected value is computed the same way the code computes it. `TimelineProseTests`
  states this in its own header; read it before adding to that file.

So: put the judgement in a function, test the function, and write down what you could not test.

## Seeing it

Three routes, in ascending order of cost and truth.

### The simulator

```
xcrun simctl boot <udid>            # or open -a Simulator
xcodebuild -project FlightDeck.xcodeproj -scheme FlightDeckMobile \
  -configuration Debug -destination 'id=<udid>' -derivedDataPath DerivedData build
xcrun simctl install <udid> DerivedData/Build/Products/Debug-iphonesimulator/FlightDeckMobile.app
xcrun simctl launch  <udid> io.radify.flightdeck.FlightDeckMobile
xcrun simctl io      <udid> screenshot shot.png
```

`simctl io screenshot` works. **Driving the UI does not**: there is no supported tap command,
and both of the usual workarounds need Accessibility permission this machine does not grant —
`osascript` returns `-1719 (not allowed assistive access)`, and anything posting `CGEvent`s
fails the same way. So you can look at whatever screen the app happens to open on, and you
cannot navigate to a second one. Plan around that rather than rediscovering it.

The simulator pairs with a real Mac over the typed code (the camera does not exist there), so a
booted simulator against a running Flight Deck shows the real fleet, which is by far the best
content to look at.

### The device

```
./scripts/deploy-phone.sh              # build, install, RELAUNCH
./scripts/deploy-phone.sh --no-build   # ship a bundle you already built
```

The relaunch is the point — `devicectl install` leaves the old process running the old code, and
reading a stale build's behaviour has happened here more than once. `DEVICE` defaults to
`Mobile3`. A `State` of `unavailable` in `xcrun devicectl list devices` means CoreDevice cannot
*find* the phone. Addressing it differently (name, UDID, ECID) will not help: the identifier is
not the problem. Plugging in a cable always works.

**Always install through `deploy-phone.sh`, never with a bare `devicectl device install`.**
Before installing, it runs `scripts/phone-proxy.sh`, which repairs the Wi-Fi case below by
itself: it reads the phone's current records and replaces any stale proxy, in about 3 s. It
also fails loudly. A failed build prints its errors and a failed install exits 1, where both
used to read as success. When the phone really can't be reached, `phone-proxy.sh` says why:
the name doesn't resolve (asleep, off this Wi-Fi, on cellular) or the phone didn't answer.
What follows explains what it automates.

#### `unavailable` on Wi-Fi: the phone is there, its Bonjour advert is not

A wireless phone is found only through its multicast mDNS advert for `_remotepairing._tcp`. On
2026-10-09 the phone sat `unavailable` for over an hour on the same Wi-Fi as the Mac and still
had a network path the whole time. It answered ping, lockdownd's port 62078 was open, and
Tailscale reported a `direct` LAN path. Its multicast adverts never reached the Mac, almost
certainly because the router filters multicast. A browse found nothing:
`dns-sd -B _remotepairing._tcp local.` stays empty. Asked over **unicast**, though, the phone
answered in full.

So hand the Mac the advert yourself:

```
# 1. The phone's LAN address. Use Tailscale's "direct <ip>:<port>" for the iPhone if you have it.
#    arp alone misleads: the phone uses a private Wi-Fi MAC, and an "iphone" arp entry can be a
#    different device.
tailscale status

# 2. Ask the phone's own mDNS responder for its records (unicast, port 5353).
dig +short @<phone-ip> -p 5353 _remotepairing._tcp.local PTR      # -> <uuid>._remotepairing._tcp.local.
dig +noall +answer @<phone-ip> -p 5353 <uuid>._remotepairing._tcp.local SRV TXT

# 3. Re-advertise it from this Mac as a Bonjour proxy, with the SRV port and every TXT pair.
nohup dns-sd -P <uuid> _remotepairing._tcp local <srv-port> <phone>-proxy.local <phone-ip> \
  identifier=<uuid> authTag=<…> ver=<…> minVer=<…> flags=<…> &
```

Within seconds the phone lists as `available (paired)` and `deploy-phone.sh` works.

- **First check that the phone is on the LAN at all.** If `tailscale status` shows the iPhone's
  `direct` address as a public IP rather than a `192.168.x.x` one, the phone is on cellular, and
  neither this recipe nor a stale proxy can help. Tailscale does not carry CoreDevice. On
  2026-10-14 the phone answered ping over its tailnet address, but its mDNS responder (5353)
  did not answer, and the remote-pairing (49152) and lockdownd (62078) ports were closed. Join
  the Mac's Wi-Fi, or plug in a cable.

- **The proxy's host name must not be the phone's own.** `Mobile3.local` is already claimed,
  and `dns-sd` reports `Name in use, please choose another`. That error is also a clue: the
  phone's *host* record does get through, and only the service advert is lost.
- **The proxy goes stale.** It hard-codes the phone's IP, port, service UUID and `authTag`. When
  any of them changes, the phone goes back to `unavailable`, though not always visibly:
  `devicectl` can keep listing it `available (paired)` while an install dies with "The peer is
  no longer reachable". The UUID changes often, once within a minute (2026-10-16), so
  `phone-proxy.sh` compares the running proxy with the phone's current records on every run.
  It never trusts "available" on its own, and `deploy-phone.sh` refreshes and retries once if
  an install loses its connection. On 2026-10-14 the IP was unchanged
  but the UUID and `authTag` were both new, so re-run step 2 from the PTR query rather than
  reusing the old UUID. Kill the `dns-sd -P` process and register again.
- **The real fix is the network.** Turn off multicast filtering, IGMP snooping or client
  isolation on the router, or keep the phone off a guest network. The proxy routes around the
  router; it does not fix it.

#### When the phone freezes

```
scripts/phone-stalls.sh [lines]    # the phone's journal, stall stacks symbolicated
```

The app watches its own main thread (`MainStallWatch`, in `PhoneLog.swift`). When the main
queue fails to answer within 250 ms, the watch samples the main thread's stack: at 250 ms, then
every 500 ms, up to four samples. Each sample goes to the journal the moment it's taken, written
synchronously from the watch's own thread, so a freeze that ends in a watchdog kill still leaves
its stacks behind. When the thread recovers, a `main stall ms=… samples=…` line gives the total.
Slow highlighting, rebuilds, cache reads and log reads log themselves under `perf` too.

The script reads the journal with `devicectl`, not over the fleet socket, because a frozen
phone is the one that can't answer a socket request. It resolves the app's own frames with
`atos`, against the dSYM whose UUID matches that launch's `stall watch armed uuid=…` line. A
launch whose build has since been overwritten in `DerivedData` prints its offsets unresolved,
so keep the dSYM of any build you leave on the phone.

Two things that cost time:
- **Instruments and lldb are not alternatives over Wi-Fi.** `xctrace` lists a wireless phone
  as offline even while CoreDevice reaches it. `lldb`'s `device process attach` does attach, but
  a scripted batch that errors out quits while attached, and that kills the app.
- **A SIGKILL report with the main thread in layout is a watchdog kill.** Check
  `xcrun devicectl device info files --device Mobile3 --domain-type systemCrashLogs` for
  `FlightDeckMobile-*.ips`. On 2026-10-14 three of them, each with the main thread in
  `NSTextLayoutManager` and `GraphHost.updatePreferences`, came from a 294-item cached
  conversation drawn before the first frame at every launch. That's why
  `SessionTimelineModel.cachedItems` is 60.

### An offscreen render

The way to compare two renderings, or to see a state you cannot navigate to.
`Tests/FlightDeckMobileTests/ProseRenderHarness.swift` is a working example; it drew the
attributed prose renderer beside the MarkdownUI one at 370pt in both themes, which is how the
theme was confirmed to survive being rewritten as `NSAttributedString`.

Four things about it cost real time, so they are written down:

- **`TEST_RUNNER_FOO=1` on the xcodebuild command line does not reach an app-hosted unit
  suite.** That prefix is for a UI-test runner. An app-hosted suite takes its environment from
  the scheme, so an env-var gate has to be set there — or flipped by hand for one run, which is
  what has actually been done every time.
- **Measure and draw want opposite orders.** A `UIHostingController` sized before its hierarchy
  has laid out under-reports any `UIViewRepresentable` inside it, so the image clips. A
  controller whose window is resized *after* layout draws nothing at all. Do them as two passes:
  one window to measure in, another to draw in.
- **`drawHierarchy(in:afterScreenUpdates:)` needs a real `UIWindow`.** A hosting controller off
  screen lays out and does not draw; a `UITextView` in particular comes back blank.
- **A blank image is the failure mode**, not a crash. Check the returned size against something
  you measured independently before believing what you are looking at.

## The rules the existing code already follows

Break one of these and the render will tell you eventually; better to know first.

- **Monospace is for machine text.** Prose is the system font. A long answer set in monospace
  fits about 38 characters to the line on a 393pt phone and turns into a grey wall — that was
  measured off a render, and it is why `TimelineMarkdown.theme` monospaces exactly two things,
  `code` and `codeBlock`.
- **Sizes are relative, never absolute.** Every size in the theme is an `em` multiplier off the
  enclosing view's font, so it tracks Dynamic Type. An absolute point size pins a heading at
  17pt while the paragraph under it grows to 53 at `.accessibilityExtraExtraExtraLarge` — see
  MOBILE.md item 29, which exists to catch exactly that.
- **Every `Text` names its own font.** `List { … }.font(…)` does not reach row content: some
  rows inherited it and their neighbours did not, in the same list, which is what sent
  `FleetListScreen` back from testing once already.
- **Prose is drawn by two renderers now, and they scale off the same numbers.**
  `TimelineMarkdown.theme` (MarkdownUI) draws code blocks, lists and quotes (a table is `PlanTableView`, below);
  `TimelineProseText` draws paragraphs as attributed text so they can be selected. Every
  multiplier in the second is named after the style it came from in the first. Change one,
  change both, and re-run the comparison render.

- **A pipe table is its own grid, and its widths are the Mac's.** `PlanTableView` (reached through
  `RichBlockView`, which the plan reader and the timeline both use) lays a table out with
  `PipeTable.fit` in FleetKit — the rule the Mac's plan editor uses — so a one-word column stays
  narrow beside two sentence columns. MarkdownUI's table, which this replaced, broke words to fit
  equal columns. A table whose longest words cannot share the phone's width keeps them whole and
  scrolls sideways; it is not stacked into cards, which would be a different document from the
  Mac's. `PlanTableRenderHarness` draws it (an empty `DerivedData/plan-table-renders-ios/.render`
  file turns it on, since the scheme's environment is not reachable from the command line).

## SwiftUI traps this codebase has actually hit

Each of these cost a debugging session. They are listed because the symptom never names the
cause.

- **A `NavigationLink` swallows the tap on any control inside it.** A row cannot be a link and
  carry a button at once — which is why a prose row past the ceiling expands in place instead of
  pushing a screen, and why `TimelineStyle.opensDetail` is an unconditional `false` for prose.
- **A self-sizing `UITextView` in a `List` row will be measured before its text is set.**
  SwiftUI can call `sizeThatFits` before `updateUIView` has run against the current value, and a
  text view still holding the previous string answers for the previous string. Apply the text in
  `sizeThatFits` too. The symptom is one clipped line, visible only in a render.
- **A scrollable subview inside a scrolling `List` steals the pan.** `isScrollEnabled = false` is
  what keeps `SelectableProseView` out of that fight, and it is also what makes it size itself.
- **`markdownMargin` survives being split across views.** A body drawn as one `Markdown`
  document spaces its own blocks; rendered as one view per segment, those margins are still
  there, so the enclosing `VStack` needs `spacing: 0` or every gap is drawn twice.
- **Row state that a `List` might recycle is not automatically lost.**
  `ProseExpansionRecyclingTests` scrolled a row six thousand points away and back at 30, 200 and
  600 rows: a row's own `@State` came back intact every time. The expansion still lives on the
  screen rather than in the row, but for a better reason than rescue — a row that is a pure
  function of what it is handed is drivable by a test with no window, which is the whole game
  here.

## Running the tests

```
./scripts/test-ios.sh
```

It **creates and destroys its own simulator**. That is deliberate and must not be "optimised"
into `-destination 'name=iPhone 17 Pro'`: running the suite installs the app onto its
destination, so pointing it at a device someone is using overwrites the build they are testing.
That has happened. The cost is a cold boot per run, about 30 seconds.

Unlike the macOS suite it is a plain `xcodebuild test` — a simulator host is launched by
`simctl`, not LaunchServices, so it needs no GUI login session. Do not port
`scripts/test-unit.sh`'s dylib-symlink dance over; it solves a problem this side does not have.

## When you are done

Everything you could not prove goes in [MOBILE.md](MOBILE.md), as a numbered item that says what
to look at and what would be wrong. Write the item so it names the failure, not the feature — an
item that says "check the menu works" gets ticked without being read, and one that says "sign an
account in on the Mac, background the phone, come back, and check the new account is there"
cannot be.
