import Foundation

/// One problem in `delegate.toml`: a parse error (thrown), an unknown key (a warning beside a
/// successful parse), or a `validate` finding.
///
/// One type for all three, because `flightdeck recipe check` prints them as one list and the
/// preflight's 125 line names the first error; two parallel types would make every consumer
/// merge them.
public struct DelegateConfigIssue: Error, Sendable, Equatable, CustomStringConvertible {
    public enum Severity: String, Sendable {
        case warning
        case error
    }

    public let severity: Severity
    /// 1-based. Nil when the issue is about the config as a whole rather than a line of it —
    /// `validate` works on the parsed values, which no longer carry lines.
    public let line: Int?
    public let message: String

    public init(_ severity: Severity, line: Int? = nil, _ message: String) {
        self.severity = severity
        self.line = line
        self.message = message
    }

    /// `delegate.toml:12: error: …`, the compiler shape, so an agent reading it knows which
    /// line to open without being told.
    public var description: String {
        "delegate.toml\(line.map { ":\($0)" } ?? ""): \(severity.rawValue): \(message)"
    }
}

public struct DelegateConfigParseResult: Sendable, Equatable {
    public let config: DelegateConfig
    /// Unknown keys and tables, in line order. Warnings and not errors so a file written for a
    /// newer Flight Deck still runs on an older one, minus the feature it cannot see.
    public let warnings: [DelegateConfigIssue]
}

/// Parses `.flightdeck/delegate.toml` (spec §8).
///
/// Foundation has no TOML reader, and this is not one either: it reads the subset §8 uses —
/// top-level keys, `[recipe.<name>]` (and `[recipe.<name>.env]`), `[[route]]`, dotted and
/// quoted keys, basic and literal strings, booleans, integers, arrays (which may span lines,
/// with comments and a trailing comma) and inline tables. Anything else — multi-line strings,
/// floats, dates — is a parse error that names its line, never a silent misread.
public enum DelegateConfigParser {
    /// Where the file lives, relative to the project root.
    public static let relativePath = ".flightdeck/delegate.toml"

    public static func fileURL(projectRoot: URL) -> URL {
        projectRoot.appendingPathComponent(relativePath)
    }

    /// The project's config, or nil when it has none. A missing file is the normal case for a
    /// project that never delegates, so it is not an error.
    public static func load(projectRoot: URL) throws -> DelegateConfigParseResult? {
        let url = fileURL(projectRoot: projectRoot)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        // Decoded here rather than by `String(contentsOf:encoding:)`, whose Cocoa error would
        // reach `recipe check` and the 125 line as an opaque "couldn't be opened" with no hint
        // that the file is simply in the wrong encoding.
        guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
            throw DelegateConfigIssue(.error, "delegate.toml is not valid UTF-8; save it as UTF-8")
        }
        return try parse(text)
    }

    /// Throws the first `DelegateConfigIssue` with severity `.error`.
    public static func parse(_ text: String) throws -> DelegateConfigParseResult {
        var reader = TOMLReader(text)
        let document = try reader.read()
        var warnings: [DelegateConfigIssue] = []
        let config = try map(document.root, warnings: &warnings)
        return DelegateConfigParseResult(
            config: config, warnings: warnings.sorted { ($0.line ?? 0) < ($1.line ?? 0) })
    }

    /// Every table header, in file order. `RecipeWriter` replaces a recipe by its header's
    /// line rather than by scanning for `[`: a line inside a multi-line array can start with
    /// `[` too, and only the reader knows which lines are headers.
    static func headers(in text: String) throws -> [TOMLHeader] {
        var reader = TOMLReader(text)
        return try reader.read().headers
    }

    // MARK: - Mapping the generic tree onto DelegateConfig

    private static func map(_ root: TOMLTable, warnings: inout [DelegateConfigIssue]) throws -> DelegateConfig {
        var config = DelegateConfig()
        for (key, node) in root.ordered {
            switch key {
            case "default_host":
                config.defaultHost = try string(node, "default_host")
            case "include":
                config.include = try strings(node, "include")
            case "recipe":
                guard case .table(let recipes) = node else {
                    throw DelegateConfigIssue(.error, line: node.line, "recipe must be a table of [recipe.<name>] tables")
                }
                for (name, recipeNode) in recipes.ordered {
                    guard case .table(let table) = recipeNode else {
                        throw DelegateConfigIssue(.error, line: recipeNode.line, "recipe.\(name) must be a [recipe.\(name)] table")
                    }
                    config.recipes[name] = try recipe(table, name: name, warnings: &warnings)
                }
            case "route":
                guard case .tables(let tables) = node else {
                    throw DelegateConfigIssue(.error, line: node.line, "route must be written as [[route]] tables")
                }
                config.routes = try tables.map { try route($0, warnings: &warnings) }
            default:
                let kind = if case .value = node { "key" } else { "table" }
                warnings.append(DelegateConfigIssue(.warning, line: node.line, "unknown \(kind) \(key) (ignored)"))
            }
        }
        return config
    }

    private static func recipe(_ table: TOMLTable, name: String,
                               warnings: inout [DelegateConfigIssue]) throws -> Recipe {
        let path = "recipe.\(name)"
        guard let runNode = table.entries["run"] else {
            throw DelegateConfigIssue(.error, line: table.line, "\(path) has no run command")
        }
        var recipe = Recipe(run: try string(runNode, "\(path).run"))
        for (key, node) in table.ordered {
            let field = "\(path).\(key)"
            switch key {
            case "run": break
            case "host": recipe.host = try string(node, field)
            case "down": recipe.down = try string(node, field)
            case "screen": recipe.screen = try bool(node, field)
            case "long": recipe.long = try bool(node, field)
            case "service": recipe.service = try bool(node, field)
            case "restart_on_sync": recipe.restartOnSync = try bool(node, field)
            case "fetch": recipe.fetch = try strings(node, field)
            case "ports": recipe.ports = try ports(node, field)
            case "env": recipe.env = try env(node, field)
            case "pool": recipe.pool = try int(node, field)
            case "orphan_timeout": recipe.orphanTimeout = try int(node, field)
            case "apply":
                guard let mode = ApplyMode(rawValue: try string(node, field)) else {
                    throw DelegateConfigIssue(.error, line: node.line, "\(field) must be \"review\" or \"auto\"")
                }
                recipe.apply = mode
            default:
                warnings.append(DelegateConfigIssue(.warning, line: node.line, "unknown key \(field) (ignored)"))
            }
        }
        return recipe
    }

    private static func route(_ table: TOMLTable, warnings: inout [DelegateConfigIssue]) throws -> Route {
        guard let match = table.entries["match"] else {
            throw DelegateConfigIssue(.error, line: table.line, "[[route]] has no match pattern")
        }
        guard let recipe = table.entries["recipe"] else {
            throw DelegateConfigIssue(.error, line: table.line, "[[route]] names no recipe")
        }
        for (key, node) in table.ordered where key != "match" && key != "recipe" {
            warnings.append(DelegateConfigIssue(.warning, line: node.line, "unknown key \(key) in [[route]] (ignored)"))
        }
        return Route(match: try string(match, "route.match"), recipe: try string(recipe, "route.recipe"))
    }

    private static func string(_ node: TOMLNode, _ field: String) throws -> String {
        guard case .value(.string(let value), _) = node else {
            throw DelegateConfigIssue(.error, line: node.line, "\(field) must be a string")
        }
        return value
    }

    private static func bool(_ node: TOMLNode, _ field: String) throws -> Bool {
        guard case .value(.bool(let value), _) = node else {
            throw DelegateConfigIssue(.error, line: node.line, "\(field) must be true or false")
        }
        return value
    }

    private static func int(_ node: TOMLNode, _ field: String) throws -> Int {
        guard case .value(.int(let value), _) = node else {
            throw DelegateConfigIssue(.error, line: node.line, "\(field) must be an integer")
        }
        return value
    }

    private static func strings(_ node: TOMLNode, _ field: String) throws -> [String] {
        guard case .value(.array(let items), _) = node else {
            throw DelegateConfigIssue(.error, line: node.line, "\(field) must be an array of strings")
        }
        return try items.map {
            guard case .string(let value) = $0 else {
                throw DelegateConfigIssue(.error, line: node.line, "\(field) must be an array of strings")
            }
            return value
        }
    }

    /// `[5432, "8080:80"]`: integers and strings side by side, all kept as notation strings.
    /// Whether each one *parses* is `validate`'s question, so a bad port is reported with the
    /// rest of the file's problems by `recipe check` rather than ending the parse.
    private static func ports(_ node: TOMLNode, _ field: String) throws -> [String] {
        let message = "\(field) must be an array of ports: 5432, \"8080:80\" or \"auto:3000\""
        guard case .value(.array(let items), _) = node else {
            throw DelegateConfigIssue(.error, line: node.line, message)
        }
        return try items.map {
            switch $0 {
            case .int(let port): String(port)
            case .string(let notation): notation
            default: throw DelegateConfigIssue(.error, line: node.line, message)
            }
        }
    }

    /// `env = { K = "v" }` or a `[recipe.<name>.env]` table; values must be strings, since
    /// they become environment variables verbatim and `1` vs `"1"` is not a distinction the
    /// environment has.
    private static func env(_ node: TOMLNode, _ field: String) throws -> [String: String] {
        let pairs: [(String, TOMLValue, Int)]
        switch node {
        case .value(.inlineTable(let entries), let line):
            pairs = entries.map { ($0.key, $0.value, line) }
        case .table(let table):
            pairs = try table.ordered.map { key, child in
                guard case .value(let value, let line) = child else {
                    throw DelegateConfigIssue(.error, line: child.line, "\(field).\(key) must be a string")
                }
                return (key, value, line)
            }
        default:
            throw DelegateConfigIssue(.error, line: node.line, "\(field) must be a table of strings")
        }
        var env: [String: String] = [:]
        for (key, value, line) in pairs {
            guard case .string(let string) = value else {
                throw DelegateConfigIssue(.error, line: line, "\(field).\(key) must be a string")
            }
            env[key] = string
        }
        return env
    }
}

// MARK: - validate()

extension DelegateConfig {
    /// The file's semantic problems, after a successful parse (spec §8, `recipe check`; §7
    /// preflight step 1).
    ///
    /// `hosts` maps each paired host's name to its platform (`HostInfo.platform`: "macOS",
    /// "Linux"). Nil means the caller knows no hosts, and every host check is skipped rather
    /// than calling every name unknown.
    ///
    /// - An unknown host is a **warning**: a recipe for a host not paired on *this* Mac is
    ///   normal in a checked-in file shared by a team.
    /// - A port that does not parse, or two entries for one remote port, is an **error**.
    /// - A `screen` recipe on a Linux host is an **error**, and only here, never at parse time:
    ///   parsing cannot know a host's platform, and the same file is valid for a teammate whose
    ///   `mini` is a Mac.
    /// - A route to a recipe that does not exist is an **error**; one whose command is a glob or
    ///   a path is a **warning**, since no shim can intercept it.
    public func validate(hosts: [String: String]? = nil) -> [DelegateConfigIssue] {
        var issues: [DelegateConfigIssue] = []
        if let hosts, let defaultHost, hosts[defaultHost] == nil {
            issues.append(DelegateConfigIssue(.warning, "default_host \"\(defaultHost)\" is not a paired host"))
        }
        for (name, recipe) in recipes.sorted(by: { $0.key < $1.key }) {
            let path = "recipe.\(name)"
            if recipe.run.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                issues.append(DelegateConfigIssue(.error, "\(path).run is empty"))
            }
            if let pool = recipe.pool, pool < 1 {
                issues.append(DelegateConfigIssue(.error, "\(path).pool must be at least 1, not \(pool)"))
            }
            if let timeout = recipe.orphanTimeout, timeout < 1 {
                issues.append(DelegateConfigIssue(.error, "\(path).orphan_timeout must be at least 1 second, not \(timeout)"))
            }
            if let hosts, let host = recipe.host, hosts[host] == nil {
                issues.append(DelegateConfigIssue(.warning, "\(path).host \"\(host)\" is not a paired host"))
            }
            var remotes: Set<UInt16> = []
            for notation in recipe.ports {
                guard let mapping = try? PortMapping.parse(notation) else {
                    issues.append(DelegateConfigIssue(
                        .error, "\(path).ports: \"\(notation)\" is not N, L:R or auto:R with ports 1–65535"))
                    continue
                }
                if !remotes.insert(mapping.remote).inserted {
                    issues.append(DelegateConfigIssue(
                        .error, "\(path).ports maps remote port \(mapping.remote) more than once"))
                }
            }
            if recipe.screen, let host = recipe.host ?? defaultHost,
               let platform = hosts?[host], platform.lowercased() == "linux" {
                issues.append(DelegateConfigIssue(
                    .error, "\(path) needs the screen, but \(host) is a Linux host; screen runs need a macOS host"))
            }
        }
        for route in routes {
            if recipes[route.recipe] == nil {
                issues.append(DelegateConfigIssue(
                    .error, "route \"\(route.match)\" names recipe \"\(route.recipe)\", which is not defined"))
            }
            if RouteMatcher.commandName(of: route.match) == nil {
                issues.append(DelegateConfigIssue(
                    .warning, "route \"\(route.match)\" does not start with a plain command name, so no shim can route it"))
            }
        }
        return issues
    }
}

// MARK: - The generic TOML tree

enum TOMLValue: Equatable {
    case string(String)
    case int(Int)
    case bool(Bool)
    case array([TOMLValue])
    case inlineTable([String: TOMLValue])
}

/// A class so a header can reopen a table already in the tree and add to it in place, which
/// is what `[recipe.svc.env]` before `[recipe.svc]` needs.
final class TOMLTable {
    var entries: [String: TOMLNode] = [:]
    private(set) var order: [String] = []
    let line: Int
    /// Defined by its own header, as opposed to created on the way to a deeper one. TOML lets
    /// an implicit table be defined explicitly once, and never an explicit one twice.
    var explicit: Bool

    init(line: Int, explicit: Bool) {
        self.line = line
        self.explicit = explicit
    }

    var ordered: [(String, TOMLNode)] { order.compactMap { key in entries[key].map { (key, $0) } } }

    func set(_ key: String, _ node: TOMLNode) {
        if entries[key] == nil { order.append(key) }
        entries[key] = node
    }
}

enum TOMLNode {
    case value(TOMLValue, line: Int)
    case table(TOMLTable)
    case tables([TOMLTable])

    var line: Int {
        switch self {
        case .value(_, let line): line
        case .table(let table): table.line
        case .tables(let tables): tables.first?.line ?? 0
        }
    }
}

struct TOMLHeader: Equatable {
    /// 1-based, like every line in this file.
    let line: Int
    let path: [String]
    let isArray: Bool
}

struct TOMLDocument {
    let root: TOMLTable
    let headers: [TOMLHeader]
}

/// A single pass over unicode scalars — not `Character`s, because `\r\n` is one `Character`
/// and the line counting below would miss it.
struct TOMLReader {
    private let scalars: [Unicode.Scalar]
    private var index = 0
    private var line = 1

    /// The deepest an array or inline table may nest, and the longest a dotted key or header
    /// path may be. The reader recurses per level, and the
    /// file is checked in — a cloned repo controls it — so an unbounded `[[[…` 100,000 deep
    /// overflowed the stack and crashed Flight Deck on every launch that read it. §8 needs
    /// one level; 32 leaves room for anything a person would write.
    static let maxDepth = 32

    init(_ text: String) {
        var scalars = Array(text.unicodeScalars)
        // A UTF-8 byte-order mark, which some editors save; read as a key it would make the
        // first line an "expected a key" error on a file that looks fine.
        if scalars.first == "\u{FEFF}" { scalars.removeFirst() }
        self.scalars = scalars
    }

    mutating func read() throws -> TOMLDocument {
        let root = TOMLTable(line: 1, explicit: true)
        var current = root
        var headers: [TOMLHeader] = []
        while true {
            skipTrivia(newlines: true)
            guard let scalar = peek() else { break }
            if scalar == "[" {
                let headerLine = line
                advance()
                let isArray = peek() == "["
                if isArray { advance() }
                skipTrivia(newlines: false)
                let path = try keyPath()
                skipTrivia(newlines: false)
                for _ in 0..<(isArray ? 2 : 1) {
                    guard peek() == "]" else {
                        throw issue(isArray ? "expected ]] to close the [[table]] header" : "expected ] to close the table header",
                                    at: headerLine)
                    }
                    advance()
                }
                try endOfLine()
                current = try open(path, in: root, isArray: isArray, line: headerLine)
                headers.append(TOMLHeader(line: headerLine, path: path, isArray: isArray))
            } else {
                let keyLine = line
                let path = try keyPath()
                skipTrivia(newlines: false)
                guard peek() == "=" else { throw issue("expected = after the key") }
                advance()
                skipTrivia(newlines: false)
                let value = try self.value()
                try endOfLine()
                let parent = try descend(path.dropLast(), from: current, line: keyLine)
                let key = path[path.count - 1]
                guard parent.entries[key] == nil else {
                    throw issue("duplicate key \(path.joined(separator: "."))", at: keyLine)
                }
                parent.set(key, .value(value, line: keyLine))
            }
        }
        return TOMLDocument(root: root, headers: headers)
    }

    // MARK: Tables

    /// The table a `[path]` or `[[path]]` header makes current.
    private func open(_ path: [String], in root: TOMLTable, isArray: Bool, line: Int) throws -> TOMLTable {
        let parent = try descend(path.dropLast(), from: root, line: line)
        let key = path[path.count - 1]
        let name = path.joined(separator: ".")
        if isArray {
            let table = TOMLTable(line: line, explicit: true)
            switch parent.entries[key] {
            case nil: parent.set(key, .tables([table]))
            case .tables(let tables): parent.set(key, .tables(tables + [table]))
            default: throw issue("\(name) is already a table or key, not a [[\(name)]] array", at: line)
            }
            return table
        }
        switch parent.entries[key] {
        case nil:
            let table = TOMLTable(line: line, explicit: true)
            parent.set(key, .table(table))
            return table
        case .table(let table) where !table.explicit:
            table.explicit = true
            return table
        case .table:
            throw issue("table \(name) is defined twice", at: line)
        default:
            throw issue("\(name) is already a key or [[\(name)]] array, not a table", at: line)
        }
    }

    /// Walks `path` from `table`, creating implicit tables, and stepping into the last element
    /// of a `[[…]]` array as TOML specifies.
    private func descend(_ path: ArraySlice<String>, from table: TOMLTable, line: Int) throws -> TOMLTable {
        var table = table
        for key in path {
            switch table.entries[key] {
            case nil:
                let child = TOMLTable(line: line, explicit: false)
                table.set(key, .table(child))
                table = child
            case .table(let child):
                table = child
            case .tables(let tables):
                table = tables[tables.count - 1]
            case .value:
                throw issue("\(key) is a value, not a table", at: line)
            }
        }
        return table
    }

    // MARK: Keys

    private mutating func keyPath() throws -> [String] {
        var path = [try key()]
        while true {
            skipTrivia(newlines: false)
            guard peek() == "." else { return path }
            // Each component is a table level, and a 100,000-long path built a chain of tables
            // that overflowed the stack when it was freed (deinit recurses down the chain).
            guard path.count < Self.maxDepth else { throw issue("keys nested too deeply") }
            advance()
            skipTrivia(newlines: false)
            path.append(try key())
        }
    }

    private mutating func key() throws -> String {
        switch peek() {
        case "\"": return try basicString()
        case "'": return try literalString()
        default:
            var key = ""
            while let scalar = peek(), Self.isBare(scalar) {
                key.unicodeScalars.append(scalar)
                advance()
            }
            guard !key.isEmpty else { throw issue("expected a key") }
            return key
        }
    }

    private static func isBare(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar {
        case "A"..."Z", "a"..."z", "0"..."9", "_", "-": true
        default: false
        }
    }

    // MARK: Values

    private mutating func value(depth: Int = 0) throws -> TOMLValue {
        switch peek() {
        case "\"": return .string(try basicString())
        case "'": return .string(try literalString())
        case "[", "{":
            guard depth < Self.maxDepth else { throw issue("arrays nested too deeply") }
            return peek() == "[" ? try array(depth: depth + 1) : try inlineTable(depth: depth + 1)
        default:
            var token = ""
            while let scalar = peek(), !" \t\r\n,]}#".unicodeScalars.contains(scalar) {
                token.unicodeScalars.append(scalar)
                advance()
            }
            if token == "true" { return .bool(true) }
            if token == "false" { return .bool(false) }
            let digits = token.replacingOccurrences(of: "_", with: "")
            if !digits.isEmpty, let int = Int(digits),
               digits.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "+" || $0 == "-") }) {
                return .int(int)
            }
            throw issue(token.isEmpty
                ? "expected a value"
                : "unsupported value \(token) (strings need quotes; floats and dates are not supported)")
        }
    }

    private mutating func array(depth: Int) throws -> TOMLValue {
        let start = line
        advance()  // [
        var items: [TOMLValue] = []
        while true {
            skipTrivia(newlines: true)
            guard let scalar = peek() else { throw issue("unterminated array", at: start) }
            if scalar == "]" {
                advance()
                return .array(items)
            }
            items.append(try value(depth: depth))
            skipTrivia(newlines: true)
            switch peek() {
            case ",": advance()
            case "]": continue
            case nil: throw issue("unterminated array", at: start)
            default: throw issue("expected , or ] in the array")
            }
        }
    }

    /// `{ K = "v", … }`, on one line as TOML requires.
    private mutating func inlineTable(depth: Int) throws -> TOMLValue {
        advance()  // {
        var entries: [String: TOMLValue] = [:]
        skipTrivia(newlines: false)
        if peek() == "}" {
            advance()
            return .inlineTable(entries)
        }
        while true {
            skipTrivia(newlines: false)
            let key = try self.key()
            skipTrivia(newlines: false)
            guard peek() == "=" else { throw issue("expected = after the key") }
            advance()
            skipTrivia(newlines: false)
            guard entries[key] == nil else { throw issue("duplicate key \(key)") }
            entries[key] = try value(depth: depth)
            skipTrivia(newlines: false)
            switch peek() {
            case ",": advance()
            case "}":
                advance()
                return .inlineTable(entries)
            default: throw issue("expected , or } in the inline table")
            }
        }
    }

    private mutating func basicString() throws -> String {
        if lookingAt("\"\"\"") { throw issue("multi-line strings are not supported") }
        advance()  // "
        var string = ""
        while let scalar = peek() {
            advance()
            switch scalar {
            case "\"": return string
            case "\n": throw issue("unterminated string", at: line - 1)
            case _ where Self.isControl(scalar): throw controlCharacter(scalar)
            case "\\":
                guard let escape = peek() else { break }
                advance()
                switch escape {
                case "b": string.unicodeScalars.append("\u{08}")
                case "t": string.unicodeScalars.append("\t")
                case "n": string.unicodeScalars.append("\n")
                case "f": string.unicodeScalars.append("\u{0C}")
                case "r": string.unicodeScalars.append("\r")
                case "\"": string.unicodeScalars.append("\"")
                case "\\": string.unicodeScalars.append("\\")
                case "u", "U":
                    let count = escape == "u" ? 4 : 8
                    var hex = ""
                    for _ in 0..<count {
                        guard let digit = peek() else { break }
                        hex.unicodeScalars.append(digit)
                        advance()
                    }
                    guard hex.count == count, let code = UInt32(hex, radix: 16),
                          let decoded = Unicode.Scalar(code)
                    else { throw issue("invalid unicode escape \\\(escape)\(hex)") }
                    string.unicodeScalars.append(decoded)
                default:
                    throw issue("unknown escape \\\(escape) in a string")
                }
            default:
                string.unicodeScalars.append(scalar)
            }
        }
        throw issue("unterminated string")
    }

    private mutating func literalString() throws -> String {
        if lookingAt("'''") { throw issue("multi-line strings are not supported") }
        advance()  // '
        var string = ""
        while let scalar = peek() {
            advance()
            if scalar == "'" { return string }
            if scalar == "\n" { throw issue("unterminated string", at: line - 1) }
            if Self.isControl(scalar) { throw controlCharacter(scalar) }
            string.unicodeScalars.append(scalar)
        }
        throw issue("unterminated string")
    }

    /// TOML's rule, and the reason for it here: a raw control character in a `run` command
    /// reaches a shell on another machine as something no reviewer of the file could see. Tab
    /// is allowed; anything else must be written as an escape.
    static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        (scalar.value < 0x20 && scalar != "\t") || scalar.value == 0x7F
    }

    private func controlCharacter(_ scalar: Unicode.Scalar) -> DelegateConfigIssue {
        issue(String(format: "raw control character U+%04X in a string; write it as an escape", scalar.value))
    }

    // MARK: Scanning

    private func peek() -> Unicode.Scalar? {
        index < scalars.count ? scalars[index] : nil
    }

    private mutating func advance() {
        if scalars[index] == "\n" { line += 1 }
        index += 1
    }

    private func lookingAt(_ text: String) -> Bool {
        let wanted = Array(text.unicodeScalars)
        return index + wanted.count <= scalars.count && Array(scalars[index..<index + wanted.count]) == wanted
    }

    /// Spaces, tabs and `#` comments, and newlines too when `newlines` is set.
    private mutating func skipTrivia(newlines: Bool) {
        while let scalar = peek() {
            if scalar == " " || scalar == "\t" || scalar == "\r" {
                advance()
            } else if scalar == "#" {
                while let next = peek(), next != "\n" { advance() }
            } else if newlines && scalar == "\n" {
                advance()
            } else {
                return
            }
        }
    }

    /// After a key/value or a header only a comment may follow on the line. Without this,
    /// `key = "a" trailing` would quietly drop `trailing`.
    private mutating func endOfLine() throws {
        skipTrivia(newlines: false)
        guard let scalar = peek() else { return }
        guard scalar == "\n" else { throw issue("expected end of line, found \(scalar)") }
        advance()
    }

    private func issue(_ message: String, at line: Int? = nil) -> DelegateConfigIssue {
        DelegateConfigIssue(.error, line: line ?? self.line, message)
    }
}
