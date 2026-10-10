import Foundation

/// Finds the rollout a headless codex run wrote, by its thread id, without walking the whole
/// `sessions/` tree: codex files a rollout under `$CODEX_HOME/sessions/YYYY/MM/DD/` for the
/// LOCAL date it started (`rollout-2026-10-09T07-34-48-<thread>.jsonl` for a run at 12:34Z in
/// UTC-5, 2026-10-09), so only the seat's start day and its neighbours are listed — a run that
/// straddles midnight, or a clock a few seconds apart from codex's, still lands in one of them.
enum CodexRolloutFile {
    static let tailBytes: UInt64 = 256 * 1024

    static func find(home: URL, thread: String, near date: Date, calendar: Calendar = .current) -> URL? {
        let root = home.appendingPathComponent("sessions", isDirectory: true)
        let suffix = "-\(thread).jsonl"
        for offset in [0, -1, 1] {
            guard let day = calendar.date(byAdding: .day, value: offset, to: date) else { continue }
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            guard let y = c.year, let m = c.month, let d = c.day else { continue }
            let folder = root.appendingPathComponent(String(format: "%04d/%02d/%02d", y, m, d), isDirectory: true)
            let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
            if let name = names.first(where: { $0.hasSuffix(suffix) }) { return folder.appendingPathComponent(name) }
        }
        return nil
    }

    /// The rollout's last `tailBytes`: a long seat's rollout runs to megabytes and only its
    /// newest `token_count` is wanted.
    static func tail(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > tailBytes ? size - tailBytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
