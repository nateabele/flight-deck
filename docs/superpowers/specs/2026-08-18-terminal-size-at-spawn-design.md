# Terminal Size At Spawn — Design

Restored sessions hard-wrap their scrollback at ~50 columns because the `claude` process
is spawned into a PTY that libghostty sized 800×600 **pixels** before any window exists.
This gives every surface a real size at creation, and keeps background surfaces current
without paying a reflow per frame of a window drag.

## 1. Root cause

Four facts, in the order they compose:

| Fact | Where |
|---|---|
| A new surface starts at a hardcoded `.size = .{ .width = 800, .height = 600 }` — screen **pixels**, with `content_scale` a separate field. | `vendor/ghostty/src/apprt/embedded.zig:475` |
| `ghostty_surface_config_s` has no width/height field. The only sizing API is `ghostty_surface_set_size`, which necessarily runs *after* `ghostty_surface_new`. | `vendor/ghostty/include/ghostty.h:426-453` |
| `ghostty_surface_new` starts terminal IO — it forks and execs the shell — so the child exists before anything can resize it. | `SurfaceView_AppKit.swift:384` |
| The only `sizeDidChange` call site in the app is `TerminalPane.updateNSView`, which only ever sees `store.selectedSessionID`'s surface. | `TerminalPane.swift:96` |

`config.scale_factor = NSScreen.main!.backingScaleFactor` (`SurfaceConfiguration.swift:68`),
so on a 2× display the cell is ~15.6 px wide for a 13pt font, and 800 px / 15.6 ≈ **51
columns** × ~17 rows. That is the observed wrap column.

`restore()` runs inside `SessionStore.init`, which is a `@StateObject` initializer
(`FlightDeckApp.swift:78`), so every session's shell is spawned before SwiftUI builds the
scene body. There is no window to measure at spawn time, and the *selected* session is
affected too — which is why the wrap is visible in the front tab's scrollback and not only
in background tabs.

### 1.1 Why the live region looks right and the scrollback does not

Ghostty reflows *soft*-wrapped rows on resize. Claude Code emits its own line breaks at
what it believes the terminal width to be, so its output lands in the grid as genuine
newline-terminated rows. When `SIGWINCH` finally arrives, Claude Code repaints its live
frame at the new width — but the rows already committed to scrollback cannot be un-broken.

## 2. Persisted size

`SessionSnapshot` gains one optional top-level field:

```swift
/// The terminal pane's content size in points when this snapshot was written.
struct TerminalSize: Codable, Equatable { var width: Double; var height: Double }
var terminalSize: TerminalSize?
```

**Optional is load-bearing**, for exactly the reason the file already documents for
`pinnedConversationID` and `transcriptDirectory`: synthesized `Codable` decodes an optional
with `decodeIfPresent`, so every existing `sessions.json` still decodes instead of throwing
and wiping every tab on the first launch after this change. The defaults key stays
`sessions.snapshot.v1`.

**Points, not pixels.** Scale is a property of the display you are on now, not of the
snapshot. A snapshot written on a Retina display and reopened on a 1× one must not double
the column count.

**App-wide, not per-session.** One window, one terminal pane (`RootWindow.swift`), so every
tab is necessarily the same size. Per-session values could only ever be copies of each
other, and would introduce state that can diverge without meaning anything.

## 3. `SessionStore`

### 3.1 The size

```swift
/// The terminal pane's content size in points. Seeded from the snapshot by `restore()`,
/// updated by `TerminalHostView`, and handed to every surface at creation.
private(set) var terminalSize: CGSize
```

Seeded in `restore()` from `snapshot.terminalSize` **immediately after
`persistence?.load()`, above the `!snapshot.sessions.isEmpty || !recorded.isEmpty` guard**.
That guard returns early when the user quit with every session closed, and
`SessionStore.init` then calls `seedInitialSession()` — which goes through `insertSession`
and so needs the size. Seeding below the guard would hand that session the default instead
of the size the window was actually left at. Otherwise `Self.defaultTerminalSize`,
derived from the geometry `RootWindow` actually declares — `.defaultSize(width: 1000,
height: 700)` less the 240pt sidebar ideal and the title bar. That constant is documented as
an estimate that applies only to a first-ever launch, when there is no snapshot to read.

### 3.2 Reporting

One private choke point, so there is exactly one place a size reaches a surface:

```swift
private func report(_ size: CGSize, to id: UUID) {
    guard size.width > 0, size.height > 0 else { return }
    if let override = sizeReporterOverride { override(id, size); return }
    surfaces[id]?.sizeDidChange(size)
}
```

Three callers:

1. **`insertSession`** — immediately after `surfaces[session.id] = surface`, before the
   shell can have produced anything. This is the fix for the reported bug.
2. **`terminalSizeDidChange(_:)`** — the window resized (§3.3).
3. **`activateTerminalSize(for:)`** — a tab was selected and needs the current size
   (§4).

### 3.3 Resize, coalesced

```swift
func terminalSizeDidChange(_ size: CGSize) {
    guard size.width > 0, size.height > 0, size != terminalSize else { return }
    terminalSize = size
    if let id = selectedSessionID { report(size, to: id) }

    resizeGeneration &+= 1
    let generation = resizeGeneration
    resizeSettle { [weak self] in
        guard let self, self.resizeGeneration == generation else { return }
        for id in self.surfaces.keys { self.report(self.terminalSize, to: id) }
        self.persist()
    }
}
```

The selected surface tracks live, as it does today. Background surfaces are told **once,
when the resize settles** — a trailing debounce. The settled pass deliberately reports to
*every* surface rather than skipping the selected one: selection can change between the
resize and the settle, and `setSurfaceSize` already discards a repeat of an unchanged pixel
size (`SurfaceView_AppKit.swift`), so the redundant call costs nothing and removes a
correctness wrinkle. Broadcasting per frame instead would cost
N `ghostty_surface_set_size` calls per frame of a drag, each one a grid-and-scrollback
reflow; `setSurfaceSize`'s existing deduplication does not help, because no two frames of a
drag carry the same size.

The debounce is deferred through a seam that mirrors `injectionSettle`
(`SessionStore.swift:252`) exactly:

```swift
/// Test seam. Production waits for the drag to settle before touching background
/// surfaces; tests run the continuation inline.
var resizeSettle: (@escaping () -> Void) -> Void = { work in
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
}
```

Cancellation is a generation counter rather than a `DispatchWorkItem`, so it works
unchanged when a test substitutes an inline `resizeSettle`.

### 3.4 Persistence

`terminalSizeDidChange` does **not** persist — it fires on every frame of a live drag. The
**settled** callback does, once, after the broadcast.

Relying on the next natural `persist()` instead would be wrong: `persist()` runs on every
mutation (`SessionStore.swift:634`), but "launch, resize the window, quit" contains no
mutation, so the new size would be lost exactly when the user had just chosen it. One write
per resize gesture is cheap and matches the file's stated philosophy — "saved on every
mutation rather than at terminate, so a crash cannot lose the list". No `AppDelegate`
change is needed.

## 4. Activation refresh — `TerminalPane`

Two distinct paths, deliberately not merged:

- **`TerminalHostView.onResize`** → `store.terminalSizeDidChange(size)`. Deduped against
  the stored size, because `updateNSView` runs on every published store change (~2 Hz per
  live agent, per the existing note in `setSurfaceSize`).
- **`updateNSView`, on attach** → `store.activateTerminalSize(for: id)`, which reports
  `terminalSize` to the newly selected surface **unconditionally**. This is the existing
  re-parent correction and it must not go through the dedupe: the whole point is that this
  surface's grid may be stale while `store.terminalSize` has not moved.

Neither path reaches into `container.subviews` any more; the store owns delivery.

## 5. Scale — `GhosttyEmbed/SurfaceView_AppKit.swift`

`sizeDidChange` converts points to pixels with `self.convertToBacking(size)`
(`SurfaceView_AppKit.swift:476`), which returns the size **unchanged** when the view has no
window. Reporting 760×640 to a not-yet-parented surface would therefore set 760×640
*pixels* — the same bug at a different column count.

Fix at that line: when `window == nil`, scale by `NSScreen.main?.backingScaleFactor ?? 1`
— precisely the scale `SurfaceConfiguration` already hands `ghostty_surface_new`. One
annotated divergence from upstream, in the style of the existing `// Flight Deck:` notes in
that file.

Nothing else in the embed layer changes. `contentSize` is already stored in points and
re-scaled by `viewDidChangeBackingProperties` (`SurfaceView_AppKit.swift:870`) when the view
is later parented, so the value set at creation stays consistent once the surface is on
screen.

`vendor/ghostty` is a clean submodule pinned to v1.3.1 and is **not** patched.

## 6. Testing

Unit, in a new `TerminalSizeTests`, driven through `sizeReporterOverride` and an inline
`resizeSettle` (test stubs return `nil` surfaces, so there is nothing to spy on otherwise):

1. A session created by `restore()` is reported the snapshot's `terminalSize`.
2. With no `terminalSize` in the snapshot, it is reported `defaultTerminalSize`.
3. A resize reports live to the selected surface, and reaches every background surface
   once the settle runs — asserted with three live sessions.
4. Two rapid resizes with a deferred settle broadcast only the last size (generation
   guard).
5. Selecting a tab reports the current size to it even when `terminalSize` has not changed.
6. `SessionSnapshot` round-trips `terminalSize`, and a snapshot JSON without the field
   still decodes with every entry intact.

Manual, once: relaunch with two or more sessions and confirm full-width scrollback in both
the selected tab and a tab that was never selected. The GUI smoke suite is not run in a
loop (`docs/AGENT-OPERATIONS.md`).

## 7. Out of scope

- **The residual race.** `ghostty_surface_set_size` reaches libghostty's IO thread
  asynchronously, microseconds after the fork; the child has not finished `exec` yet, let
  alone printed. Not eliminated. If it ever bites, the escalation is to stop passing the
  resume line as `config.initialInput` and inject it through the existing `TextInjecting`
  seam only once the surface has been sized.
- Retroactively repairing scrollback already wrapped in a running session.
- Per-session or per-window sizes.
- Any change to `vendor/ghostty`.
