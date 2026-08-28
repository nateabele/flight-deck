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
xcrun simctl launch  <udid> dev.flightdeck.FlightDeckMobile
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
`Mobile3`; a `State` of `unavailable` in `xcrun devicectl list devices` means the phone is
asleep, off the network, or unplugged, and no way of addressing it (name, UDID, ECID) will get
past that — it is the device, not the identifier.

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
  `TimelineMarkdown.theme` (MarkdownUI) draws code blocks, tables, lists and quotes;
  `TimelineProseText` draws paragraphs as attributed text so they can be selected. Every
  multiplier in the second is named after the style it came from in the first. Change one,
  change both, and re-run the comparison render.

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
