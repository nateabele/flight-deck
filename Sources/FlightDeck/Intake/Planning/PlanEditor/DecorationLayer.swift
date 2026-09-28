import AppKit

/// One decoration layer over the plan editor — the human's edits, the notes' highlights, the
/// agents' churn — drawn as TextKit 2 rendering attributes, which colour text without
/// touching the stored plan or its layout.
///
/// Several layers share one layout manager, so each clears only what IT set: clearing a key
/// across the whole plan erased every other layer's use of it (the edit tint and the note
/// highlight wiped each other on each refresh). Each layer also keeps to its own attribute
/// keys where layers overlap — the edit layer a background, notes an underline — since two
/// layers setting the same key on the same characters can only show one of them.
///
/// Ranges are found, not remembered as offsets: the layout manager moves rendering attributes
/// with every edit (probed — a tint on "world" follows it when text is typed before it), so
/// offsets saved at the last refresh point at the wrong characters by the next. Every range
/// the layer sets also carries a marker key of its own, and a refresh clears exactly the
/// runs that carry it, wherever the edits have moved them.
final class DecorationLayer {
    let key: String
    private let marker: NSAttributedString.Key
    /// The attribute keys this layer has set, so a refresh removes those and no others.
    private var keys: Set<NSAttributedString.Key> = []

    init(key: String) {
        self.key = key
        marker = NSAttributedString.Key("FlightDeck.decoration.\(key)")
    }

    /// Replaces this layer's decoration with `ranges` (UTF-16 offsets of the plan), leaving
    /// every other layer's alone. Ranges past the end of the text are clipped.
    func apply(_ ranges: [(NSRange, [NSAttributedString.Key: Any])], to layoutManager: NSTextLayoutManager) {
        guard let content = layoutManager.textContentManager else { return }
        let document = content.documentRange
        var mine: [NSTextRange] = []
        layoutManager.enumerateRenderingAttributes(from: document.location, reverse: false) { _, attributes, range in
            if attributes[marker] != nil { mine.append(range) }
            return true
        }
        for range in mine {
            for key in keys.union([marker]) { layoutManager.removeRenderingAttribute(key, for: range) }
        }
        keys = []

        let length = content.offset(from: document.location, to: document.endLocation)
        for (range, attributes) in ranges {
            let clipped = NSIntersectionRange(range, NSRange(location: 0, length: length))
            guard clipped.length > 0,
                  let start = content.location(document.location, offsetBy: clipped.location),
                  let end = content.location(start, offsetBy: clipped.length),
                  let textRange = NSTextRange(location: start, end: end) else { continue }
            for (key, value) in attributes {
                layoutManager.addRenderingAttribute(key, value: value, for: textRange)
                keys.insert(key)
            }
            layoutManager.addRenderingAttribute(marker, value: true, for: textRange)
        }
    }
}
