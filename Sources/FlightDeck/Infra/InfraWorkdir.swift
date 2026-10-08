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
/// Everything else from the previous copy is: OpenTofu reads every `.tf` in the directory, so
/// a file deleted from the source but left here would still be applied.
enum InfraWorkdir {
    static let varsFile = "fd.auto.tfvars.json"
    static let lockFile = ".terraform.lock.hcl"

    static func prepare(root: URL, name: String, moduleSource: URL, vars: [String: InfraVar]) throws -> URL {
        let fm = FileManager.default
        let workdir = root.appendingPathComponent(name, isDirectory: true)
        let module = workdir.appendingPathComponent("module", isDirectory: true)
        try fm.createDirectory(at: module, withIntermediateDirectories: true)

        let entries = try fm.contentsOfDirectory(at: moduleSource, includingPropertiesForKeys: nil)
        // The lock `tofu init` wrote is kept only while the source pins none of its own; a
        // source lock always replaces it, so a module's pins are the ones that apply.
        let sourceHasLock = entries.contains { $0.lastPathComponent == lockFile }
        for stale in try fm.contentsOfDirectory(at: module, includingPropertiesForKeys: nil) {
            let n = stale.lastPathComponent
            guard !isStateOrCache(n), sourceHasLock || n != lockFile else { continue }
            try fm.removeItem(at: stale)
        }
        for entry in entries where !isStateOrCache(entry.lastPathComponent) {
            let dest = module.appendingPathComponent(entry.lastPathComponent)
            if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
            try fm.copyItem(at: entry, to: dest)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        // Owner-only from the first byte: the vars hold the enrollment PSK (inside the user-data)
        // and any Tailscale auth key. Written to a 0600 temp file and renamed over the old one,
        // so neither a reader nor a crash ever sees it world-readable or half-written.
        let data = try encoder.encode(vars)
        let temp = module.appendingPathComponent(".\(varsFile).\(UUID().uuidString)")
        guard fm.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path])
        }
        guard rename(temp.path, module.appendingPathComponent(varsFile).path) == 0 else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? fm.removeItem(at: temp)
            throw error
        }
        return workdir
    }

    /// A source module checked out from a working tree can carry its own state and provider
    /// cache; copying either would overwrite this machine's real state with someone else's.
    private static func isStateOrCache(_ name: String) -> Bool {
        name.hasPrefix("terraform.tfstate") || name == ".terraform"
    }
}
