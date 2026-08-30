import Foundation

/// Plannotator's own session registry, read rather than replaced.
///
/// Plannotator writes `~/.plannotator/sessions/<pid>.json` for every server it starts and
/// removes it on exit. A gate is therefore discoverable with a directory read and no side
/// effects — no hook of ours in the user's `settings.json`, and no second
/// `PermissionRequest` handler racing Plannotator's for the decision.
///
/// The format is undocumented and unversioned. Every rule fails closed, exactly as
/// `ClaudeStatusFile`'s do: anything unrecognised yields nil and the caller sees no gate,
/// which is the safe direction — a missing gate is invisible, an invented one offers Approve
/// for a session nothing is blocking.
enum PlannotatorRegistry {

    struct Entry: Equatable {
        /// `plannotator`'s pid, not `claude`'s.
        let pid: pid_t
        let port: Int
        let url: String
        /// `"plan"`, `"review"`, `"annotate"`, `"archive"`. Only `"plan"` is a gate.
        let mode: String
        let project: String
        let startedAt: String
    }

    static func decode(_ data: Data) -> Entry? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let pid = root["pid"] as? Int,
              let port = root["port"] as? Int,
              let url = root["url"] as? String,
              let mode = root["mode"] as? String,
              let project = root["project"] as? String,
              let startedAt = root["startedAt"] as? String
        else { return nil }
        return Entry(pid: pid_t(pid), port: port, url: url,
                     mode: mode, project: project, startedAt: startedAt)
    }

    /// Every live plan gate in `directory`, keyed by the **`claude` pid that owns it**.
    ///
    /// **Attribution is by parent pid and nothing else.** `plannotator` is spawned by the
    /// `claude` process whose `ExitPlanMode` call it is gating (verified: 18418 → 66955 →
    /// `claude`), and `SessionStore` already keys tabs by that pid through
    /// `ClaudeStatusFile.Entry.pid`. Matching on `project` or `cwd` instead would collapse two
    /// gates in this shared checkout onto one tab.
    ///
    /// `isAlive` and `parentOf` are injected for the reason `PromptService.tail` is: the
    /// process table is the thing a test must substitute, and passing functions keeps this
    /// enum free of both a store and a `FileManager` policy.
    static func planGates(
        in directory: URL,
        isAlive: (pid_t) -> Bool,
        parentOf: (pid_t) -> pid_t?
    ) -> [pid_t: Entry] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        var gates: [pid_t: Entry] = [:]
        for name in names where name.hasSuffix(".json") {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(name)),
                  let entry = decode(data),
                  entry.mode == "plan",
                  isAlive(entry.pid),
                  let owner = parentOf(entry.pid)
            else { continue }
            gates[owner] = entry
        }
        return gates
    }

    /// The default registry location.
    static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".plannotator/sessions", isDirectory: true)
    }

    /// `kill(pid, 0)` succeeds for a live process we may signal, and sets `EPERM` for one we
    /// may not — which is still alive. Only `ESRCH` means gone.
    static func processIsAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// The parent pid, via `sysctl`. `ps` would be a subprocess per poll.
    static func parentProcess(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = sysctl(&mib, u_int(mib.count), &info, &size, nil, 0)
        guard result == 0, size > 0 else { return nil }
        let parent = info.kp_eproc.e_ppid
        return parent > 0 ? parent : nil
    }
}
