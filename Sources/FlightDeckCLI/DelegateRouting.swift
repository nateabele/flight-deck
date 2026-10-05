import Darwin
import FleetKit
import Foundation

/// `flightdeck route-exec <argv0> -- <args…>` (spec §8): what a routing shim runs. It either
/// delegates the command through a matching `[[route]]`, or runs the real binary as if no shim
/// were there. Every fall-through path must reach the real binary: a shim that fails closed
/// turns "Flight Deck is not running" into "`xcodebuild` is broken" in every tab.
enum DelegateRouting {
    /// The name the shim was invoked as. A shim is reached through `PATH`, so argv0 is usually
    /// bare already; a path is cut to its last component so the routes and the `PATH` search
    /// both see `xcodebuild`, never `/…/shims/xcodebuild`.
    static func commandName(_ argv0: String) -> String {
        (argv0 as NSString).lastPathComponent
    }

    /// The recipe of the first route whose glob matches the joined argv (§8: "a glob over the
    /// joined argv"), with `fnmatch` semantics: `*` crosses `/` and spaces.
    ///
    /// The app applies the same rule when it resolves the run (`DelegateConfigLoading.recipe
    /// (routing:in:)`); this copy only decides whether to delegate at all.
    static func recipe(for argv: [String], in routes: [WireRoute]) -> String? {
        let joined = argv.joined(separator: " ")
        return routes.first { fnmatch($0.match, joined, 0) == 0 }?.recipe
    }

    /// The real binary for `name`: the first executable on `path` outside the shim directory.
    /// Without excluding it the shim would find itself and exec itself forever.
    static func resolve(_ name: String, path: String, shimDir: String?) -> String? {
        let shim = shimDir.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
        for entry in path.split(separator: ":").map(String.init) where !entry.isEmpty {
            if let shim, URL(fileURLWithPath: entry).standardizedFileURL.path == shim { continue }
            let candidate = (entry as NSString).appendingPathComponent(name)
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate, isDirectory: &isDirectory), !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }

    /// Replaces this process with the real binary. Returns only when it could not: 127 when
    /// nothing on `PATH` has the name, as a shell would, or 126 when the exec itself failed.
    static func execReal(_ argv0: String, _ args: [String], environment: [String: String]) -> Int32 {
        let name = commandName(argv0)
        guard let real = resolve(name, path: environment["PATH"] ?? "", shimDir: environment["FLIGHTDECK_SHIM_DIR"]) else {
            FileHandle.standardError.write(Data("flightdeck: \(name): command not found\n".utf8))
            return 127
        }
        let argv = ([name] + args).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        execv(real, argv)
        FileHandle.standardError.write(Data("flightdeck: \(real): \(String(cString: strerror(errno)))\n".utf8))
        return 126
    }
}
