import Foundation
import HostKit

/// What `flightdeck provider check` prints and the status it exits with.
public struct ProviderCheckReport: Equatable, Sendable {
    /// Newline-separated, no trailing newline.
    public var text: String
    /// 0 valid (warnings may print), 1 problems. The caller owns 2, the usage error.
    public var exitCode: Int32
}

/// Validates one provider folder the way the app loads it, so a provider that passes here is a
/// provider the app will offer. A provider is valid whole or not at all: any error means exit 1.
public enum ProviderCheck {
    public static func run(folder: URL, sandbox: ProviderSandbox = ProviderSandbox()) async -> ProviderCheckReport {
        var lines: [String] = []
        var errors = 0
        func report(_ issue: ProviderManifestIssue) {
            lines.append(issue.description)
            if issue.severity == .error { errors += 1 }
        }
        func fail(_ line: Int?, _ message: String) {
            report(ProviderManifestIssue(.error, line: line, message))
        }
        func finish() -> ProviderCheckReport {
            ProviderCheckReport(text: lines.joined(separator: "\n"), exitCode: errors == 0 ? 0 : 1)
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            lines.append("\(folder.path): error: not a folder")
            errors += 1
            lines.append("invalid: nothing to check")
            return finish()
        }
        let manifestURL = folder.appendingPathComponent(ProviderManifestParser.fileName)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            fail(nil, "\(folder.path) has no provider.toml; a provider folder holds one")
            lines.append("invalid: 1 problem")
            return finish()
        }

        let result: ProviderManifestParseResult
        do {
            result = try ProviderManifestParser.load(folder: folder)
        } catch {
            report((error as? ProviderManifestIssue) ?? ProviderManifestIssue(.error, "\(error)"))
            lines.append("invalid: 1 problem, so nothing was loaded")
            return finish()
        }
        let manifest = result.manifest
        result.issues.forEach(report)

        // The parser proves each path stays inside the folder; this proves the file is there.
        let source = (try? String(contentsOf: manifestURL, encoding: .utf8)) ?? ""
        for kind in manifest.kinds {
            requireFile(kind.instructions, "kind \"\(kind.id)\" instructions", in: folder, source: source, fail: fail)
            for asset in kind.assets {
                requireFile(asset, "kind \"\(kind.id)\" asset", in: folder, source: source, fail: fail)
            }
        }

        if let generator = manifest.generator {
            // Only a manifest with no errors may run code: a provider is never partly loaded.
            if errors > 0 {
                lines.append("generator not run: fix the problems above first")
            } else {
                await runSamples(manifest, generator: generator, folder: folder, sandbox: sandbox,
                                 lines: &lines, fail: fail)
            }
        }

        if errors == 0 {
            lines.append("valid: \(manifest.id) \(manifest.version), \(manifest.kinds.count) "
                         + (manifest.kinds.count == 1 ? "kind" : "kinds"))
        } else {
            lines.append("invalid: \(errors) " + (errors == 1 ? "problem" : "problems"))
        }
        return finish()
    }

    // MARK: - Files

    /// The 1-based line of `provider.toml` that names `path`, if any line does.
    static func line(of path: String, in source: String) -> Int? {
        let lines = source.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
        let spellings = ["\"\(path)\"", "\"./\(path)\"", "'\(path)'", "'./\(path)'"]
        return lines.firstIndex { line in spellings.contains { line.contains($0) } }.map { $0 + 1 }
    }

    private static func requireFile(_ path: String, _ what: String, in folder: URL, source: String,
                                    fail: (Int?, String) -> Void) {
        let url = folder.appendingPathComponent(path)
        var isDirectory: ObjCBool = false
        let line = line(of: path, in: source)
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            fail(line, "\(what) \"\(path)\" does not exist in the provider folder")
            return
        }
        if isDirectory.boolValue {
            fail(line, "\(what) \"\(path)\" is a folder, not a file")
        }
    }

    // MARK: - Samples

    private static func runSamples(_ manifest: ProviderManifest, generator: ProviderGenerator, folder: URL,
                                   sandbox: ProviderSandbox, lines: inout [String],
                                   fail: (Int?, String) -> Void) async {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        for kind in manifest.kinds {
            let samples = folder.appendingPathComponent("samples/\(kind.id)", isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: samples.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                lines.append("sample \(kind.id): skipped; no samples/\(kind.id)/ folder, so the generator was not run")
                continue
            }
            let resolved = samples.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root.path + "/") else {
                fail(nil, "sample \(kind.id): samples/\(kind.id) resolves outside the provider folder")
                continue
            }
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("fd-provider-check-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: output) }
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                // The folder is the person's own, run by name from the command line: it counts as
                // theirs (`.user`), and the sandbox, the clock and the output caps still apply.
                let provider = ResolvedProvider(id: manifest.id, manifest: manifest, source: .user, folder: folder,
                                                trust: .user, problems: [], digest: nil)
                let outcome = try await sandbox.run(
                    provider, outputDirectory: output, inputDirectory: resolved,
                    placeholders: ["source": resolved.path, "input": resolved.path, "kind": kind.id])
                switch outcome {
                case .exited(let code, _, let stderr, let outputs):
                    if code != 0 {
                        fail(nil, "sample \(kind.id): the generator exited \(code)" + detail(stderr))
                    } else if outputs.isEmpty {
                        fail(nil, "sample \(kind.id): the generator exited 0 but wrote no files" + detail(stderr))
                    } else {
                        lines.append("sample \(kind.id): ok, wrote \(outputs.sorted().joined(separator: ", "))")
                    }
                case .timedOut:
                    fail(nil, "sample \(kind.id): the generator did not finish within \(generator.timeout.seconds) seconds")
                case .outputTooLarge(let what):
                    fail(nil, "sample \(kind.id): the generator's \(what) is over the size limit")
                }
            } catch {
                fail(nil, "sample \(kind.id): \(error)")
            }
        }
    }

    private static func detail(_ stderr: String) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return ": " + String(trimmed.suffix(400)).replacingOccurrences(of: "\n", with: " | ")
    }
}
