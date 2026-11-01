# example.sketch

You are making a visual for a plan. Write these files in the draft folder you were given.

## visual.html

A single self-contained HTML file. State what belongs in it here, for example: one `<svg>`
showing the components named in the brief, each box labelled, arrows for data flow.

- Inline all CSS and scripts. No external URLs, no web fonts, no remote images.
- Keep the whole folder under 10 MB.
- Every name in `states` must exist as a state of the visual, and be listed in `visual.json`.

## visual.json

```json
{ "title": "Short title", "caption": "One sentence saying what the reader should notice.", "states": [] }
```

## Good and wrong

Say here what a good result looks like (readable at phone width, labels not clipped), and
what is wrong (decoration with no meaning, text under 12 px).
