# flightdeckapp.dev

The marketing site for Flight Deck. Static — no build step, no dependencies, no
framework. Four files plus icons.

```
site/
  index.html     the whole page
  styles.css     design tokens + the app-window replica
  demo.js        the demo (beats, glyphs, terminal content) + launch sequence
  assets/        icon sizes derived from ../assets/appicon-source.png
```

## Run it locally

```bash
cd site && python3 -m http.server 8899
# → http://localhost:8899
```

## Deploy (Cloudflare Pages)

The domain is registered at Cloudflare, so Pages is the path of least friction.

- **Build command:** *(none)*
- **Build output directory:** `site`
- **Root directory:** repository root

Connect the repo in the Pages dashboard, then add `flightdeckapp.dev` as a custom
domain. Because there's no build step, `wrangler pages deploy site` works just as
well for a one-off publish.

## Before it goes live

**The download link is a placeholder.** Two occurrences of
`/download/FlightDeck-latest.dmg` in `index.html` (hero and closing CTA), each
marked with a `PLACEHOLDER:` comment. Point them at the real release artifact
once shipping is set up:

```bash
rg -n 'FlightDeck-latest.dmg' index.html
```

Everything else on the page is accurate as written — see below.

## Editing the content

**Feature list.** `index.html`, the `.outcomes` block. Four numbered outcomes,
each with nested capabilities. Numbering is CSS counters, so inserting an item
renumbers everything automatically — don't hand-number.

Each capability carries a state tag, and the page's credibility rests on these
being true:

| Tag | Meaning |
|---|---|
| `tag-shipped` | Built and running today |
| `tag-building` | Actively in progress |
| `tag-planned` | Designed and specified, not yet built |

The current assignment tracks `docs/HANDOFF.md` and `docs/FOLLOWUPS.md`. When a
subsystem lands, move its tag in the same branch as the behaviour change — the
same rule `AGENTS.md` applies to docs.

**Demo.** `demo.js`, the `BEATS` array — one entry per beat, each holding its
caption, project/session tree, and which session is selected. Terminal content
lives in the `T` map, keyed by session id. Add a beat and the rail grows to
match; nothing else needs adjusting.

**Launch.** The demo starts hidden. As you scroll, the app icon travels down
the page — passing behind the hero copy and buttons, dimming 20% while it is
behind them and coming back to full as it clears — and when it reaches the demo
the window zooms open out of it the way a Mac app opens from its Finder icon.
The icon descends at `TRAVEL_RATE` (2.2×) of the scroll, so it arrives at the
demo ahead of the page. Just before the zoom, the icon flashes
to its Finder selected state (`SELECT_MS`), the way Finder marks an icon
selected on double-click a beat before the app opens. The window opens at `LAUNCH_LEAD` px
of scroll from that arrival point — currently -105, so the zoom is well underway
before the icon finishes travelling and the two motions overlap.

How far the whole sequence runs ahead of the scrollbar is set by `TRAVEL_RATE`
— the icon arrives at `land / TRAVEL_RATE`, and the launch keys off that, so
raising it pulls the slide and the launch forward together.

Both thresholds are fixed positions on the page, and should stay that way. They
were once made to move with scroll velocity, to try to outrun a fast fling. It
broke more than it fixed: the two boundaries could cross, so the demo flickered
open and shut whenever the scroll rate changed — open early at speed, slow down,
and the close point ends up above you. Hysteresis only works if the boundaries
can't pass through each other. `CLOSE_MARGIN` is the gap below the open point,
wide enough that a scroll stalling on the boundary can't toggle it.

Double-clicking the icon or its name (or pressing Enter on it) scrolls to the
same place and opens it. Scrolling back up closes it again so the sequence can
replay.

**"See what it does"** doesn't stop at the demo — it carries on past the features
heading and lands on the outcome list, switching the demo on (a 10ms fade, no
selection flash, no zoom) so it's already running as you pass it. It runs at its
own `REVEAL_SPEED`, faster than the demo-opening rate, because it covers roughly
three times the distance. The demo's sticky hold means it still sits at the
top for a moment on the way by. That path sets a `forced` flag, and has to: the
scroll tween calls `updateTravel()` on every step, and near the top of the page
that is below the close threshold, so without it the reveal would undo itself on
the very next frame.

**Scroll motion** is a uniform `SCROLL_SPEED` (px/ms) with the distance setting
the duration, not a fixed duration — otherwise the long trip to the features
section covers three times the ground in the same time as the short one to the
demo and whips past. It's linear within the run too; ease-in-out and a
fast-ramp-then-glide were both tried and read as awkward. `SCROLL_MIN_MS` is a
deliberate exception: trips under ~250px take that long regardless, so a short
hop isn't an instant jump. The landing position is
`LANDING_GAP` in `demo.js` — the window's resting distance below the top of the
screen.

**Sticky hold.** Once landed, the demo pins at the top and holds for 160px of
scroll before releasing — long enough that the beat rail ends up just above the
"What you get" heading. Two non-obvious constraints:

- The hold is the `.demo-track` spacer's height, *not* padding on `.demo`. A
  sticky box is constrained to its containing block's **content** box, so
  padding-bottom there buys zero travel and the pin silently never happens.
- `.demo-inner` being sticky makes it a positioned element, so `offsetTop`
  measured *through* it reports the shifted position once pinned. Everything in
  `demo.js` that needs the window's laid-out position goes through
  `windowStaticTop()`, which measures from the section instead. Walking up from
  the window itself makes the launch threshold drift by up to the full 160px as
  you scroll.

Two more things are load-bearing and easy to break:

- The icon's entrance animation is opacity-only, with `animation-fill-mode:
  backwards`. A filled CSS animation outranks inline styles, so giving the icon
  the shared `rise` keyframe (which ends `transform: none`) silently pins it in
  place and the travel stops working with no error anywhere.
- The hidden-until-launched state is scoped to `html.js`, set by an inline
  script in `<head>` before first paint and removed again by `demo.js` if it
  can't wire the launch up. Don't hide the demo unconditionally in CSS — a
  script that fails would leave the page's centrepiece invisible.

**Autoplay.** It advances on a timer — `DWELL` in `demo.js`, currently 5200ms —
and is not tied to scroll position at all. Beats only run once the app has
launched, so the story always starts from the first one. It pauses on hover, on keyboard focus, and
whenever it scrolls off-screen, and resuming restarts the current beat's dwell
from zero rather than finishing a partial one. Clicking a rail dot hands
control to the visitor permanently, since an autoplay that resumed underneath
someone who just picked a step would pull them off it moments later. Under
`prefers-reduced-motion` it never advances on its own and the rail is the only
way through it.

The sidebar in the demo mirrors the real app deliberately: row geometry, the
hover-revealed close button, the collapsed-project rollup that surfaces the most
demanding child state, and the four status glyphs from
`Sources/FlightDeck/SessionStatusIcon.swift` (grey `circle.fill` idle, accent
`circle.fill` unread, indeterminate spinner + subagent count busy, orange
`questionmark.circle.fill` waiting, green `terminal.fill` shell). SF Symbols
aren't available on the web, so those are redrawn as inline SVG in `demo.js`.
If the app's status vocabulary changes, change it here too.

## Notes

- Dark-only by design — the palette is sampled from the app icon.
- No analytics, no fonts, no third-party requests. The page loads three local
  files and two images.
- `prefers-reduced-motion` is honoured: entrance animations and the caret drop
  out, and the spinner slows rather than stopping (it's a status indicator, so
  it still needs to read as active).
