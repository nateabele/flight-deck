import Foundation

/// A stand-in for a real CLI (`aws`, `gcloud`, `tofu`…): a `/bin/sh` script named `name`, in a
/// fresh temp directory of its own, so a test drives the real spawn path without ever running
/// the real tool — the cloud CLIs would sign in, spend money or touch a live account.
enum FakeExecutable {
    /// `script` is the body after the shebang; it sees the arguments as `$@`.
    static func make(_ name: String, script: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fake-exec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        try "#!/bin/sh\n\(script)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// Every argument vector the fake was run with, one line per run, written by a script
    /// that begins with `record(to:)`'s line.
    static func record(to log: URL) -> String { #"echo "$*" >> '\#(log.path)'"# }
    static func calls(_ log: URL) -> [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}
