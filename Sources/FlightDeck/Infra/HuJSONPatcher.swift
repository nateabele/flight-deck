import Foundation

/// Adds Flight Deck's two tailnet policy rules (spec §6.1) to a HuJSON policy file as text
/// insertions, so every comment, blank line and trailing comma the user wrote survives:
/// re-serialising through `JSONSerialization` would strip the comments that document most
/// real policies, and the setup sheet shows the user the exact diff before applying it.
///
/// - `"tagOwners": { "<tag>": ["<ownerAutogroup>"] }`, merged into an existing `tagOwners`;
/// - one `grants` entry from `autogroup:member` (this user's devices) to the tag on the
///   delegation ports. Nothing grants the tag itself anything.
enum HuJSONPatcher {
    struct Patch: Equatable {
        let original: String
        let patched: String
        /// Line diff, `+`/`-` prefixed, two lines of context. Empty when nothing changed.
        let diff: String
    }

    /// Nil when the policy cannot be patched safely — a tokenizer error, a top level that is
    /// not an object, a duplicate key, or a `tagOwners`/`grants` of the wrong shape. The caller
    /// then copies the snippet and opens the policy editor instead (spec §9).
    static func addFlightDeckRules(to policy: String, tag: String, ownerAutogroup: String) -> Patch? {
        let bytes = Array(policy.utf8)
        var parser = Parser(bytes)
        guard let root = try? parser.document(), case .object(let top, _) = root.kind else { return nil }
        let owners = top.first { $0.key == "tagOwners" }?.value
        let grants = top.first { $0.key == "grants" }?.value
        if let owners, !owners.isObject { return nil }
        if let grants, !grants.isArray { return nil }

        let ownerEntry = ownerEntry(tag: tag, ownerAutogroup: ownerAutogroup)
        let grantEntry = grantEntry(tag: tag)
        let editor = Editor(bytes: bytes)
        var edits: [Edit] = []
        var topLevel: [String] = []

        if let owners, case .object(let members, _) = owners.kind {
            if !members.contains(where: { $0.key == tag }) { edits += editor.insert([ownerEntry], into: owners) }
        } else {
            topLevel.append("\"tagOwners\": {\(ownerEntry)}")
        }
        if let grants, case .array(let elements, _) = grants.kind {
            if !elements.contains(where: { grantsTo(tag, $0) }) { edits += editor.insert([grantEntry], into: grants) }
        } else {
            topLevel.append("\"grants\": [\(grantEntry)]")
        }
        if !topLevel.isEmpty { edits += editor.insert(topLevel, into: root) }

        let patched = edits.isEmpty ? policy : apply(edits, to: bytes)
        return Patch(original: policy, patched: patched, diff: LineDiff.unified(policy, patched, context: 2))
    }

    /// The two rules as text to paste into the policy editor by hand, for when
    /// `addFlightDeckRules` cannot place them safely: the same entries it would insert.
    static func snippet(tag: String, ownerAutogroup: String) -> String {
        """
        "tagOwners": {\(ownerEntry(tag: tag, ownerAutogroup: ownerAutogroup))},
        "grants": [\(grantEntry(tag: tag))],
        """
    }

    private static func ownerEntry(tag: String, ownerAutogroup: String) -> String {
        "\(quote(tag)): [\(quote(ownerAutogroup))]"
    }

    private static func grantEntry(tag: String) -> String {
        "{\"src\": [\"autogroup:member\"], \"dst\": [\(quote(tag))], \"ip\": [\(quote(ports))]}"
    }

    /// The delegation ports, as the grant's `ip` names them.
    private static let ports = "tcp:47410-47411"

    /// A grant whose `dst` names the tag and whose `ip` names the delegation ports — the user's
    /// own wording of the rule counts, but a grant to the tag on other ports (an SSH rule) does
    /// not stand in for ours.
    private static func grantsTo(_ tag: String, _ node: Node) -> Bool {
        guard case .object(let members, _) = node.kind else { return false }
        func strings(_ key: String) -> [String] {
            guard let value = members.first(where: { $0.key == key })?.value,
                  case .array(let items, _) = value.kind else { return [] }
            return items.compactMap { if case .string(let s) = $0.kind { return s } else { return nil } }
        }
        return strings("dst").contains(tag) && strings("ip").contains(ports)
    }

    private static func quote(_ s: String) -> String {
        var out = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case _ where scalar.value < 0x20: out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// Edits are insertions only; a stable sort keeps two at the same offset in the order made.
    private static func apply(_ edits: [Edit], to bytes: [UInt8]) -> String {
        var out: [UInt8] = []
        var cursor = 0
        for edit in edits.enumerated().sorted(by: { ($0.element.offset, $0.offset) < ($1.element.offset, $1.offset) }).map(\.element) {
            out += bytes[cursor..<edit.offset]
            out += Array(edit.text.utf8)
            cursor = edit.offset
        }
        out += bytes[cursor...]
        return String(decoding: out, as: UTF8.self)
    }

    // MARK: - Syntax

    private struct Edit { let offset: Int; let text: String }

    private struct Member { let key: String; let start: Int; let value: Node }

    private struct Node {
        enum Kind {
            /// The `Bool` is whether a comma follows the last item.
            case object([Member], trailingComma: Bool)
            case array([Node], trailingComma: Bool)
            case string(String)
            case scalar
        }
        let kind: Kind
        /// First byte, and one past the last (the closing bracket, for a container).
        let start: Int
        let end: Int

        var isObject: Bool { if case .object = kind { return true } else { return false } }
        var isArray: Bool { if case .array = kind { return true } else { return false } }
    }

    private struct SyntaxError: Error {}

    /// Recursive descent over HuJSON: JSON plus `//` and `/* */` comments and trailing commas.
    /// It records byte offsets rather than building values, because offsets are all an
    /// insertion needs; strings are decoded only so keys and tags can be compared.
    private struct Parser {
        let bytes: [UInt8]
        var i = 0
        var depth = 0

        init(_ bytes: [UInt8]) { self.bytes = bytes }

        mutating func document() throws -> Node {
            try skipTrivia()
            let root = try value()
            try skipTrivia()
            guard i == bytes.count else { throw SyntaxError() }
            return root
        }

        private mutating func value() throws -> Node {
            guard i < bytes.count else { throw SyntaxError() }
            switch bytes[i] {
            case UInt8(ascii: "{"): return try container(close: UInt8(ascii: "}"))
            case UInt8(ascii: "["): return try container(close: UInt8(ascii: "]"))
            case UInt8(ascii: "\""):
                let start = i
                return Node(kind: .string(try string()), start: start, end: i)
            default: return try literal()
            }
        }

        private mutating func container(close: UInt8) throws -> Node {
            // A pathological nesting must not overflow the stack of the app parsing it.
            depth += 1; defer { depth -= 1 }
            guard depth < 256 else { throw SyntaxError() }
            let start = i, isObject = close == UInt8(ascii: "}")
            i += 1
            var members: [Member] = [], elements: [Node] = [], keys = Set<String>()
            var trailingComma = false
            while true {
                try skipTrivia()
                guard i < bytes.count else { throw SyntaxError() }
                if bytes[i] == close { break }
                if isObject {
                    guard bytes[i] == UInt8(ascii: "\"") else { throw SyntaxError() }
                    let keyStart = i
                    let key = try string()
                    // Which of two duplicates Tailscale honours is not ours to guess.
                    guard keys.insert(key).inserted else { throw SyntaxError() }
                    try skipTrivia()
                    guard i < bytes.count, bytes[i] == UInt8(ascii: ":") else { throw SyntaxError() }
                    i += 1
                    try skipTrivia()
                    members.append(Member(key: key, start: keyStart, value: try value()))
                } else {
                    elements.append(try value())
                }
                try skipTrivia()
                guard i < bytes.count else { throw SyntaxError() }
                if bytes[i] == UInt8(ascii: ",") {
                    i += 1; trailingComma = true; continue
                }
                guard bytes[i] == close else { throw SyntaxError() }
                trailingComma = false
                break
            }
            i += 1
            let kind: Node.Kind = isObject ? .object(members, trailingComma: trailingComma)
                                           : .array(elements, trailingComma: trailingComma)
            return Node(kind: kind, start: start, end: i)
        }

        private mutating func string() throws -> String {
            i += 1
            var out = "", run = i
            while true {
                guard i < bytes.count else { throw SyntaxError() }
                let b = bytes[i]
                if b == UInt8(ascii: "\"") { break }
                guard b >= 0x20 else { throw SyntaxError() }
                guard b == UInt8(ascii: "\\") else { i += 1; continue }
                out += String(decoding: bytes[run..<i], as: UTF8.self)
                i += 1
                guard i < bytes.count else { throw SyntaxError() }
                switch bytes[i] {
                case UInt8(ascii: "\""): out += "\""
                case UInt8(ascii: "\\"): out += "\\"
                case UInt8(ascii: "/"): out += "/"
                case UInt8(ascii: "b"): out += "\u{08}"
                case UInt8(ascii: "f"): out += "\u{0C}"
                case UInt8(ascii: "n"): out += "\n"
                case UInt8(ascii: "r"): out += "\r"
                case UInt8(ascii: "t"): out += "\t"
                case UInt8(ascii: "u"):
                    var units: [UInt16] = [try hex4()]
                    // A surrogate pair is two escapes; decode them together.
                    if (0xD800..<0xDC00).contains(units[0]), i + 2 < bytes.count,
                       bytes[i + 1] == UInt8(ascii: "\\"), bytes[i + 2] == UInt8(ascii: "u") {
                        i += 2
                        units.append(try hex4())
                    }
                    out += String(decoding: units, as: UTF16.self)
                default: throw SyntaxError()
                }
                i += 1
                run = i
            }
            out += String(decoding: bytes[run..<i], as: UTF8.self)
            i += 1
            return out
        }

        /// The four hex digits after `\u`; leaves `i` on the last of them.
        private mutating func hex4() throws -> UInt16 {
            guard i + 4 < bytes.count,
                  let unit = UInt16(String(decoding: bytes[(i + 1)...(i + 4)], as: UTF8.self), radix: 16)
            else { throw SyntaxError() }
            i += 4
            return unit
        }

        /// `true`, `false`, `null`, or a number in JSON's own grammar —
        /// `-? (0 | [1-9][0-9]*) (. [0-9]+)? ([eE] [+-]? [0-9]+)?`. Not `Double(_:)`, which
        /// takes `nan`, `inf` and hex that Tailscale's parser rejects. Whatever follows is left
        /// to the container, which refuses anything but a separator (`01`, `0x10`).
        private mutating func literal() throws -> Node {
            let start = i
            for word in ["true", "false", "null"] where bytes[i...].starts(with: word.utf8) {
                i += word.utf8.count
                return Node(kind: .scalar, start: start, end: i)
            }
            _ = take("-")
            if !take("0") { guard digits() else { throw SyntaxError() } }
            if take(".") { guard digits() else { throw SyntaxError() } }
            if take("e") || take("E") {
                _ = take("+") || take("-")
                guard digits() else { throw SyntaxError() }
            }
            return Node(kind: .scalar, start: start, end: i)
        }

        private mutating func take(_ ascii: Unicode.Scalar) -> Bool {
            guard i < bytes.count, bytes[i] == UInt8(ascii: ascii) else { return false }
            i += 1
            return true
        }

        /// One or more ASCII digits; false, consuming nothing, when there are none.
        private mutating func digits() -> Bool {
            let start = i
            while i < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[i]) { i += 1 }
            return i > start
        }

        private mutating func skipTrivia() throws {
            while i < bytes.count {
                switch bytes[i] {
                case UInt8(ascii: " "), UInt8(ascii: "\t"), UInt8(ascii: "\n"), UInt8(ascii: "\r"):
                    i += 1
                case UInt8(ascii: "/"):
                    guard i + 1 < bytes.count else { throw SyntaxError() }
                    if bytes[i + 1] == UInt8(ascii: "/") {
                        while i < bytes.count, bytes[i] != UInt8(ascii: "\n") { i += 1 }
                    } else if bytes[i + 1] == UInt8(ascii: "*") {
                        i += 2
                        while true {
                            guard i + 1 < bytes.count else { throw SyntaxError() }
                            if bytes[i] == UInt8(ascii: "*"), bytes[i + 1] == UInt8(ascii: "/") { i += 2; break }
                            i += 1
                        }
                    } else {
                        throw SyntaxError()
                    }
                default:
                    return
                }
            }
        }
    }

    /// Where an insertion goes and how it is indented, read off the text around it.
    private struct Editor {
        let bytes: [UInt8]

        /// `entries` go after the container's last item. A closing bracket on a line of its own
        /// gets each entry on a new line above it, indented like the last item (a tab or four
        /// spaces past the bracket when that item shares a line); a one-line container gets
        /// them inline. Every entry ends in a comma, HuJSON style, and a last item without one
        /// gets one.
        func insert(_ entries: [String], into container: Node) -> [Edit] {
            let items: [(start: Int, end: Int)]
            let trailingComma: Bool
            switch container.kind {
            case .object(let members, let comma): items = members.map { ($0.start, $0.value.end) }; trailingComma = comma
            case .array(let elements, let comma): items = elements.map { ($0.start, $0.end) }; trailingComma = comma
            default: return []
            }
            let close = container.end - 1
            var edits: [Edit] = []
            if let last = items.last, !trailingComma { edits.append(Edit(offset: last.end, text: ",")) }
            if let closeIndent = indentation(ofLineStartingAt: close) {
                let unit = closeIndent.contains("\t") ? "\t" : "    "
                let indent = items.last.flatMap { indentation(ofLineStartingAt: $0.start) } ?? closeIndent + unit
                let lines = entries.map { "\(indent)\($0),\n" }.joined()
                edits.append(Edit(offset: close - closeIndent.utf8.count, text: lines))
            } else {
                let space = close > 0 && [UInt8(ascii: " "), UInt8(ascii: "\t")].contains(bytes[close - 1]) ? "" : " "
                edits.append(Edit(offset: close, text: space + entries.map { "\($0), " }.joined()))
            }
            return edits
        }

        /// The whitespace before `offset` back to the start of its line, or nil when anything
        /// else precedes it on that line.
        private func indentation(ofLineStartingAt offset: Int) -> String? {
            var j = offset
            while j > 0, bytes[j - 1] == UInt8(ascii: " ") || bytes[j - 1] == UInt8(ascii: "\t") { j -= 1 }
            guard j == 0 || bytes[j - 1] == UInt8(ascii: "\n") else { return nil }
            return String(decoding: bytes[j..<offset], as: UTF8.self)
        }
    }
}

/// A minimal line diff for showing a patch: LCS over the lines that differ, hunks with
/// `context` lines either side.
enum LineDiff {
    static func unified(_ old: String, _ new: String, context: Int) -> String {
        guard old != new else { return "" }
        let a = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let b = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let ops = operations(a, b)

        // Keep every change and `context` lines either side; a gap of unkept lines ends a hunk.
        var kept = Array(repeating: false, count: ops.count)
        for (index, op) in ops.enumerated() where op.0 != " " {
            for k in max(0, index - context)...min(ops.count - 1, index + context) { kept[k] = true }
        }
        var hunks: [[(Character, String, Int, Int)]] = [[]]
        for (index, op) in ops.enumerated() {
            if kept[index] { hunks[hunks.count - 1].append(op) } else if !hunks[hunks.count - 1].isEmpty { hunks.append([]) }
        }
        hunks.removeAll { $0.isEmpty }

        return hunks.map { hunk in
            let oldCount = hunk.filter { $0.0 != "+" }.count, newCount = hunk.filter { $0.0 != "-" }.count
            let header = "@@ -\(hunk[0].2 + 1),\(oldCount) +\(hunk[0].3 + 1),\(newCount) @@"
            return ([header] + hunk.map { "\($0.0)\($0.1)" }).joined(separator: "\n")
        }.joined(separator: "\n") + "\n"
    }

    /// (marker, line, index in old, index in new) for every line, in order.
    private static func operations(_ a: [String], _ b: [String]) -> [(Character, String, Int, Int)] {
        // Trim the shared ends first: the table below is quadratic in what remains.
        var prefix = 0
        while prefix < min(a.count, b.count), a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < min(a.count, b.count) - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let x = Array(a[prefix..<(a.count - suffix)]), y = Array(b[prefix..<(b.count - suffix)])

        var lcs = Array(repeating: Array(repeating: Int32(0), count: y.count + 1), count: x.count + 1)
        for i in stride(from: x.count - 1, through: 0, by: -1) {
            for j in stride(from: y.count - 1, through: 0, by: -1) {
                lcs[i][j] = x[i] == y[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var ops = (0..<prefix).map { (Character(" "), a[$0], $0, $0) }
        var i = 0, j = 0
        while i < x.count || j < y.count {
            if i < x.count, j < y.count, x[i] == y[j] {
                ops.append((" ", x[i], prefix + i, prefix + j)); i += 1; j += 1
            } else if i < x.count, j == y.count || lcs[i + 1][j] >= lcs[i][j + 1] {
                // Removals first on a tie, so a changed line reads `-old` then `+new`.
                ops.append(("-", x[i], prefix + i, prefix + j)); i += 1
            } else {
                ops.append(("+", y[j], prefix + i, prefix + j)); j += 1
            }
        }
        ops += (0..<suffix).map { k in (" ", a[a.count - suffix + k], a.count - suffix + k, b.count - suffix + k) }
        return ops
    }
}
