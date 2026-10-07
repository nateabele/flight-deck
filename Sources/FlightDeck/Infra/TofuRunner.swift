import Foundation
import IntakeKit

struct TofuProgress: Equatable, Sendable { let resource: String; let action: String; let done: Bool }
struct TofuOutputs: Equatable, Sendable { let address: String; let instanceID: String?; let hourlyUSD: Double? }

enum TofuError: Error, Equatable {
    case failed(step: String, message: String)
    case missingOutput(String)
}

protocol TofuRunning: Sendable {
    func initialize(workdir: URL) async throws
    func apply(workdir: URL, progress: @escaping @Sendable (TofuProgress) -> Void) async throws
    func destroy(workdir: URL, progress: @escaping @Sendable (TofuProgress) -> Void) async throws
    func outputs(workdir: URL) async throws -> TofuOutputs
    /// True when a refresh-only plan found the machine's instance deleted behind OpenTofu's
    /// back (a TTL timer, a console delete): the state is stale and the machine is `gone`.
    func refreshShowsGone(workdir: URL) async throws -> Bool
}

/// Drives the OpenTofu binary in `<workdir>/module`. `-json` output is parsed line by line
/// as it streams, so a long apply reports each resource as it starts and finishes.
struct LiveTofuRunner: TofuRunning {
    let tofu: URL
    let pluginCache: URL
    let runner: CommandRunner
    let environment: [String: String]

    init(tofu: URL, pluginCache: URL, runner: CommandRunner, environment: [String: String]) {
        self.tofu = tofu; self.pluginCache = pluginCache; self.runner = runner; self.environment = environment
    }

    func initialize(workdir: URL) async throws {
        _ = try await run("init", ["init", "-input=false", "-no-color"], workdir: workdir)
    }

    func apply(workdir: URL, progress: @escaping @Sendable (TofuProgress) -> Void) async throws {
        _ = try await run("apply", ["apply", "-auto-approve", "-input=false", "-json"], workdir: workdir, progress: progress)
    }

    func destroy(workdir: URL, progress: @escaping @Sendable (TofuProgress) -> Void) async throws {
        _ = try await run("destroy", ["destroy", "-auto-approve", "-input=false", "-json"], workdir: workdir, progress: progress)
    }

    func outputs(workdir: URL) async throws -> TofuOutputs {
        let result = try await run("output", ["output", "-json"], workdir: workdir)
        let object = (try? JSONSerialization.jsonObject(with: result.stdout)) as? [String: Any] ?? [:]
        func value(_ key: String) -> Any? { (object[key] as? [String: Any])?["value"] }
        guard let address = value("fd_address") as? String, !address.isEmpty else {
            throw TofuError.missingOutput("fd_address")
        }
        return TofuOutputs(address: address,
                           instanceID: value("fd_instance_id") as? String,
                           hourlyUSD: (value("fd_hourly_usd") as? NSNumber)?.doubleValue)
    }

    func refreshShowsGone(workdir: URL) async throws -> Bool {
        // -detailed-exitcode: 0 no drift, 2 drift, anything else a real failure.
        let result = try await run("plan", ["plan", "-refresh-only", "-detailed-exitcode", "-input=false", "-json"],
                                   workdir: workdir, okCodes: [0, 2])
        guard result.exitCode == 2 else { return false }
        return Self.lines(result.stdout).contains { line in
            guard line["type"] as? String == "resource_drift",
                  let change = line["change"] as? [String: Any],
                  change["action"] as? String == "delete",
                  let addr = (change["resource"] as? [String: Any])?["addr"] as? String else { return false }
            // A deleted security group is not a gone machine; only the compute resource counts.
            return ["instance", "virtual_machine", "droplet"].contains { addr.contains($0) }
        }
    }

    // MARK: - plumbing

    private func run(_ step: String, _ arguments: [String], workdir: URL, okCodes: Set<Int32> = [0],
                     progress: (@Sendable (TofuProgress) -> Void)? = nil) async throws -> CommandResult {
        var env = environment
        env["TF_PLUGIN_CACHE_DIR"] = pluginCache.path
        env["TF_IN_AUTOMATION"] = "1"
        let module = workdir.appendingPathComponent("module").path
        let splitter = LineSplitter { line in
            guard let progress, let event = Self.parse(line), let p = Self.progress(from: event) else { return }
            progress(p)
        }
        let result = try await runner.run(executable: tofu.path, arguments: ["-chdir=\(module)"] + arguments,
                                          cwd: workdir, environment: env, processGroup: false, onSpawn: nil,
                                          onStdout: { splitter.feed($0) })
        splitter.finish()
        guard okCodes.contains(result.exitCode) else {
            throw TofuError.failed(step: step, message: Self.failureMessage(result))
        }
        return result
    }

    private static func parse(_ line: Data) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: line)) as? [String: Any]
    }

    private static func lines(_ data: Data) -> [[String: Any]] {
        data.split(separator: UInt8(ascii: "\n")).compactMap { parse(Data($0)) }
    }

    private static func progress(from event: [String: Any]) -> TofuProgress? {
        guard let type = event["type"] as? String, type == "apply_start" || type == "apply_complete",
              let hook = event["hook"] as? [String: Any],
              let addr = (hook["resource"] as? [String: Any])?["addr"] as? String,
              let action = hook["action"] as? String else { return nil }
        return TofuProgress(resource: addr, action: action, done: type == "apply_complete")
    }

    /// The error diagnostics `-json` emitted, else the stderr tail (`init` and `output` have no
    /// JSON stream), else the exit code, so a failure never reads as an empty message.
    private static func failureMessage(_ result: CommandResult) -> String {
        let diagnostics = lines(result.stdout).compactMap { line -> String? in
            guard line["@level"] as? String == "error", line["type"] as? String == "diagnostic",
                  let d = line["diagnostic"] as? [String: Any], let summary = d["summary"] as? String else { return nil }
            let detail = (d["detail"] as? String) ?? ""
            return detail.isEmpty ? summary : "\(summary): \(detail)"
        }
        if !diagnostics.isEmpty { return diagnostics.joined(separator: "\n") }
        let tail = result.stderr.split(separator: "\n").suffix(20).joined(separator: "\n")
        return tail.isEmpty ? "exit \(result.exitCode)" : tail
    }
}

/// Re-assembles whole lines from stdout chunks, which can split a JSON line anywhere. The
/// runner calls its sink serially from one thread; the lock covers the final `finish()`.
private final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = Data()
    private let emit: (Data) -> Void
    init(_ emit: @escaping (Data) -> Void) { self.emit = emit }

    func feed(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        pending.append(chunk)
        while let nl = pending.firstIndex(of: UInt8(ascii: "\n")) {
            let line = pending[pending.startIndex..<nl]
            pending.removeSubrange(pending.startIndex...nl)
            if !line.isEmpty { emit(Data(line)) }
        }
    }

    func finish() {
        lock.lock(); defer { lock.unlock() }
        if !pending.isEmpty { emit(pending); pending = Data() }
    }
}
