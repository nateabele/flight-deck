import AppKit

/// One character edit to the plan, as its text storage reported it: `range` is the new text's
/// characters in the new text, `delta` the change in length. What lets a layer keep the ranges
/// it found and move them, instead of finding them all again after every keystroke.
struct TextEdit: Equatable {
    let range: NSRange
    let delta: Int

    /// Where the replaced characters ended in the text before the edit.
    var oldEnd: Int { range.location + range.length - delta }

    /// `r` (in the text before the edit) in the text after it; nil when the edit changed
    /// characters inside it, so whatever it marked has to be found again. Text typed right
    /// after a range is not in it; text typed right before it moves it.
    func shift(_ r: NSRange) -> NSRange? {
        if NSMaxRange(r) <= range.location && !(r.length == 0 && r.location == range.location && range.length > 0) { return r }
        if r.location >= oldEnd { return NSRange(location: r.location + delta, length: r.length) }
        return nil
    }

    /// Every character of `r` after the edit, plus whatever the edit put inside it — a bound,
    /// not an exact range: it may cover a little more.
    func stretch(_ r: NSRange) -> NSRange {
        if let moved = shift(r) { return moved }
        let start = min(r.location, range.location)
        let end = max(NSMaxRange(r) + delta, NSMaxRange(range))
        return NSRange(location: start, length: max(end - start, 0))
    }

    /// Calls `edited` for every character edit to `storage` (attribute-only passes, like the
    /// styler's, are not edits). Remove the returned observer to stop.
    static func observe(_ storage: NSTextStorage, _ edited: @escaping @MainActor (TextEdit) -> Void) -> NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: NSTextStorage.didProcessEditingNotification, object: storage, queue: nil) { note in
            guard let storage = note.object as? NSTextStorage, storage.editedMask.contains(.editedCharacters) else { return }
            let edit = TextEdit(range: storage.editedRange, delta: storage.changeInLength)
            MainActor.assumeIsolated { edited(edit) }
        }
    }
}

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
/// runs that carry it, wherever the edits have moved them. The search is bounded: the layer
/// keeps the span its ranges cover, moved by every edit to the text (`TextEdit`), and walks
/// only that — walking the whole plan's runs on every keystroke cost more than the tint.
final class DecorationLayer {
    let key: String
    private let marker: NSAttributedString.Key
    /// The attribute keys this layer has set, so a refresh removes those and no others.
    private var keys: Set<NSAttributedString.Key> = []
    /// Where this layer's runs can be — the span of what it last set, moved with the text's
    /// edits since; nil when it has set nothing. Exposed for tests.
    private(set) var extent: NSRange?
    private var observed: NSTextStorage?
    private var observer: NSObjectProtocol?

    init(key: String) {
        self.key = key
        marker = NSAttributedString.Key("FlightDeck.decoration.\(key)")
    }

    deinit { observer.map(NotificationCenter.default.removeObserver) }

    /// Replaces this layer's decoration with `ranges` (UTF-16 offsets of the plan), leaving
    /// every other layer's alone. Ranges past the end of the text are clipped.
    func apply(_ ranges: [(NSRange, [NSAttributedString.Key: Any])], to layoutManager: NSTextLayoutManager) {
        guard let content = layoutManager.textContentManager else { return }
        follow(content)
        let document = content.documentRange
        let length = content.offset(from: document.location, to: document.endLocation)
        if let extent, let from = content.location(document.location, offsetBy: min(extent.location, length)) {
            let end = NSMaxRange(extent)
            var mine: [NSTextRange] = []
            layoutManager.enumerateRenderingAttributes(from: from, reverse: false) { _, attributes, range in
                if attributes[marker] != nil { mine.append(range) }
                return content.offset(from: document.location, to: range.endLocation) < end
            }
            for range in mine {
                for key in keys.union([marker]) { layoutManager.removeRenderingAttribute(key, for: range) }
            }
        }
        keys = []
        extent = nil

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
            extent = extent.map { NSUnionRange($0, clipped) } ?? clipped
        }
    }

    /// Moves `extent` with every edit to the text the layer decorates.
    private func follow(_ content: NSTextContentManager) {
        guard let storage = (content as? NSTextContentStorage)?.textStorage, storage !== observed else { return }
        observer.map(NotificationCenter.default.removeObserver)
        observed = storage
        observer = TextEdit.observe(storage) { [weak self] edit in
            guard let self, let extent = self.extent else { return }
            self.extent = edit.stretch(extent)
        }
    }
}
