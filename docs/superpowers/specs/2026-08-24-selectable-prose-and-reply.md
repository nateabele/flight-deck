# Selectable agent prose, with Reply — design

**Status:** specified, decisions settled 2026-08-25; implementation in progress.
**Written:** 2026-08-24, from an implementation survey; no code written.

## The ask

1. An agent's response is currently one contiguous block you press to copy. It should be
   **inline text you can highlight and copy** like any other text on the phone.
2. A selection's edit menu gains **Reply** beside Copy. It drops the selected text into the
   composer, prefixed `"> "` and followed by **two newlines**.
3. **Fenced code blocks inside the prose stay press-to-copy.** Only prose becomes selectable.

Two things this is not:

- **Not the detail screen.** Prose rows already lead nowhere — `TimelineStyle.opensDetail` is an
  unconditional `false` for `.assistantText`/`.userTurn`, and a long answer opens where it
  stopped instead. The row is the only surface prose has, so it is the surface this changes.
  `.thinking`, the machine-text kinds and tool cards keep both their clamps and their detail
  screen; nothing here touches them.
- **Not cross-message selection.** A drag selects any range inside one message and stops at its
  edges. Selection that flows from one message into the next is not a text view away — UIKit has
  no cross-view selection, so it would mean the timeline ceasing to be a `List` of rows and
  becoming one continuous text container with the tool cards as attachments inside it. Declined
  on cost, not on taste.

**Both kinds of prose get this**, agent text and the reader's own turns: `rendersMarkdown`
already admits `.assistantText` and `.userTurn`, they are drawn by the same code, and quoting
your own earlier prompt to sharpen it is a real use. One rule is also less to explain than a
menu that changes depending on who wrote the row.

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
`[Segment]`, where `Segment` is one of three:

- `.prose(String)` — paragraphs, headings, emphasis, links. Becomes the selectable text view.
- `.code(language: String?, String)` — a fenced block. Stays press-to-copy.
- `.richBlock(String)` — a table, a list, or a blockquote.

**The third kind exists because `NSAttributedString` has no table.** MarkdownUI draws tables and
lists as views, and there is no attributed run that reproduces one; flattening a table to
tab-separated text would make the structured answers most worth quoting look worse than they do
today. So a rich block keeps MarkdownUI and goes press-to-copy alongside code. Only paragraph
prose becomes selectable, which is also the part whose theme an attributed string can honestly
match.

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

## The clamp, restated in segments

The ceiling stays. `proseCeilingLines` is 120 lines at 42 columns — some five thousand
characters, which no ordinary answer reaches — and it is what keeps a pasted log from costing
a screenful of layout. What changes is where it cuts and what the way out looks like.

### More/Less is a word, not a control

Today it is an accent `Label` with a chevron, `.caption2`, sitting under the prose
(`TimelineRow.swift:337-349`). It becomes **a plain accent word on its own line, in the text's
own left margin, with no chevron** — part of the message rather than a button bolted beneath
it. Less lands in the same place in both states, which the trailing-link alternative could not
offer: at the foot of a 120-line answer, a link that continues the cut sentence puts Less four
screenfuls from where More was tapped.

### The cut finishes a code block it lands inside

A budget that runs out mid-fence would draw half a panel. So once a fenced block starts within
the budget it renders **whole**, overshooting the ceiling by whatever that block costs.

This breaks an agreement the row currently depends on. `exceeds` decides *whether* to clamp and
`firstLines` decides *where*, and they count the same lines on purpose — the comment on
`firstLines` says why: a disagreement is a row that offers More and has nothing to show. Once
the cut can overshoot, the two can disagree in exactly one case, a block that ends the message.

So **the clamp reports whether anything remains** rather than the row inferring it from a line
count. `firstLines` also stops operating on raw text: it walks segments, spends the budget
across them, and returns both the kept segments and whether it kept all of them.

The mid-line, mid-word cut inside a prose segment is unchanged and still deliberate — a row
that ends on a whole line looks finished.

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
- [ ] A selection reaching the end of a message stops there rather than continuing into the next.
- [ ] Reply appears on the reader's own turns as well as agent text.
- [ ] A table or list in a response renders as it does today and is press-to-copy, not selectable.
- [ ] More/Less is an unadorned accent word on its own line, left-aligned with the prose.
- [ ] A cut landing inside a fenced block shows that block whole, never a partial panel.
- [ ] A message whose overshoot consumes the remainder draws **no** More link.

## Risks

- **Attributed-string fidelity.** Reproducing the MarkdownUI theme as an `NSAttributedString`
  is the largest unknown. Offscreen renders exist for this screen and should be compared before
  and after; a visual regression here is easy to ship and hard to notice.
- **Row sizing.** A self-sizing `UITextView` inside a `List` row is a classic source of
  wrong-height rows on first layout. Expect to pin `setContentCompressionResistancePriority`
  and to test with a response long enough to wrap several times.
- **The overshoot is unbounded.** A 400-line code block starting at line 118 renders whole, so
  the ceiling is a floor with a tail. This is the accepted cost of never drawing half a panel;
  if it bites, the answer is a cap on the block, not a return to cutting mid-fence.
- **Selection versus scroll.** A selectable text view inside a scrolling list can capture the
  pan gesture. Verify a long conversation still scrolls when the drag starts on prose.

## Sequencing

1. Segmenter (`body → [Segment]`), pure, with tests. Nothing renders differently yet.
1b. Clamp walks segments and reports whether anything remains; More/Less restyled. Visible, and
   independently checkable against a message that ends on a code block.
2. Render fenced segments as today's press-to-copy block; prose still via MarkdownUI. No visible
   change, but the row is now built from segments.
3. Lift `draft` to `SessionTimelineModel`. No visible change; existing prompt tests must stay green.
4. Swap prose to the `UITextView` representable, matching the theme.
5. Add the Reply edit-menu action wired to the lifted draft.

Each step ships on its own and none of them leaves the screen broken between steps.
