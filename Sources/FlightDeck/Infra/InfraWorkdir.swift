import Foundation

/// One value in a module's `fd.auto.tfvars.json`. Encodes as the bare JSON value (not a
/// tagged enum), because OpenTofu reads that file as plain variable assignments.
enum InfraVar: Encodable, Equatable {
    case string(String), number(Double), bool(Bool), map([String: String])

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .map(let v): try c.encode(v)
        }
    }
}

/// `<root>/<name>/module/` — the directory OpenTofu runs in for one machine. The module is
/// re-copied on every `up` (a user module may have changed), so state and the plugin
/// directory that live beside the sources must survive the copy: they are never deleted.
enum InfraWorkdir {
    static let varsFile = "fd.auto.tfvars.json"

    static func prepare(root: URL, name: String, moduleSource: URL, vars: [String: InfraVar]) throws -> URL {
        let fm = FileManager.default
        let workdir = root.appendingPathComponent(name, isDirectory: true)
        let module = workdir.appendingPathComponent("module", isDirectory: true)
        try fm.createDirectory(at: module, withIntermediateDirectories: true)

        let entries = try fm.contentsOfDirectory(at: moduleSource, includingPropertiesForKeys: nil)
        for entry in entries where !isStateOrCache(entry.lastPathComponent) {
            let dest = module.appendingPathComponent(entry.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: entry, to: dest)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(vars).write(to: module.appendingPathComponent(varsFile), options: .atomic)
        return workdir
    }

    /// A source module checked out from a working tree can carry its own state and provider
    /// cache; copying either would overwrite this machine's real state with someone else's.
    private static func isStateOrCache(_ name: String) -> Bool {
        name.hasPrefix("terraform.tfstate") || name == ".terraform"
    }
}
