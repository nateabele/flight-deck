import Foundation

/// Line-count and section summary of what changed between two revisions of a plan document —
/// what the round card and plan viewer show without re-diffing on every render.
public struct PlanDelta: Equatable, Sendable {
    public var added: Int
    public var removed: Int
    public var sectionsChanged: [String]
    public init(added: Int, removed: Int, sectionsChanged: [String]) {
        self.added = added; self.removed = removed; self.sectionsChanged = sectionsChanged
    }
}

/// Measures how much a plan (markdown text) or a change set changed between two rounds.
///
/// The line diff is Myers' algorithm (`myersDiff` below) with a common-prefix/suffix strip in
/// front of it: a real plan revision is almost always "most of the document, unchanged, plus a
/// pocket of edits somewhere in the middle", and stripping the shared ends first shrinks Myers'
/// `D` (edit distance) parameter to roughly the size of that pocket instead of the whole
/// document — the difference between microseconds and the multi-second, ~36M-cell blowup a
/// plain O(n*m) LCS table hits on a 6,000-line plan in a Debug build.
public enum PlanMetrics {
    /// Line-level diff (Myers' LCS) — counts, plus the markdown headings (`#`...) whose section
    /// bodies changed, in document order.
    public static func delta(from old: String, to new: String) -> PlanDelta {
        let oldLines = planLines(old)
        let newLines = planLines(new)
        let ops = lineDiff(oldLines, newLines)

        var added = 0, removed = 0
        for op in ops {
            switch op {
            case .insert: added += 1
            case .delete: removed += 1
            case .equal: break
            }
        }

        let oldHeadings = headingPerLine(oldLines)
        let newHeadings = headingPerLine(newLines)
        let sections = sectionsChanged(ops, oldHeadings: oldHeadings, newHeadings: newHeadings)
        return PlanDelta(added: added, removed: removed, sectionsChanged: sections)
    }

    /// Unified-diff text for the plan viewer: standard `@@ -a,b +c,d @@` hunks with 3 lines of
    /// context, no `---`/`+++` file headers (there's no filename worth putting there — both
    /// sides are the same plan, at two rounds).
    public static func unifiedDiff(from old: String, to new: String) -> String {
        let oldLines = planLines(old)
        let newLines = planLines(new)
        let ops = lineDiff(oldLines, newLines)
        let codes = opcodes(from: ops)
        let groups = groupedOpcodes(codes, context: 3)

        var hunks: [String] = []
        for group in groups {
            guard let first = group.first, let last = group.last else { continue }
            let oldStart = first.i1, oldCount = last.i2 - first.i1
            let newStart = first.j1, newCount = last.j2 - first.j1

            var lines: [String] = []
            for code in group {
                switch code.tag {
                case .equal:
                    for i in code.i1..<code.i2 { lines.append(" \(oldLines[i])") }
                case .changed:
                    for i in code.i1..<code.i2 { lines.append("-\(oldLines[i])") }
                    for j in code.j1..<code.j2 { lines.append("+\(newLines[j])") }
                }
            }

            // Unified-diff convention: a zero-length side reports the line number BEFORE the
            // insertion/deletion point (with a count of 0), not the usual 1-based start.
            let oldHeader = oldCount == 0 ? "\(oldStart),0" : "\(oldStart + 1),\(oldCount)"
            let newHeader = newCount == 0 ? "\(newStart),0" : "\(newStart + 1),\(newCount)"
            hunks.append("@@ -\(oldHeader) +\(newHeader) @@\n" + lines.joined(separator: "\n"))
        }
        return hunks.joined(separator: "\n")
    }

    /// The changed regions between two revisions, without context lines — one `PlanHunk` per
    /// maximal run of deleted/inserted lines, in document order. The shape `PlanLayers.userDiff`
    /// hands the UI for "your edits", and the unit a per-hunk revert works on.
    public static func hunks(from old: String, to new: String) -> [PlanHunk] {
        let oldLines = planLines(old)
        let newLines = planLines(new)
        let newHeadings = headingPerLine(newLines)
        let oldHeadings = headingPerLine(oldLines)
        return opcodes(from: lineDiff(oldLines, newLines)).compactMap { code in
            guard code.tag == .changed else { return nil }
            // The section a hunk sits in, read from the edited side when it has lines there and
            // from the generated side for a pure deletion; "(preamble)" is no section at all.
            let heading = code.j2 > code.j1 ? newHeadings[code.j1]
                : code.i2 > code.i1 ? oldHeadings[code.i1] : "(preamble)"
            return PlanHunk(oldStart: code.i1, oldLines: oldLines[code.i1..<code.i2].map(String.init),
                            newStart: code.j1, newLines: newLines[code.j1..<code.j2].map(String.init),
                            section: heading == "(preamble)" ? nil : heading)
        }
    }

    /// Ops changed between two change sets: added + removed + modified, matched by the rules
    /// task-6-brief hands down — a created bead by its `tempId`, everything else (edits,
    /// reopens, follow-ups, dependency edges) by the existing bead id (or edge endpoints) plus
    /// op kind. `ChangeOp` is already `Equatable`, so "modified" is just "matched but unequal".
    public static func opsChanged(from old: ChangeSet, to new: ChangeSet) -> Int {
        let oldByKey = keyedOps(old.ops)
        let newByKey = keyedOps(new.ops)

        var changed = 0
        for (key, oldOp) in oldByKey {
            if let newOp = newByKey[key] {
                if newOp != oldOp { changed += 1 }
            } else {
                changed += 1 // removed
            }
        }
        for key in newByKey.keys where oldByKey[key] == nil {
            changed += 1 // added
        }
        return changed
    }
}

// MARK: - opsChanged matching

/// The identity a `ChangeOp` is matched by across two change sets — see `opsChanged`'s doc
/// comment. Dependency edges (`addEdge`) match by `(from, to)` only, deliberately dropping
/// `kind`: an edge whose `kind` flips (e.g. `related` -> `blocks`) between rounds is the same
/// edge, modified, not a different edge entirely.
private enum BaseOpKey: Hashable {
    case create(String)
    case edge(String, String)
    case edit(String)
    case reopen(String)
    case followUp(String)
}

/// `BaseOpKey` plus which occurrence (0-based) of it this op is within its own `ChangeSet`.
/// The validator allows more than one op sharing a `BaseOpKey` — two `followUp`s targeting the
/// same bead, two `editBead`s on the same id — so keying on `BaseOpKey` alone collapses every
/// such duplicate into one dictionary slot and only the last write survives; a real change on an
/// earlier occurrence then reads back as unmodified. Pairing the Nth occurrence in `old` with
/// the Nth occurrence in `new` (both counted by each set's own op order) keeps duplicates
/// distinguishable without needing anything beyond position to tell them apart.
private struct OpKey: Hashable {
    var base: BaseOpKey
    var occurrence: Int
}

private func baseOpKey(_ op: ChangeOp) -> BaseOpKey {
    switch op {
    case .createBead(let bead): .create(bead.tempId)
    case .addEdge(let from, let to, _): .edge(from.wireValue, to.wireValue)
    case .editBead(let id, _, _, _): .edit(id)
    case .reopen(let id, _, _): .reopen(id)
    case .followUp(_, let of, _, _, _): .followUp(of)
    }
}

private func keyedOps(_ ops: [ChangeOp]) -> [OpKey: ChangeOp] {
    var occurrences: [BaseOpKey: Int] = [:]
    var result: [OpKey: ChangeOp] = [:]
    for op in ops {
        let base = baseOpKey(op)
        let occurrence = occurrences[base, default: 0]
        occurrences[base] = occurrence + 1
        result[OpKey(base: base, occurrence: occurrence)] = op
    }
    return result
}

// MARK: - Line-level diff

/// Splits `text` into lines the way `split(separator: "\n", omittingEmptySubsequences: false)`
/// would for LF-only text, but correct for CRLF too. Splitting on `"\n"` as a `Character` never
/// fires inside a CRLF pair: `"\r\n"` is a single extended grapheme cluster, not two characters,
/// so a `Character`-based split treats a whole CRLF plan as one giant line. This splits on the
/// LF *unicode scalar* instead (bypassing grapheme-cluster segmentation entirely) and strips a
/// trailing CR scalar off each resulting line — all still via `String.Index`, so the result is
/// ordinary `Substring`s, safe to hash/compare/interpolate like any other line here.
func planLines(_ text: String) -> [Substring] {
    let scalars = text.unicodeScalars
    var lines: [Substring] = []
    var lineStart = scalars.startIndex
    var i = scalars.startIndex
    while i < scalars.endIndex {
        if scalars[i] == "\n" {
            lines.append(lineDroppingTrailingCR(text, lineStart, i))
            i = scalars.index(after: i)
            lineStart = i
        } else {
            i = scalars.index(after: i)
        }
    }
    lines.append(lineDroppingTrailingCR(text, lineStart, scalars.endIndex))
    return lines
}

private func lineDroppingTrailingCR(_ text: String, _ start: String.Index, _ end: String.Index) -> Substring {
    let scalars = text.unicodeScalars
    if end > start {
        let beforeEnd = scalars.index(before: end)
        if scalars[beforeEnd] == "\r" { return text[start..<beforeEnd] }
    }
    return text[start..<end]
}

/// One step of an edit script that aligns `old` and `new` line arrays: which lines matched
/// unchanged, which were only in `old`, and which were only in `new`. Indices are into the
/// original (untrimmed) line arrays, not whatever internal range actually ran through Myers.
enum LineEditOp: Equatable {
    case equal(oldIndex: Int, newIndex: Int)
    case delete(oldIndex: Int)
    case insert(newIndex: Int)
}

/// Diffs two line arrays: strips the common prefix/suffix (see the type's doc comment for why),
/// then runs Myers' algorithm over interned line ids so the inner-loop comparisons are Int
/// equality, not O(line length) string comparisons, on whatever's left in the middle.
func lineDiff(_ oldLines: [Substring], _ newLines: [Substring]) -> [LineEditOp] {
    var ids: [Substring: Int] = [:]
    func id(for line: Substring) -> Int {
        if let existing = ids[line] { return existing }
        let next = ids.count
        ids[line] = next
        return next
    }
    let a = oldLines.map(id(for:))
    let b = newLines.map(id(for:))

    var prefix = 0
    while prefix < a.count && prefix < b.count && a[prefix] == b[prefix] { prefix += 1 }
    var suffix = 0
    while suffix < a.count - prefix && suffix < b.count - prefix
        && a[a.count - 1 - suffix] == b[b.count - 1 - suffix] {
        suffix += 1
    }

    var ops: [LineEditOp] = []
    ops.reserveCapacity(prefix + suffix + 16)
    for i in 0..<prefix { ops.append(.equal(oldIndex: i, newIndex: i)) }

    let midA = Array(a[prefix..<(a.count - suffix)])
    let midB = Array(b[prefix..<(b.count - suffix)])
    for op in myersDiff(midA, midB) {
        switch op {
        case .equal(let oi, let ni): ops.append(.equal(oldIndex: oi + prefix, newIndex: ni + prefix))
        case .delete(let oi): ops.append(.delete(oldIndex: oi + prefix))
        case .insert(let ni): ops.append(.insert(newIndex: ni + prefix))
        }
    }

    for i in 0..<suffix {
        let oi = a.count - suffix + i, ni = b.count - suffix + i
        ops.append(.equal(oldIndex: oi, newIndex: ni))
    }
    return ops
}

/// Myers' O((n+m)*D) shortest-edit-script algorithm (Myers 1986), the standard diff used by
/// `diff`/git. `a`/`b` are interned line ids. Runtime and the `trace` memory it needs both scale
/// with `D` (the number of non-matching lines), not `n*m` — the property that keeps a
/// 6,000-line plan with a small pocket of edits fast where a plain LCS table would choke.
private func myersDiff(_ a: [Int], _ b: [Int]) -> [LineEditOp] {
    let n = a.count, m = b.count
    if n == 0 && m == 0 { return [] }
    if n == 0 { return (0..<m).map { .insert(newIndex: $0) } }
    if m == 0 { return (0..<n).map { .delete(oldIndex: $0) } }

    let maxD = n + m
    func vIndex(_ k: Int) -> Int { k + maxD }

    var v = [Int](repeating: 0, count: 2 * maxD + 1)
    var trace: [[Int]] = []
    var foundD = -1

    outer: for d in 0...maxD {
        trace.append(v)
        for k in stride(from: -d, through: d, by: 2) {
            let x: Int
            if k == -d || (k != d && v[vIndex(k - 1)] < v[vIndex(k + 1)]) {
                x = v[vIndex(k + 1)]
            } else {
                x = v[vIndex(k - 1)] + 1
            }
            var xi = x, yi = x - k
            while xi < n && yi < m && a[xi] == b[yi] {
                xi += 1; yi += 1
            }
            v[vIndex(k)] = xi
            if xi >= n && yi >= m {
                foundD = d
                break outer
            }
        }
    }

    // Backtrace `trace` from the end point to the origin to recover the edit script, then
    // reverse it into document order.
    var ops: [LineEditOp] = []
    var x = n, y = m
    if foundD > 0 {
        for d in stride(from: foundD, through: 1, by: -1) {
            let vAtD = trace[d]
            let k = x - y
            let prevK: Int
            if k == -d || (k != d && vAtD[vIndex(k - 1)] < vAtD[vIndex(k + 1)]) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let prevX = vAtD[vIndex(prevK)]
            let prevY = prevX - prevK

            while x > prevX && y > prevY {
                ops.append(.equal(oldIndex: x - 1, newIndex: y - 1))
                x -= 1; y -= 1
            }
            if x == prevX {
                ops.append(.insert(newIndex: y - 1))
                y -= 1
            } else {
                ops.append(.delete(oldIndex: x - 1))
                x -= 1
            }
        }
    }
    while x > 0 && y > 0 {
        ops.append(.equal(oldIndex: x - 1, newIndex: y - 1))
        x -= 1; y -= 1
    }
    return ops.reversed()
}

// MARK: - sectionsChanged

/// The nearest preceding `#`-heading text for every line in a document, including the heading
/// line itself (a heading line's own "nearest preceding heading" is itself). Lines before the
/// first heading get the pseudo-heading `"(preamble)"`.
private func headingPerLine(_ lines: [Substring]) -> [String] {
    var result = [String](repeating: "(preamble)", count: lines.count)
    var current = "(preamble)"
    for (i, line) in lines.enumerated() {
        if line.hasPrefix("#") {
            current = String(line).trimmingCharacters(in: .whitespaces)
        }
        result[i] = current
    }
    return result
}

/// Attributes every changed line to a heading, then reports the distinct headings in the new
/// document's order, followed by any headings that exist only in the old document.
///
/// The subtle case is a heading renamed with its body untouched (`## Foo` -> `## Bar`, same
/// lines under it): the diff sees exactly one changed line each side -- the heading line itself,
/// deleted in `old`, inserted in `new` -- which naively would report BOTH "Foo" (old-only) and
/// "Bar" (new). To collapse that into just "Bar", `oldToNewHeading` maps an old heading to
/// whatever new heading its surviving (unchanged, `equal`-matched) body lines now sit under; a
/// `delete` under a mapped-and-thus-still-alive old heading is folded into that new heading
/// instead of standing alone as "old only". Only a heading with NO surviving line at all (the
/// whole section, heading and body, genuinely removed) lands in the old-only bucket.
///
/// The result is sorted by each heading's position in its own document, not by ops-traversal
/// order: a `delete` mapped through `oldToNewHeading` can be reached before an `insert` that's
/// structurally earlier in the new document (an edit script interleaves old/new positions, it
/// doesn't walk either document's order on its own), so collecting into `Set`s first and sorting
/// by `documentOrder` afterward is what actually guarantees "new document's order" rather than
/// just usually matching it — exercised by `testSectionsChangedOrderSurvivesAMovedSection`.
private func sectionsChanged(_ ops: [LineEditOp], oldHeadings: [String], newHeadings: [String]) -> [String] {
    var oldToNewHeading: [String: String] = [:]
    for op in ops {
        if case .equal(let oi, let ni) = op {
            let oldHeading = oldHeadings[oi]
            if oldToNewHeading[oldHeading] == nil {
                oldToNewHeading[oldHeading] = newHeadings[ni]
            }
        }
    }

    // A heading text that also occurs in the new document — most obviously the pseudo-heading
    // "(preamble)", which exists in every document whether or not it changed — is never "old
    // only" even without a body-survival mapping: it's still there, just not the section this
    // particular deleted line happened to map through.
    let newHeadingSet = Set(newHeadings)

    var changedNew = Set<String>()
    var changedOldOnly = Set<String>()

    for op in ops {
        switch op {
        case .insert(let ni):
            changedNew.insert(newHeadings[ni])
        case .delete(let oi):
            let heading = oldHeadings[oi]
            if let mapped = oldToNewHeading[heading] {
                changedNew.insert(mapped)
            } else if !newHeadingSet.contains(heading) {
                changedOldOnly.insert(heading)
            }
        case .equal:
            continue
        }
    }

    let newOrder = documentOrder(newHeadings)
    let oldOrder = documentOrder(oldHeadings)
    let sortedNew = changedNew.sorted { newOrder[$0]! < newOrder[$1]! }
    let sortedOldOnly = changedOldOnly.sorted { oldOrder[$0]! < oldOrder[$1]! }
    return sortedNew + sortedOldOnly
}

/// Maps each distinct heading (as produced by `headingPerLine`) to the line index of its FIRST
/// occurrence — i.e. its rank in document order — so `sectionsChanged` can sort by "where this
/// heading actually sits" instead of "when its change happened to surface in the edit script".
private func documentOrder(_ headingPerLine: [String]) -> [String: Int] {
    var order: [String: Int] = [:]
    for (i, heading) in headingPerLine.enumerated() where order[heading] == nil {
        order[heading] = i
    }
    return order
}

// MARK: - unifiedDiff hunks

private enum OpcodeTag { case equal, changed }

/// A maximal run of same-kind edit-script steps, as old/new line ranges (half-open, 0-based) —
/// the unit `groupedOpcodes` clusters into hunks and `unifiedDiff` renders line-by-line.
private struct Opcode { var tag: OpcodeTag; var i1: Int; var i2: Int; var j1: Int; var j2: Int }

/// Collapses an edit script into maximal equal/changed runs, tracking old/new cursors directly
/// rather than min/max-ing indices -- which is what makes a pure insert (no `old` side) or pure
/// delete (no `new` side) run report the right zero-width range instead of a bogus one.
private func opcodes(from ops: [LineEditOp]) -> [Opcode] {
    var result: [Opcode] = []
    var oldPos = 0, newPos = 0
    var i = 0
    while i < ops.count {
        if case .equal = ops[i] {
            let i1 = oldPos, j1 = newPos
            while i < ops.count, case .equal = ops[i] {
                oldPos += 1; newPos += 1; i += 1
            }
            result.append(Opcode(tag: .equal, i1: i1, i2: oldPos, j1: j1, j2: newPos))
        } else {
            let i1 = oldPos, j1 = newPos
            while i < ops.count {
                if case .equal = ops[i] { break }
                switch ops[i] {
                case .delete: oldPos += 1
                case .insert: newPos += 1
                case .equal: break
                }
                i += 1
            }
            result.append(Opcode(tag: .changed, i1: i1, i2: oldPos, j1: j1, j2: newPos))
        }
    }
    return result
}

/// Ports `difflib.SequenceMatcher.get_grouped_opcodes`: trims unbounded leading/trailing equal
/// runs down to `context` lines, then splits on any interior equal run longer than `2*context`
/// (its middle can't serve as trailing context for one hunk AND leading context for the next),
/// producing exactly the hunks `git diff -U3`/GNU diff would.
private func groupedOpcodes(_ codes: [Opcode], context: Int) -> [[Opcode]] {
    guard !codes.isEmpty else { return [] }
    var codes = codes

    if codes[0].tag == .equal {
        let c = codes[0]
        codes[0] = Opcode(tag: .equal, i1: max(c.i1, c.i2 - context), i2: c.i2,
                           j1: max(c.j1, c.j2 - context), j2: c.j2)
    }
    if codes[codes.count - 1].tag == .equal {
        let c = codes[codes.count - 1]
        codes[codes.count - 1] = Opcode(tag: .equal, i1: c.i1, i2: min(c.i2, c.i1 + context),
                                         j1: c.j1, j2: min(c.j2, c.j1 + context))
    }

    let doubled = context * 2
    var groups: [[Opcode]] = []
    var group: [Opcode] = []
    for code in codes {
        var c = code
        if c.tag == .equal && c.i2 - c.i1 > doubled {
            group.append(Opcode(tag: .equal, i1: c.i1, i2: min(c.i2, c.i1 + context),
                                 j1: c.j1, j2: min(c.j2, c.j1 + context)))
            groups.append(group)
            group = []
            c = Opcode(tag: .equal, i1: max(c.i1, c.i2 - context), i2: c.i2,
                       j1: max(c.j1, c.j2 - context), j2: c.j2)
        }
        group.append(c)
    }
    if !group.isEmpty && !(group.count == 1 && group[0].tag == .equal) {
        groups.append(group)
    }
    return groups
}
