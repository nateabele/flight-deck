# Selectable agent prose, with Reply — design

**Status:** specified, not started.
**Written:** 2026-08-24, from an implementation survey; no code written.

## The ask

1. An agent's response is currently one contiguous block you press to copy. It should be
   **inline text you can highlight and copy** like any other text on the phone.
2. A selection's edit menu gains **Reply** beside Copy. It drops the selected text into the
   composer, prefixed `"> "` and followed by **two newlines**.
3. **Fenced code blocks inside the prose stay press-to-copy.** Only prose becomes selectable.

## Why this is not a display tweak

Three things have to move together. Each is load-bearing; doing one without the others leaves
the feature half-working in a way that is worse than today.

### 1. SwiftUI `Text` cannot carry a custom edit-menu item

`.textSelection(.enabled)` makes prose selectable and gives the caller **nothing**: no access
to the selected substring, no hook to add an action. `.contextMenu(forSelectionType:)` exists
only for `List`/`Table` row selection, not text ranges.

So the prose view must be a `UIViewRepresentable` over `UITextView`, using

```swift
func textView(_ textView: UITextView,
              editMenuForTextIn range: NSRange,
              suggestedActions: [UIMenuElement]) -> UIMenu?
```

to append a `UIAction(title: "Reply")` whose handler reads
`(textView.text as NSString).substring(with: range)`.

The text view is `isEditable = false`, `isSelectable = true`, scrolling disabled, and sized by
its own content — it lives inside a `List` row that must grow to fit it.

### 2. That displaces MarkdownUI for prose, so prose and code must be split first

`TimelineRow.swift:208-209` renders the whole body through `Markdown(...)` with
`TimelineMarkdown.theme`. That theme is not decoration — it carries the heading flattening, the
`.em`-relative sizing that Dynamic Type depends on (docs/MOBILE.md item 29), and the inline
`code` tint and wash added on 2026-08-24.

A `UITextView` renders `NSAttributedString`, not MarkdownUI. So the body has to be **segmented**
before rendering:

- **prose segments** → selectable text view, attributed to match the current theme
- **fenced code segments** → the existing press-to-copy block (`TimelineBodyBlock`,
  `TimelineItemDetailScreen.swift:148`)

Segmenting is the first task and is independently testable: a pure function from body text to
`[Segment]`, where `Segment` is `.prose(String)` or `.code(language: String?, String)`.

**Inline code (single backticks) stays inside prose** and keeps its tint. Only fenced blocks
become their own segment. Getting this backwards would strip the styling shipped two commits
ago.

### 3. The composer's draft is private state and Reply has to reach it

`PromptComposer.swift:24` — `@State private var draft: String`. A Reply action fires from a
timeline row, which has no path to it.

The draft must be lifted to `SessionTimelineModel`, which already owns everything else about
the screen's send path. That touches:

- `PromptComposer` — reads and writes `model.draft` instead of its own `@State`
- the send path — `model.send(draft)` then clear, including the deferred second clear that
  fixes the stale `UITextView` repaint (`PromptComposer.swift`, the `DispatchQueue.main.async`
  double write; see its comment before touching it)
- `SessionTimelinePromptTests` — the outbox is filed with `PromptText.value`, and
  `PromptOutbox.reconcile` matches on **exact string equality**, so anything that alters the
  draft's whitespace on the way out breaks retirement

## Reply's exact behaviour

Given a selection `S` and the current draft `D`:

```
D' = D + (D.isEmpty || D.hasSuffix("\n") ? "" : "\n") + quote(S) + "\n\n"
quote(S) = S split on newlines, each line prefixed "> ", rejoined
```

- **Every line of a multi-line selection is prefixed**, not just the first — a two-line quote
  with one marker is not a quote.
- **Two trailing newlines**, as asked: the reader's own text starts on a blank line after the
  quotation.
- **Appends, never replaces.** A draft already being written is not discarded by a quote.
- The composer scrolls to the end and keeps focus, so the reader types straight into the space
  the quote just made.

## Acceptance

- [ ] Highlighting a word in an agent response shows the system menu with **Copy** and **Reply**.
- [ ] Reply appends `"> "`-prefixed lines plus two newlines to whatever is already in the box.
- [ ] A fenced code block inside a response is still one press-to-copy block, not selectable prose.
- [ ] Inline single-backtick code inside a sentence keeps its purple tint and wash.
- [ ] Headings, emphasis, links and Dynamic Type sizing are unchanged from the MarkdownUI theme.
- [ ] Sending still clears the field, including the deferred repaint fix.
- [ ] The outbox still retires a sent prompt (exact-match reconcile is intact).

## Risks

- **Attributed-string fidelity.** Reproducing the MarkdownUI theme as an `NSAttributedString`
  is the largest unknown. Offscreen renders exist for this screen and should be compared before
  and after; a visual regression here is easy to ship and hard to notice.
- **Row sizing.** A self-sizing `UITextView` inside a `List` row is a classic source of
  wrong-height rows on first layout. Expect to pin `setContentCompressionResistancePriority`
  and to test with a response long enough to wrap several times.
- **Selection versus scroll.** A selectable text view inside a scrolling list can capture the
  pan gesture. Verify a long conversation still scrolls when the drag starts on prose.

## Sequencing

1. Segmenter (`body → [Segment]`), pure, with tests. Nothing renders differently yet.
2. Render fenced segments as today's press-to-copy block; prose still via MarkdownUI. No visible
   change, but the row is now built from segments.
3. Lift `draft` to `SessionTimelineModel`. No visible change; existing prompt tests must stay green.
4. Swap prose to the `UITextView` representable, matching the theme.
5. Add the Reply edit-menu action wired to the lifted draft.

Each step ships on its own and none of them leaves the screen broken between steps.
