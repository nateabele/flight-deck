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
    public static let notRunLine = "generator not run (pass --run-samples to try it in the sandbox)"

    /// `runSamples` is the author's explicit word that the generator may run, on the provider's
    /// own `samples/<kind>/` input. Without it nothing in the folder is ever executed.
    public static func run(folder: URL, runSamples: Bool = false,
                           sandbox: ProviderSandbox = ProviderSandbox()) async -> ProviderCheckReport {
        var lines: [String] = []
        var errors = 0
        func report(_ issue: ProviderManifestIssue) {
            lines.append(clean(issue.description))
            if issue.severity == .error { errors += 1 }
        }
        func fail(_ line: Int?, _ message: String) {
            report(ProviderManifestIssue(.error, line: line, message))
        }
        /// A problem that is not a line of provider.toml (a sample run, the folder itself), so
        /// it carries no `provider.toml:` prefix.
        func problem(_ message: String) {
            lines.append(clean("error: \(message)"))
            errors += 1
        }
        func finish() -> ProviderCheckReport {
            ProviderCheckReport(text: lines.joined(separator: "\n"), exitCode: errors == 0 ? 0 : 1)
        }

        // The registry ignores a linked provider folder, so the check refuses one too, and says
        // what to pass instead. Only the folder itself: a link higher up (/tmp) is fine.
        if (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.type] as? FileAttributeType == .typeSymbolicLink {
            problem("the provider folder is a link; pass the real folder")
            lines.append("invalid: nothing to check")
            return finish()
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            lines.append(clean("\(folder.path): error: not a folder"))
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
        // The line of each is the one the parser read it from. Not `entry`: spec §9 step 5 has
        // the agent write it in the draft folder, so a provider ships no such file.
        for kind in manifest.kinds {
            let scope = "kind \"\(kind.id)\""
            requireFile(kind.instructions, "\(scope) instructions", in: folder, line: kind.lines.instructions, fail: fail)
            for asset in kind.assets {
                requireFile(asset, "\(scope) asset", in: folder, line: kind.lines.assets, fail: fail)
            }
        }

        var sampled = 0
        if let generator = manifest.generator, runSamples {
            // Only a manifest with no errors may run code: a provider is never partly loaded.
            if errors > 0 {
                lines.append("generator not run: fix the problems above first")
            } else {
                sampled = await sampleRun(manifest, generator: generator, folder: folder, sandbox: sandbox,
                                           say: { lines.append($0) }, fail: problem)
            }
        }

        if errors == 0 {
            var summary = "valid: \(manifest.id) \(manifest.version), \(manifest.kinds.count) "
                + (manifest.kinds.count == 1 ? "kind" : "kinds")
            if manifest.generator != nil, sampled == 0 { summary += ", generator untested" }
            lines.append(clean(summary))
        } else {
            lines.append("invalid: \(errors) " + (errors == 1 ? "problem" : "problems"))
        }
        // Last, so it is the line an author reads when the check passed and nothing ran.
        if manifest.generator != nil, !runSamples { lines.append(notRunLine) }
        return finish()
    }

    // MARK: - Files

    private static func requireFile(_ path: String, _ what: String, in folder: URL, line: Int?,
                                    fail: (Int?, String) -> Void) {
        let url = folder.appendingPathComponent(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            fail(line, "\(what) \"\(path)\" does not exist in the provider folder")
            return
        }
        if isDirectory.boolValue {
            fail(line, "\(what) \"\(path)\" is a folder, not a file")
        }
    }

    // MARK: - Samples

    /// Runs the generator once per kind that has a samples folder; returns how many ran ok.
    private static func sampleRun(_ manifest: ProviderManifest, generator: ProviderGenerator, folder: URL,
                                   sandbox: ProviderSandbox, say: (String) -> Void,
                                   fail: (String) -> Void) async -> Int {
        let root = folder.resolvingSymlinksInPath().standardizedFileURL
        var succeeded = 0
        for kind in manifest.kinds {
            let relative = "samples/\(kind.id)"
            let samples = folder.appendingPathComponent(relative, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: samples.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                say(clean("sample \(kind.id): skipped; no \(relative)/ folder, so the generator was not run"))
                continue
            }
            let resolved = samples.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(root.path + "/") else {
                fail("sample \(kind.id): \(relative) resolves outside the provider folder")
                continue
            }
            if let bad = unsafeEntry(in: samples, prefix: relative) {
                fail("sample \(kind.id): \(bad)")
                continue
            }
            // The exact argv, before anything runs. {source} and {out} are filled in by the
            // runner, from its private copy of the folder and its private output folder.
            say(clean("running sample \(kind.id): \(generator.command.joined(separator: " "))"
                               + "  ({source} = the copy of \(relative), {out} = a private folder)"))
            let output = FileManager.default.temporaryDirectory
                .appendingPathComponent("fd-provider-check-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: output) }
            do {
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                // The author asked for this run by name (`--run-samples`): the folder counts as
                // theirs (`.user`). The sandbox, the clock and the output caps still apply.
                let provider = ResolvedProvider(id: manifest.id, manifest: manifest, source: .user, folder: folder,
                                                trust: .user, problems: [], digest: nil)
                let outcome = try await sandbox.run(
                    provider, outputDirectory: output, inputInProvider: relative,
                    placeholders: ["kind": kind.id])
                switch outcome {
                case .exited(let code, _, let stderr, let outputs):
                    if code != 0 {
                        fail("sample \(kind.id): the generator exited \(code)" + detail(stderr))
                    } else if outputs.isEmpty {
                        fail("sample \(kind.id): the generator exited 0 but wrote no files" + detail(stderr))
                    } else {
                        succeeded += 1
                        say(clean("sample \(kind.id): ok, wrote \(outputs.sorted().joined(separator: ", "))"))
                    }
                case .timedOut:
                    fail("sample \(kind.id): the generator did not finish within \(generator.timeout.seconds) seconds")
                case .outputTooLarge(let what):
                    fail("sample \(kind.id): the generator's \(what) is over the size limit")
                }
            } catch {
                fail("sample \(kind.id): \(error)")
            }
        }
        return succeeded
    }

    /// A link or other non-regular file under `folder`, named by its path. The runner refuses
    /// these too, with a message that has no path.
    private static func unsafeEntry(in folder: URL, prefix: String) -> String? {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        for name in names {
            let url = folder.appendingPathComponent(name)
            let path = "\(prefix)/\(name)"
            guard let type = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType else {
                return "\(path) cannot be read"
            }
            switch type {
            case .typeSymbolicLink: return "\(path) is a symlink; samples hold plain files only"
            case .typeDirectory: if let bad = unsafeEntry(in: url, prefix: path) { return bad }
            case .typeRegular: break
            default: return "\(path) is not a plain file"
            }
        }
        return nil
    }

    // MARK: - Printing

    private static func detail(_ stderr: String) -> String {
        let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return clean(": " + String(trimmed.suffix(400)).replacingOccurrences(of: "\n", with: " | "))
    }

    /// Anything a generator or a file name could use to drive the person's terminal: C0 and C1
    /// controls (ESC, BEL, CSI), DEL, and line breaks, which would fake a line of this report.
    static func clean(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter {
            !($0.value < 0x20 || (0x7F...0x9F).contains($0.value) || $0.value == 0x2028 || $0.value == 0x2029)
        }))
    }
}
