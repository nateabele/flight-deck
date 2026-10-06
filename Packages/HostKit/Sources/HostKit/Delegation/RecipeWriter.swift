import Foundation

/// `flightdeck recipe add` (spec §8): writes one `[recipe.<name>]` table into
/// `.flightdeck/delegate.toml`, in place.
///
/// The file is checked in and hand-edited, so the writer never regenerates it: every byte
/// outside the recipe's own table — comments, ordering, other recipes, routes — is kept. A new
/// recipe is appended; an existing one is replaced where it stands. A regenerating writer
/// would be simpler and would strip a team's comments the first time an agent added a recipe.
public enum RecipeWriter {
    /// `text` with `recipe` written as `[recipe.<name>]`.
    ///
    /// Throws when `text` does not parse (writing into a file the parser cannot read could put a
    /// second copy of a recipe it never saw), when `name` cannot be a table name, and — as a
    /// last check — when the result would not read back as exactly `recipe`.
    public static func add(name: String, recipe: Recipe, to text: String) throws -> String {
        guard !name.isEmpty, !name.unicodeScalars.contains(where: TOMLReader.isControl), !name.contains("\t")
        else {
            throw DelegateConfigIssue(.error, "a recipe name must be non-empty, on one line, with no control characters")
        }
        // A CRLF file stays CRLF: a writer that added LF lines to it would leave mixed endings,
        // which review tools show as a change to every line.
        let crlf = text.utf8.contains(13)
        let eol = crlf ? "\r\n" : "\n"
        let headers = try DelegateConfigParser.headers(in: text)
        // Split on the byte, never on `Character`s: "\r\n" is ONE Character, and on Linux
        // `components(separatedBy: "\n")` compares Characters, so a CRLF file came back as a
        // single line and a replace appended a duplicate table instead.
        var lines = text.utf8.split(separator: 10, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        // `lines` comes from splitting on "\n", so a CRLF file's lines keep their "\r"; the
        // inserted block's lines need one too.
        let block = render(name: name, recipe: recipe).map { crlf ? $0 + "\r" : $0 }

        // Its own table and any `[recipe.<name>.*]` subtables (a hand-written
        // `[recipe.<name>.env]`): the rendered block writes `env` inline, so a leftover subtable
        // would redefine it and the file would stop parsing.
        let owned = headers.indices.filter {
            headers[$0].path.count >= 2 && Array(headers[$0].path.prefix(2)) == ["recipe", name]
        }
        let output: String
        if let first = owned.first {
            var removals: [Range<Int>] = []
            for (n, index) in owned.enumerated() {
                var range = extent(of: index, headers: headers, lines: lines)
                // A removed subtable also takes the blank lines after it, or deleting it would
                // leave a double gap where it stood.
                if n > 0 {
                    while range.upperBound < lines.count, isBlank(lines[range.upperBound]),
                          range.upperBound + 1 < lines.count {
                        range = range.lowerBound..<(range.upperBound + 1)
                    }
                }
                removals.append(range)
            }
            let insertAt = headers[first].line - 1
            for range in removals.reversed() { lines.removeSubrange(range) }
            lines.insert(contentsOf: block, at: insertAt)
            output = lines.joined(separator: "\n")
        } else {
            var prefix = text
            if !prefix.isEmpty && !endsWith(prefix, "\n") { prefix += eol }
            if !prefix.isEmpty && !endsWith(prefix, eol + eol) { prefix += eol }
            output = prefix + block.joined(separator: "\n") + "\n"
        }

        let reread = try DelegateConfigParser.parse(output).config.recipes[name]
        guard reread == recipe else {
            throw DelegateConfigIssue(.error, "recipe \(name) would not read back as written; delegate.toml is unchanged")
        }
        return output
    }

    /// Adds `recipe` to `<projectRoot>/.flightdeck/delegate.toml`, creating the directory and
    /// the file when there are none. Atomic, so an agent's `recipe add` racing the shim watcher
    /// never shows it a half-written file.
    public static func add(name: String, recipe: Recipe, projectRoot: URL) throws {
        let url = DelegateConfigParser.fileURL(projectRoot: projectRoot)
        let existing = FileManager.default.fileExists(atPath: url.path)
            ? try String(contentsOf: url, encoding: .utf8) : ""
        let text = try add(name: name, recipe: recipe, to: existing)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Zero-based lines `[header, end)` belonging to `headers[index]`: up to the next header,
    /// minus the blank and comment lines just before it. Those lead into the *next* table
    /// ("# Comment about ui-tests" above `[recipe.ui-tests]`), so replacing this one must
    /// leave them where they are.
    private static func extent(of index: Int, headers: [TOMLHeader], lines: [String]) -> Range<Int> {
        let start = headers[index].line - 1
        var end = index + 1 < headers.count ? headers[index + 1].line - 1 : lines.count
        while end > start + 1, isBlank(lines[end - 1]) || isComment(lines[end - 1]) { end -= 1 }
        return start..<end
    }

    /// Byte-wise, for the same reason as the split above: `hasSuffix("\n")` is false for a
    /// string ending in the single Character "\r\n".
    private static func endsWith(_ text: String, _ suffix: String) -> Bool {
        text.utf8.reversed().starts(with: suffix.utf8.reversed())
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy(\.isWhitespace)
    }

    private static func isComment(_ line: String) -> Bool {
        line.drop(while: \.isWhitespace).hasPrefix("#")
    }

    /// Only the fields that differ from `Recipe`'s defaults, plus `run`, so a written recipe
    /// reads like a hand-written one. Order is the spec's example order.
    static func render(name: String, recipe: Recipe) -> [String] {
        var lines = ["[recipe.\(key(name))]"]
        if let host = recipe.host { lines.append("host = \(quote(host))") }
        lines.append("run = \(quote(recipe.run))")
        if let down = recipe.down { lines.append("down = \(quote(down))") }
        if recipe.screen { lines.append("screen = true") }
        if recipe.long { lines.append("long = true") }
        if recipe.service { lines.append("service = true") }
        if recipe.restartOnSync { lines.append("restart_on_sync = true") }
        if !recipe.fetch.isEmpty { lines.append("fetch = [\(recipe.fetch.map(quote).joined(separator: ", "))]") }
        if !recipe.ports.isEmpty {
            // `5432`, not `"5432"`: the spec writes a plain port as an integer, and the parser
            // reads either back as the same notation string.
            let ports = recipe.ports.map { port in
                port.allSatisfy(\.isASCII) && !port.isEmpty && port.allSatisfy(\.isNumber) && !port.hasPrefix("0")
                    ? port : quote(port)
            }
            lines.append("ports = [\(ports.joined(separator: ", "))]")
        }
        if !recipe.env.isEmpty {
            let pairs = recipe.env.sorted { $0.key < $1.key }.map { "\(key($0.key)) = \(quote($0.value))" }
            lines.append("env = { \(pairs.joined(separator: ", ")) }")
        }
        if recipe.apply != .review { lines.append("apply = \(quote(recipe.apply.rawValue))") }
        if let pool = recipe.pool { lines.append("pool = \(pool)") }
        if let timeout = recipe.orphanTimeout { lines.append("orphan_timeout = \(timeout)") }
        return lines
    }

    /// A bare key when TOML allows one, otherwise a quoted key.
    private static func key(_ name: String) -> String {
        let bare = !name.isEmpty && name.unicodeScalars.allSatisfy {
            switch $0 {
            case "A"..."Z", "a"..."z", "0"..."9", "_", "-": true
            default: false
            }
        }
        return bare ? name : quote(name)
    }

    /// A TOML basic string. Control characters are escaped, since a raw newline would end the
    /// string mid-line and a raw tab is legal but invisible in review.
    private static func quote(_ value: String) -> String {
        var out = "\""
        for scalar in value.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case _ where scalar.value < 0x20 || scalar.value == 0x7F:
                out += String(format: "\\u%04X", scalar.value)
            default:
                out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }
}
