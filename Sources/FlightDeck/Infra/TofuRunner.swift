import Foundation
import IntakeKit

struct TofuProgress: Equatable, Sendable { let resource: String; let action: String; let done: Bool }
struct TofuOutputs: Equatable, Sendable { let address: String; let instanceID: String?; let hourlyUSD: Double? }

/// One entry of a saved plan's `resource_changes`. `id` is the resource's id before the
/// change: nil for a create, the cloud's id for a delete.
struct TofuChange: Equatable, Sendable {
    let address: String
    let type: String
    let managed: Bool
    let actions: [String]
    let importing: Bool
    let id: String?
}

/// One managed resource the state holds, by its `id` attribute.
struct TofuResource: Equatable, Sendable { let address: String; let type: String; let id: String }

enum TofuError: Error, Equatable {
    case failed(step: String, message: String)
    case missingOutput(String)
}

protocol TofuRunning: Sendable {
    func initialize(workdir: URL) async throws
    /// Saves a plan in the work directory, an `up` plan or a destroy plan, and returns what it
    /// would change. Nothing changes in the cloud until `applyPlan`.
    func plan(workdir: URL, destroy: Bool) async throws -> [TofuChange]
    /// Applies exactly the plan `plan` saved, and nothing else: OpenTofu refuses a saved plan
    /// whose state moved since, so what was checked is what runs. There is no other way to
    /// change the cloud here, which is what makes `ResourceProvenance`'s checks a bound.
    func applyPlan(workdir: URL, destroy: Bool, progress: @escaping @Sendable (TofuProgress) -> Void) async throws
    /// The managed resources the state holds now.
    func resources(workdir: URL) async throws -> [TofuResource]
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

    /// Relative to `module/`, where every command runs.
    static func planFile(destroy: Bool) -> String { destroy ? "fd-destroy.tfplan" : "fd-up.tfplan" }

    func plan(workdir: URL, destroy: Bool) async throws -> [TofuChange] {
        let file = Self.planFile(destroy: destroy)
        _ = try await run(destroy ? "plan -destroy" : "plan",
                          ["plan", "-input=false", "-json", "-out=\(file)"] + (destroy ? ["-destroy"] : []), workdir: workdir)
        let shown = try await run("show", ["show", "-json", file], workdir: workdir)
        let object = (try? JSONSerialization.jsonObject(with: shown.stdout)) as? [String: Any] ?? [:]
        return Self.changes(object)
    }

    func applyPlan(workdir: URL, destroy: Bool, progress: @escaping @Sendable (TofuProgress) -> Void) async throws {
        let file = Self.planFile(destroy: destroy)
        defer { try? FileManager.default.removeItem(at: workdir.appendingPathComponent("module/\(file)")) }
        _ = try await run(destroy ? "destroy" : "apply", ["apply", "-auto-approve", "-input=false", "-json", file],
                          workdir: workdir, progress: progress)
    }

    func resources(workdir: URL) async throws -> [TofuResource] {
        let shown = try await run("show", ["show", "-json"], workdir: workdir)
        let object = (try? JSONSerialization.jsonObject(with: shown.stdout)) as? [String: Any] ?? [:]
        return Self.resources(object)
    }

    /// `resource_changes` of `tofu show -json <plan>`.
    static func changes(_ plan: [String: Any]) -> [TofuChange] {
        (plan["resource_changes"] as? [[String: Any]] ?? []).compactMap { c in
            guard let address = c["address"] as? String, let change = c["change"] as? [String: Any] else { return nil }
            return TofuChange(address: address, type: c["type"] as? String ?? "", managed: c["mode"] as? String != "data",
                              actions: change["actions"] as? [String] ?? [], importing: change["importing"] != nil,
                              id: (change["before"] as? [String: Any])?["id"] as? String)
        }
    }

    /// Every managed resource in `tofu show -json`'s `values`, child modules included.
    static func resources(_ state: [String: Any]) -> [TofuResource] {
        func walk(_ module: [String: Any]?) -> [TofuResource] {
            guard let module else { return [] }
            let own = (module["resources"] as? [[String: Any]] ?? []).compactMap { r -> TofuResource? in
                guard r["mode"] as? String == "managed", let address = r["address"] as? String, let type = r["type"] as? String,
                      let id = (r["values"] as? [String: Any])?["id"] as? String else { return nil }
                return TofuResource(address: address, type: type, id: id)
            }
            return own + (module["child_modules"] as? [[String: Any]] ?? []).flatMap { walk($0) }
        }
        return walk((state["values"] as? [String: Any])?["root_module"] as? [String: Any])
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
        // -detailed-exitcode: 0 no drift, 2 drift, anything else a real failure. -lock=false: a
        // refresh-only plan writes nothing, so it must never hold the state lock a user's
        // `down` or `apply` needs (the Reaper runs one every 10 minutes per machine).
        let result = try await run("plan", ["plan", "-refresh-only", "-detailed-exitcode", "-input=false", "-lock=false", "-json"],
                                   workdir: workdir, okCodes: [0, 2])
        guard result.exitCode == 2 else { return false }
        return Self.lines(result.stdout).contains { line in
            guard line["type"] as? String == "resource_drift",
                  let change = line["change"] as? [String: Any],
                  change["action"] as? String == "delete",
                  let resource = change["resource"] as? [String: Any] else { return false }
            // A deleted security group, or an `aws_instance_profile`, is not a gone machine; only
            // the compute resource's own type counts, so match the type, never a substring.
            let type = resource["resource_type"] as? String ?? (resource["addr"] as? String).flatMap { Self.resourceType(addr: $0) }
            return type.map(Self.machineTypes.contains) ?? false
        }
    }

    /// The resource types that ARE the machine, one per preset cloud.
    static let machineTypes: Set<String> = ["aws_instance", "google_compute_instance"]

    /// `aws_instance` from `aws_instance.this`, `module.box.aws_instance.this[0]` or
    /// `aws_instance.this["a"]`: the segment before the resource name, after any `module.<n>`
    /// prefixes.
    static func resourceType(addr: String) -> String? {
        var parts = addr.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        while parts.count > 2, parts[0] == "module" { parts.removeFirst(2) }
        if parts.first == "data" { return nil }
        return parts.count >= 2 ? parts[0] : nil
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
