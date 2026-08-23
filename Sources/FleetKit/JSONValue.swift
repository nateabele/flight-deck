import Foundation

/// One JSON value, **in the order the document wrote it**.
///
/// `JSONSerialization` is not usable for this and that is the whole reason this type exists:
/// it hands back `[String: Any]`, and a Swift `Dictionary` has no order at all. A tool input
/// read as an object with a known shape — `AskUserQuestion`'s `question`, `header`,
/// `multiSelect`, `options` — is read by a person who already knows what the fourth key is,
/// and shuffling those four every launch (a `Dictionary`'s iteration order is seeded per
/// process) makes the tree and the raw text beside it disagree about the same document.
/// So an object is an ARRAY of members here, and the toggle shows two views of one order.
///
/// **Numbers are kept as the lexeme the document wrote**, not as a `Double`. `1.50`, `1e3`
/// and an id past 2^53 all survive a round trip through this type and none of them survives
/// one through `Double`. Nothing here does arithmetic; a viewer's only job with a number is
/// to show the number that is there.
///
/// Pure Foundation, so it can live beside `TimelineItem` in the module both platforms share:
/// the phone draws the tree, and the macOS suite is what runs the parser against a thousand
/// shapes. `indirect` because a value contains values.
public indirect enum JSONValue: Hashable, Sendable {
    /// One `"key": value` pair, in document position. A struct rather than a tuple because a
    /// tuple is not `Hashable` and this type is held in SwiftUI state.
    public struct Member: Hashable, Sendable {
        public let key: String
        public let value: JSONValue

        public init(key: String, value: JSONValue) {
            self.key = key
            self.value = value
        }
    }

    case object([Member])
    case array([JSONValue])
    case string(String)
    /// Verbatim, exactly as written. See the note above.
    case number(String)
    case bool(Bool)
    case null

    /// Whether this node has children to expand. Note that an EMPTY object or array is still
    /// a container — it draws as `{}` / `[]` with nothing under it, which is the honest
    /// answer, where a leaf would imply a value it does not have.
    public var isContainer: Bool {
        switch self {
        case .object, .array: return true
        default: return false
        }
    }

    public var childCount: Int {
        switch self {
        case .object(let members): return members.count
        case .array(let elements): return elements.count
        default: return 0
        }
    }
}

// MARK: - Parsing

extension JSONValue {

    /// The body of a tool call or result, if it is JSON worth drawing as a tree — and `nil`
    /// for every other body, which is most of them.
    ///
    /// **This is allowed to fail and is expected to, constantly.** A `.toolCall`'s text is
    /// pretty-printed JSON cut at `TimelineLimits.maxItemBytes` wherever that lands, so a
    /// truncated input is structurally incomplete BY DESIGN (see `TimelineItem.Body.text`) —
    /// and a `.toolResult` is usually not JSON at all: it is `ls` output, a diff, a stack
    /// trace. `nil` from here means "render the text", which is what the screen did before
    /// this type existed and what it must still do.
    ///
    /// A bare scalar is refused even though it is legal JSON. A `.toolResult` whose whole
    /// text is `42` or `"done"` parses, and a one-node tree of it is strictly worse than the
    /// two characters it replaces. Only an object or an array has structure to show.
    public static func document(from text: String) -> JSONValue? {
        guard let value = parse(text) else { return nil }
        return value.isContainer ? value : nil
    }

    /// Strict RFC 8259, returning `nil` rather than throwing or trapping on anything else.
    ///
    /// Strict on purpose: the fallback is the raw text, which is a good outcome, so there is
    /// nothing to gain by half-reading a broken document and a lot to lose — a tree drawn
    /// from a body cut mid-string would be a confident, wrong picture of what the tool was
    /// asked to do. Trailing content after the value is a failure for the same reason.
    ///
    /// - Parameter maxDepth: How deep nesting may go before the input is refused. This is a
    ///   guard against the stack, not against the data: the parser recurses, and `[` repeated
    ///   a hundred thousand times is a crash rather than a parse error without it. Real tool
    ///   inputs nest four or five deep.
    public static func parse(_ text: String, maxDepth: Int = 64) -> JSONValue? {
        var scanner = Scanner(bytes: Array(text.utf8), maxDepth: maxDepth)
        guard let value = scanner.value(depth: 0) else { return nil }
        scanner.skipWhitespace()
        return scanner.isAtEnd ? value : nil
    }

    /// A hand-rolled recursive-descent scanner over UTF-8 bytes.
    ///
    /// Bytes rather than `Character`s because every structural token in JSON is ASCII, so the
    /// scanner never needs to know where a grapheme boundary is — and the one place that does
    /// (a string's contents) is rebuilt with `String(decoding:as:)`, which substitutes the
    /// replacement character for malformed UTF-8 instead of failing. Nothing in here can trap:
    /// every index is bounds-checked before it is read.
    private struct Scanner {
        let bytes: [UInt8]
        let maxDepth: Int
        var index = 0

        var isAtEnd: Bool { index >= bytes.count }

        private func peek() -> UInt8? { index < bytes.count ? bytes[index] : nil }

        mutating func skipWhitespace() {
            while index < bytes.count {
                switch bytes[index] {
                case 0x20, 0x09, 0x0A, 0x0D: index += 1
                default: return
                }
            }
        }

        /// Consumes a literal ASCII sequence, or leaves the position untouched and fails.
        private mutating func match(_ literal: [UInt8]) -> Bool {
            guard index + literal.count <= bytes.count else { return false }
            for (offset, byte) in literal.enumerated() where bytes[index + offset] != byte {
                return false
            }
            index += literal.count
            return true
        }

        mutating func value(depth: Int) -> JSONValue? {
            guard depth <= maxDepth else { return nil }
            skipWhitespace()
            guard let byte = peek() else { return nil }
            switch byte {
            case UInt8(ascii: "{"): return object(depth: depth)
            case UInt8(ascii: "["): return array(depth: depth)
            case UInt8(ascii: "\""): return string().map(JSONValue.string)
            case UInt8(ascii: "t"): return match(Array("true".utf8)) ? .bool(true) : nil
            case UInt8(ascii: "f"): return match(Array("false".utf8)) ? .bool(false) : nil
            case UInt8(ascii: "n"): return match(Array("null".utf8)) ? .null : nil
            default: return number()
            }
        }

        private mutating func object(depth: Int) -> JSONValue? {
            index += 1  // '{'
            var members: [Member] = []
            skipWhitespace()
            if peek() == UInt8(ascii: "}") { index += 1; return .object(members) }
            while true {
                skipWhitespace()
                guard peek() == UInt8(ascii: "\""), let key = string() else { return nil }
                skipWhitespace()
                guard peek() == UInt8(ascii: ":") else { return nil }
                index += 1
                guard let value = value(depth: depth + 1) else { return nil }
                members.append(Member(key: key, value: value))
                skipWhitespace()
                switch peek() {
                case UInt8(ascii: ","): index += 1
                case UInt8(ascii: "}"): index += 1; return .object(members)
                default: return nil  // a missing comma, or the end of a truncated body
                }
            }
        }

        private mutating func array(depth: Int) -> JSONValue? {
            index += 1  // '['
            var elements: [JSONValue] = []
            skipWhitespace()
            if peek() == UInt8(ascii: "]") { index += 1; return .array(elements) }
            while true {
                guard let value = value(depth: depth + 1) else { return nil }
                elements.append(value)
                skipWhitespace()
                switch peek() {
                case UInt8(ascii: ","): index += 1
                case UInt8(ascii: "]"): index += 1; return .array(elements)
                default: return nil
                }
            }
        }

        /// The bytes between the quotes, with the six escapes and `\uXXXX` resolved.
        ///
        /// Surrogate pairs are joined, because the pair is how JSON spells every emoji and a
        /// tool input carries plenty. A HIGH surrogate not followed by a low one — which is
        /// exactly what a body cut mid-escape leaves — fails rather than producing a lone
        /// scalar that `Unicode.Scalar(_:)` would refuse anyway.
        private mutating func string() -> String? {
            index += 1  // '"'
            var out: [UInt8] = []
            while index < bytes.count {
                let byte = bytes[index]
                if byte == UInt8(ascii: "\"") {
                    index += 1
                    return String(decoding: out, as: UTF8.self)
                }
                if byte == UInt8(ascii: "\\") {
                    index += 1
                    guard let escape = peek() else { return nil }
                    index += 1
                    switch escape {
                    case UInt8(ascii: "\""): out.append(UInt8(ascii: "\""))
                    case UInt8(ascii: "\\"): out.append(UInt8(ascii: "\\"))
                    case UInt8(ascii: "/"): out.append(UInt8(ascii: "/"))
                    case UInt8(ascii: "b"): out.append(0x08)
                    case UInt8(ascii: "f"): out.append(0x0C)
                    case UInt8(ascii: "n"): out.append(0x0A)
                    case UInt8(ascii: "r"): out.append(0x0D)
                    case UInt8(ascii: "t"): out.append(0x09)
                    case UInt8(ascii: "u"):
                        guard let scalar = unicodeEscape() else { return nil }
                        out.append(contentsOf: Array(String(scalar).utf8))
                    default: return nil
                    }
                    continue
                }
                // A control character must be escaped in JSON; an unescaped one means this is
                // not the document it claims to be.
                if byte < 0x20 { return nil }
                out.append(byte)
                index += 1
            }
            return nil  // ran off the end — the usual shape of a body cut at the byte cap
        }

        /// Reads the four hex digits after `\u`, and the `\uXXXX` of a low surrogate after a
        /// high one. Positioned just past the `u`.
        private mutating func unicodeEscape() -> Unicode.Scalar? {
            guard let first = hexQuad() else { return nil }
            if first >= 0xD800 && first <= 0xDBFF {
                guard index + 1 < bytes.count,
                      bytes[index] == UInt8(ascii: "\\"),
                      bytes[index + 1] == UInt8(ascii: "u")
                else { return nil }
                index += 2
                guard let low = hexQuad(), low >= 0xDC00, low <= 0xDFFF else { return nil }
                let combined = 0x10000 + ((first - 0xD800) << 10) + (low - 0xDC00)
                return Unicode.Scalar(combined)
            }
            // A lone LOW surrogate is not a scalar; `Unicode.Scalar(_:)` returns nil and so
            // does this.
            return Unicode.Scalar(first)
        }

        private mutating func hexQuad() -> UInt32? {
            guard index + 4 <= bytes.count else { return nil }
            var value: UInt32 = 0
            for offset in 0..<4 {
                guard let digit = Self.hexDigit(bytes[index + offset]) else { return nil }
                value = value << 4 | UInt32(digit)
            }
            index += 4
            return value
        }

        private static func hexDigit(_ byte: UInt8) -> UInt8? {
            switch byte {
            case UInt8(ascii: "0")...UInt8(ascii: "9"): return byte - UInt8(ascii: "0")
            case UInt8(ascii: "a")...UInt8(ascii: "f"): return byte - UInt8(ascii: "a") + 10
            case UInt8(ascii: "A")...UInt8(ascii: "F"): return byte - UInt8(ascii: "A") + 10
            default: return nil
            }
        }

        /// The full JSON number grammar, kept as its own text. A leading `+`, a leading zero
        /// before another digit, a bare `.5` and a trailing `.` are all refused — they are
        /// what a language that is nearly JSON looks like, and reading one as a number is how
        /// a viewer ends up confidently drawing a tree of a JavaScript literal.
        private mutating func number() -> JSONValue? {
            let start = index
            if peek() == UInt8(ascii: "-") { index += 1 }
            guard let lead = peek() else { return nil }
            if lead == UInt8(ascii: "0") {
                index += 1
            } else if (UInt8(ascii: "1")...UInt8(ascii: "9")).contains(lead) {
                while let byte = peek(), Self.isDigit(byte) { index += 1 }
            } else {
                return nil
            }
            if peek() == UInt8(ascii: ".") {
                index += 1
                guard let byte = peek(), Self.isDigit(byte) else { return nil }
                while let byte = peek(), Self.isDigit(byte) { index += 1 }
            }
            if let byte = peek(), byte == UInt8(ascii: "e") || byte == UInt8(ascii: "E") {
                index += 1
                if let sign = peek(), sign == UInt8(ascii: "+") || sign == UInt8(ascii: "-") {
                    index += 1
                }
                guard let byte = peek(), Self.isDigit(byte) else { return nil }
                while let byte = peek(), Self.isDigit(byte) { index += 1 }
            }
            return .number(String(decoding: bytes[start..<index], as: UTF8.self))
        }

        private static func isDigit(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        }
    }
}

// MARK: - The tree, flattened

/// One line of the tree as it is drawn: a node, how deep it sits, and what it is called there.
///
/// **Flat, not nested.** A recursive view of `DisclosureGroup`s draws the same picture, but the
/// state it needs lives inside SwiftUI, so which nodes are open is unreachable from a test and
/// unreachable from the screen — and "open the first two levels of THIS document" is a decision
/// worth testing. A flat row list makes the expansion set an ordinary value, and the view a
/// `ForEach` over it.
public struct JSONTreeRow: Identifiable, Hashable, Sendable {
    /// The node's position in the document, as ordinals: `"/0/3/1"` is the second child of the
    /// fourth child of the first top-level member.
    ///
    /// Ordinals for object members as well as array elements, deliberately — a path built from
    /// KEY names collides the moment a document repeats a key, which JSON permits, and two
    /// rows with one id in a `ForEach` is a SwiftUI diffing bug rather than a visible one.
    /// This is an identity, not a JSON Pointer, and nothing outside this file reads it.
    public let id: String
    /// 0 for a top-level member. The root object itself gets no row: its members ARE the top
    /// level, which is how Chrome shows a response and which buys back a whole indent step on
    /// a 393pt phone.
    public let depth: Int
    /// The object key this node sits under. `nil` when the parent is an array.
    public let key: String?
    /// The position in the parent array. `nil` when the parent is an object.
    public let index: Int?
    public let value: JSONValue
    /// Whether this node's children are on screen under it. `false` for a leaf — and for an
    /// EMPTY container, which has nothing to put on screen: a chevron rotated open above
    /// nothing reads as a row that failed to load.
    public let isExpanded: Bool

    public var isContainer: Bool { value.isContainer }
    public var childCount: Int { value.childCount }

    public init(
        id: String, depth: Int, key: String?, index: Int?,
        value: JSONValue, isExpanded: Bool
    ) {
        self.id = id
        self.depth = depth
        self.key = key
        self.index = index
        self.value = value
        self.isExpanded = isExpanded
    }
}

extension JSONValue {

    /// The rows to draw, given which nodes are open.
    ///
    /// Iterative rather than recursive: the parser already refuses anything deeper than its
    /// own guard, but this walks whatever it is handed — including a value built in code — and
    /// a viewer that overflows the stack drawing a document it parsed fine is a worse failure
    /// than one that will not parse it.
    public func treeRows(expanded: Set<String>) -> [JSONTreeRow] {
        var rows: [JSONTreeRow] = []
        // Reverse order on the stack, so children are popped left to right.
        var stack: [Child] = children(of: self, parentID: "", depth: 0).reversed()
        while let node = stack.popLast() {
            let open = node.value.childCount > 0 && expanded.contains(node.id)
            rows.append(
                JSONTreeRow(
                    id: node.id, depth: node.depth, key: node.key, index: node.index,
                    value: node.value, isExpanded: open
                )
            )
            if open {
                stack.append(
                    contentsOf: children(
                        of: node.value, parentID: node.id, depth: node.depth + 1
                    ).reversed()
                )
            }
        }
        return rows
    }

    /// Which nodes are open when a document is first shown.
    ///
    /// Two levels, then stop — the top-level members and their children. On the shape this was
    /// built for that is exactly right: `AskUserQuestion` opens showing the question, its
    /// header and its `multiSelect` flag, with `options: [3]` collapsed beside them, which is
    /// the summary a reader wants before they decide to go in.
    ///
    /// **And a budget, because the depth rule alone is not safe.** A single top-level array of
    /// four hundred objects is two levels deep and would open as four hundred rows nobody
    /// asked for. Containers are opened breadth-first and stop being opened once the visible
    /// rows would pass `maxRows`; breadth-first is what makes that deterministic rather than
    /// dependent on which branch was walked first.
    public func defaultExpansion(maxDepth: Int = 1, maxRows: Int = 200) -> Set<String> {
        var expanded: Set<String> = []
        var frontier = children(of: self, parentID: "", depth: 0)
        // The top level is drawn whether or not anything is expanded, so it is spent up front.
        var budget = maxRows - frontier.count
        while !frontier.isEmpty {
            var next: [Child] = []
            for node in frontier where node.value.childCount > 0 && node.depth <= maxDepth {
                guard node.value.childCount <= budget else { continue }
                expanded.insert(node.id)
                budget -= node.value.childCount
                next.append(
                    contentsOf: children(
                        of: node.value, parentID: node.id, depth: node.depth + 1
                    )
                )
            }
            frontier = next
        }
        return expanded
    }

    /// A node on its way to becoming a row: everything `JSONTreeRow` needs except whether it
    /// is open, which only the caller knows.
    private typealias Child = (
        id: String, depth: Int, key: String?, index: Int?, value: JSONValue
    )

    private func children(of value: JSONValue, parentID: String, depth: Int) -> [Child] {
        switch value {
        case .object(let members):
            return members.enumerated().map {
                ("\(parentID)/\($0.offset)", depth, $0.element.key, nil, $0.element.value)
            }
        case .array(let elements):
            return elements.enumerated().map {
                ("\(parentID)/\($0.offset)", depth, nil, $0.offset, $0.element)
            }
        default:
            return []
        }
    }
}
