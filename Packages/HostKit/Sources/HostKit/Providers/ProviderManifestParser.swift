import Foundation

/// Parses a visual provider's `provider.toml` (spec §9) on top of HostKit's TOML reader.
///
/// All or nothing: any error throws, so a provider is never partly loaded. Repo providers are
/// untrusted input, so every path in the manifest is checked to stay inside the provider folder.
public enum ProviderManifestParser {
    public static let fileName = "provider.toml"
    /// The newest contract this build reads.
    public static let supportedContract = 1

    public static func load(folder: URL) throws -> ProviderManifestParseResult {
        let url = folder.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ProviderManifestIssue(.error, "\(folder.lastPathComponent) has no \(fileName)")
        }
        // Decoded here so a wrong encoding says so, rather than reaching the user as Cocoa's
        // "couldn't be opened".
        guard let text = String(data: try Data(contentsOf: url), encoding: .utf8) else {
            throw ProviderManifestIssue(.error, "provider.toml is not valid UTF-8; save it as UTF-8")
        }
        return try parse(text, folder: folder)
    }

    public static func parse(_ text: String, folder: URL) throws -> ProviderManifestParseResult {
        let document: TOMLDocument
        do {
            var reader = TOMLReader(text)
            document = try reader.read()
        } catch let issue as DelegateConfigIssue {
            // A newer contract may use syntax this reader lacks (dates, say). Its `contract`
            // line is still plain, so say "newer Flight Deck" instead of a misleading parse error.
            // Only top-level lines count: a `contract` key under a table header belongs to that
            // table. a split on `isNewline` Characters, because "\r\n" is one Character that a split
            // on "\n" never sees, and `components(separatedBy: .newlines)` counts it as two lines.
            for (number, line) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
                let trimmed = String(line).trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("[") { break }
                let words = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                if words.count == 2, words[0] == "contract",
                   let n = Int(words[1].prefix { $0.isNumber }), n > supportedContract {
                    throw ProviderManifestIssue(
                        .error, line: number + 1, needsNewerFlightDeck: true,
                        "needs a newer Flight Deck (this provider is contract \(n); this build reads up to \(supportedContract))")
                }
            }
            throw ProviderManifestIssue(issue.severity, line: issue.line, issue.message)
        }
        var warnings: [ProviderManifestIssue] = []
        let manifest = try map(document.root, folder: folder, warnings: &warnings)
        return ProviderManifestParseResult(
            manifest: manifest, issues: warnings.sorted { ($0.line ?? 0) < ($1.line ?? 0) })
    }

    private static let topKeys: Set = ["id", "name", "version", "contract", "kind", "generator"]
    private static let kindKeys: Set = ["id", "summary", "output", "entry", "pins", "states", "sizes",
                                        "cost", "instructions", "assets"]

    private static func map(_ root: TOMLTable, folder: URL,
                            warnings: inout [ProviderManifestIssue]) throws -> ProviderManifest {
        // The contract is read before anything else: a later contract may rename the fields the
        // rest of this function expects, and "needs a newer Flight Deck" is the true answer then.
        guard let contractNode = root.entries["contract"] else {
            throw ProviderManifestIssue(.error, "contract is required, e.g. contract = 1")
        }
        let contract = try int(contractNode, "contract")
        guard contract >= 1 else {
            throw ProviderManifestIssue(.error, line: contractNode.line, "contract must be 1 or more")
        }
        guard contract <= supportedContract else {
            throw ProviderManifestIssue(
                .error, line: contractNode.line, needsNewerFlightDeck: true,
                "needs a newer Flight Deck (this provider is contract \(contract); this build reads up to \(supportedContract))")
        }

        // `id` is the key the trust file records approvals under and may become a path
        // component, so it is held to a filename-safe shape here, not at each use.
        let id = try required(root, "id", in: "provider.toml") { node in
            let value = try string(node, "id")
            // \A…\z, not ^…$: ICU lets `$` match before a trailing newline, and a newline in a
            // trust key or path component is the thing this check exists to stop.
            let safe = value.range(of: "\\A[A-Za-z0-9][A-Za-z0-9._-]*\\z", options: .regularExpression) != nil
            guard safe, !value.contains("..") else {
                throw ProviderManifestIssue(.error, line: node.line,
                    "id \"\(value)\" must be letters, digits, \".\", \"_\" or \"-\", start with a letter or digit, and not contain \"..\"")
            }
            return value
        }
        let name = try required(root, "name", in: "provider.toml") { try nonEmpty($0, "name") }
        let version = try required(root, "version", in: "provider.toml") { try nonEmpty($0, "version") }

        for (key, node) in root.ordered where !topKeys.contains(key) {
            let what = if case .value = node { "key" } else { "table" }
            warnings.append(ProviderManifestIssue(.warning, line: node.line, "unknown \(what) \(key) (ignored)"))
        }

        guard let kindNode = root.entries["kind"] else {
            throw ProviderManifestIssue(.error, "a provider needs at least one [[kind]]")
        }
        guard case .tables(let kindTables) = kindNode else {
            throw ProviderManifestIssue(.error, line: kindNode.line, "kind must be written as [[kind]] tables")
        }
        var kinds: [ProviderKind] = []
        for table in kindTables {
            let kind = try self.kind(table, folder: folder, warnings: &warnings)
            if kinds.contains(where: { $0.id == kind.id }) {
                throw ProviderManifestIssue(.error, line: table.line, "kind \(kind.id) is declared twice")
            }
            kinds.append(kind)
        }

        var generator: ProviderGenerator?
        if let node = root.entries["generator"] {
            guard case .table(let table) = node else {
                throw ProviderManifestIssue(.error, line: node.line, "generator must be a [generator] table")
            }
            generator = try self.generator(table, folder: folder, warnings: &warnings)
        }
        return ProviderManifest(id: id, name: name, version: version, contract: contract,
                                kinds: kinds, generator: generator)
    }

    private static func kind(_ table: TOMLTable, folder: URL,
                             warnings: inout [ProviderManifestIssue]) throws -> ProviderKind {
        let scope = "[[kind]]"
        let id = try required(table, "id", in: scope) { try string($0, "kind.id") }
        let path = "kind \(id)"
        let summary = try required(table, "summary", in: scope) { try string($0, "\(path).summary") }
        let outputName = try required(table, "output", in: scope) { try string($0, "\(path).output") }
        guard let output = ProviderKind.Output(rawValue: outputName) else {
            let options = ProviderKind.Output.allCases.map(\.rawValue).joined(separator: ", ")
            throw ProviderManifestIssue(.error, line: table.entries["output"]?.line,
                                        "\(path).output must be one of \(options), not \"\(outputName)\"")
        }
        let entry = try required(table, "entry", in: scope) {
            try inside(try string($0, "\(path).entry"), folder: folder, line: $0.line, field: "\(path).entry")
        }
        let instructions = try required(table, "instructions", in: scope) {
            try inside(try string($0, "\(path).instructions"), folder: folder, line: $0.line,
                       field: "\(path).instructions")
        }

        var pins: ProviderKind.Pins?
        if let node = table.entries["pins"] {
            let name = try string(node, "\(path).pins")
            guard let value = ProviderKind.Pins(rawValue: name) else {
                let options = ProviderKind.Pins.allCases.map(\.rawValue).joined(separator: ", ")
                throw ProviderManifestIssue(.error, line: node.line, "\(path).pins must be one of \(options), not \"\(name)\"")
            }
            pins = value
        }
        let states = try table.entries["states"].map { try strings($0, "\(path).states") } ?? []
        let sizes = try table.entries["sizes"].map { try strings($0, "\(path).sizes") } ?? ["default"]
        let assets = try table.entries["assets"].map { node in
            try strings(node, "\(path).assets").map {
                try inside($0, folder: folder, line: node.line, field: "\(path).assets")
            }
        } ?? []
        let cost = try table.entries["cost"].map { try self.cost($0, field: "\(path).cost", warnings: &warnings) }

        for (key, node) in table.ordered where !kindKeys.contains(key) {
            warnings.append(ProviderManifestIssue(.warning, line: node.line, "unknown key \(key) in [[kind]] (ignored)"))
        }
        return ProviderKind(id: id, summary: summary, output: output, entry: entry, pins: pins,
                            states: states, sizes: sizes, cost: cost, instructions: instructions, assets: assets)
    }

    private static func cost(_ node: TOMLNode, field: String,
                             warnings: inout [ProviderManifestIssue]) throws -> ProviderKind.Cost {
        guard case .value(.inlineTable(let entries), let line) = node else {
            throw ProviderManifestIssue(.error, line: node.line, "\(field) must be { seconds = 20, tokens = 6000 }")
        }
        var cost = ProviderKind.Cost()
        for (key, value) in entries.sorted(by: { $0.key < $1.key }) {
            switch (key, value) {
            case ("seconds", .int(let n)) where n >= 0: cost.seconds = n
            case ("tokens", .int(let n)) where n >= 0: cost.tokens = n
            case ("seconds", _), ("tokens", _):
                throw ProviderManifestIssue(.error, line: line, "\(field).\(key) must be a whole number, 0 or more")
            default:
                warnings.append(ProviderManifestIssue(.warning, line: line, "unknown key \(key) in \(field) (ignored)"))
            }
        }
        return cost
    }

    private static func generator(_ table: TOMLTable, folder: URL,
                                  warnings: inout [ProviderManifestIssue]) throws -> ProviderGenerator {
        guard let commandNode = table.entries["command"] else {
            throw ProviderManifestIssue(.error, line: table.line, "[generator] needs a command, e.g. command = [\"./bin/render\", \"{source}\", \"{out}\"]")
        }
        var command = try strings(commandNode, "generator.command")
        guard let program = command.first, !program.isEmpty else {
            throw ProviderManifestIssue(.error, line: commandNode.line, "generator.command must name a program")
        }
        // Only a relative path is the provider's own file. A bare name is a PATH lookup and an
        // absolute path is the host's, and neither can be inside the folder to begin with.
        let providerRelative = !program.hasPrefix("/") && program.contains("/")
        if providerRelative {
            command[0] = try inside(program, folder: folder, line: commandNode.line, field: "generator.command[0]")
        }
        // 60s when absent: a generator with no deadline would be the one thing here that can hang
        // a turn, so omitting the key picks the spec's example value rather than "forever".
        var timeout = Duration(seconds: 60)
        if let node = table.entries["timeout"] {
            let text = try string(node, "generator.timeout")
            guard let parsed = Duration.parse(text) else {
                throw ProviderManifestIssue(.error, line: node.line, "generator.timeout must be a duration like \"60s\" or \"2m\", not \"\(text)\"")
            }
            guard parsed <= ProviderGenerator.maxTimeout else {
                throw ProviderManifestIssue(.error, line: node.line, "generator.timeout must be at most \(ProviderGenerator.maxTimeout.formatted), not \"\(text)\"")
            }
            timeout = parsed
        }
        let network = try table.entries["network"].map { try bool($0, "generator.network") } ?? false
        for (key, node) in table.ordered where !["command", "timeout", "network"].contains(key) {
            warnings.append(ProviderManifestIssue(.warning, line: node.line, "unknown key \(key) in [generator] (ignored)"))
        }
        return ProviderGenerator(command: command, timeout: timeout, network: network, providerRelative: providerRelative)
    }

    // MARK: - Paths

    /// The path, normalized and relative, or a refusal carrying `line`. Two checks, because
    /// each catches what the other cannot: the lexical one refuses `../../x` whether or not
    /// the file exists, and the symlink one refuses a link inside the folder that points out.
    static func inside(_ path: String, folder: URL, line: Int, field: String) throws -> String {
        func refuse(_ why: String) -> ProviderManifestIssue {
            ProviderManifestIssue(.error, line: line, "\(field) \"\(path)\" \(why)")
        }
        guard !path.isEmpty else { throw refuse("is empty") }
        guard !path.hasPrefix("/"), !path.hasPrefix("~") else {
            throw refuse("must be relative to the provider folder")
        }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                guard !parts.isEmpty else { throw refuse("reaches outside the provider folder") }
                parts.removeLast()
            } else {
                parts.append(part)
            }
        }
        guard !parts.isEmpty else { throw refuse("must name a file inside the provider folder") }
        let relative = parts.joined(separator: "/")

        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        // Follow every link hop by hop with `destinationOfSymbolicLink`, which reads the link
        // itself. `fileExists` and `resolvingSymlinksInPath` both follow a link, so a dangling
        // `link -> /outside/missing` looked like a missing file, and so did `x -> d/file` when
        // `d` was the dangling one. The hop limit stops a link loop.
        var resolved = root
        var queue = parts.map(String.init)
        var hops = 0
        while !queue.isEmpty {
            let part = queue.removeFirst()
            if part == "." || part.isEmpty { continue }
            if part == ".." { resolved.deleteLastPathComponent(); continue }
            let next = resolved.appendingPathComponent(part)
            guard let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: next.path) else {
                resolved = next
                continue
            }
            hops += 1
            guard hops <= 40 else { throw refuse("goes through too many symlinks") }
            if destination.hasPrefix("/") { resolved = URL(fileURLWithPath: "/") }
            queue = destination.split(separator: "/").map(String.init) + queue
        }
        guard (resolved.standardizedFileURL.path + "/").hasPrefix(prefix) else {
            throw refuse("resolves outside the provider folder through a symlink")
        }
        return relative
    }

    // MARK: - Value readers

    private static func required<T>(_ table: TOMLTable, _ key: String, in scope: String,
                                    _ read: (TOMLNode) throws -> T) throws -> T {
        guard let node = table.entries[key] else {
            throw ProviderManifestIssue(.error, line: table.line, "\(scope) needs \(key)")
        }
        return try read(node)
    }

    private static func string(_ node: TOMLNode, _ field: String) throws -> String {
        guard case .value(.string(let value), _) = node else {
            throw ProviderManifestIssue(.error, line: node.line, "\(field) must be a string")
        }
        return value
    }

    private static func nonEmpty(_ node: TOMLNode, _ field: String) throws -> String {
        let value = try string(node, field)
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ProviderManifestIssue(.error, line: node.line, "\(field) must not be empty")
        }
        return value
    }

    private static func bool(_ node: TOMLNode, _ field: String) throws -> Bool {
        guard case .value(.bool(let value), _) = node else {
            throw ProviderManifestIssue(.error, line: node.line, "\(field) must be true or false")
        }
        return value
    }

    private static func int(_ node: TOMLNode, _ field: String) throws -> Int {
        guard case .value(.int(let value), _) = node else {
            throw ProviderManifestIssue(.error, line: node.line, "\(field) must be an integer")
        }
        return value
    }

    private static func strings(_ node: TOMLNode, _ field: String) throws -> [String] {
        guard case .value(.array(let items), _) = node else {
            throw ProviderManifestIssue(.error, line: node.line, "\(field) must be an array of strings")
        }
        return try items.map {
            guard case .string(let value) = $0 else {
                throw ProviderManifestIssue(.error, line: node.line, "\(field) must be an array of strings")
            }
            return value
        }
    }
}
