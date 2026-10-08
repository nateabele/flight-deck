import Foundation
import IntakeKit

/// Where `agy` (the Antigravity CLI) keeps one conversation's files.
///
/// Every path here was read off a live agy 1.3.1 (`.superpowers/agy-tui-facts.md` §2, re-checked
/// 2026-10-08). The root is `~/.gemini/antigravity-cli`, and nothing relocates it: agy reads no
/// home variable (unify brief R5), so gemini has exactly one root per macOS user.
///
/// **Ids are lowercase on disk.** agy names every file after the conversation's UUID in
/// lowercase, while `UUID.uuidString` is uppercase — so every path goes through `name(_:)`, and
/// a path built from `uuidString` directly names a file that never exists.
struct GeminiPaths: Equatable, Sendable {
    let root: URL

    init(root: URL) { self.root = root }

    /// `~/.gemini/antigravity-cli`. `AgentID.gemini.builtInHome` is `~/.gemini`, which is also
    /// the `gemini` CLI's home; agy's own files live one directory down.
    static let `default` = GeminiPaths(root: AgentID.gemini.builtInHome
        .appendingPathComponent("antigravity-cli", isDirectory: true))

    /// The root agy uses under a gemini account home (`~/.gemini` → `~/.gemini/antigravity-cli`).
    static func forHome(_ home: URL) -> GeminiPaths {
        GeminiPaths(root: home.appendingPathComponent("antigravity-cli", isDirectory: true))
    }

    static func name(_ id: UUID) -> String { id.uuidString.lowercased() }

    var brain: URL { root.appendingPathComponent("brain", isDirectory: true) }
    var presenceDirectory: URL { root.appendingPathComponent("presence", isDirectory: true) }
    var summaries: URL { root.appendingPathComponent("conversation_summaries.db") }

    /// The full transcript: tool arguments raw, not JSON-string-encoded as in `transcript.jsonl`.
    /// It is the path agy's own hooks report as `transcriptPath`.
    func transcript(_ id: UUID) -> URL {
        brain.appendingPathComponent(Self.name(id), isDirectory: true)
            .appendingPathComponent(".system_generated/logs/transcript_full.jsonl")
    }

    /// One line, `title:"…"`, written by agy's auto-title and by `/rename`.
    func annotation(_ id: UUID) -> URL {
        root.appendingPathComponent("annotations/\(Self.name(id)).pbtxt")
    }

    /// The step store: the only place a step that is WAITING on an approval appears.
    func stepStore(_ id: UUID) -> URL {
        root.appendingPathComponent("conversations/\(Self.name(id)).db")
    }

    func presenceLock(_ id: UUID) -> URL {
        presenceDirectory.appendingPathComponent("\(Self.name(id)).lock")
    }

    /// Whether agy knows this conversation, i.e. whether `--conversation=<id>` resumes it.
    ///
    /// **Load-bearing because agy fails open.** `agy --conversation=<unknown>` prints a one-line
    /// warning and opens a FRESH conversation under a newly minted id (probed 1.3.1), so a resume
    /// of an id agy never had is not an error anyone sees. The step store is the file agy creates
    /// with the conversation (`/clear` created one before any prompt, 2026-10-08), so its
    /// presence is the test.
    func conversationExists(_ id: UUID, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Bool {
        exists(stepStore(id).path)
    }

    /// The conversation a `transcript_full.jsonl` belongs to, from its own path
    /// (`<root>/brain/<id>/.system_generated/logs/transcript_full.jsonl`).
    static func conversation(ofTranscript url: URL) -> (paths: GeminiPaths, id: UUID)? {
        let components = url.standardizedFileURL.pathComponents
        guard let brain = components.lastIndex(of: "brain"), brain + 1 < components.count,
              let id = UUID(uuidString: components[brain + 1]), brain >= 1
        else { return nil }
        let root = NSString.path(withComponents: Array(components[..<brain]))
        return (GeminiPaths(root: URL(fileURLWithPath: root, isDirectory: true)), id)
    }

    /// The conversation a path names when it is one of this root's presence locks.
    func conversation(ofPresenceLockPath path: String) -> UUID? {
        let url = URL(fileURLWithPath: path)
        // Resolved on both sides: the kernel reports the real path (`/private/var/…`), and a
        // root reached through a symlink (`/var/…`, or a linked `~/.gemini`) would never match.
        guard url.pathExtension == "lock",
              url.deletingLastPathComponent().resolvingSymlinksInPath().path
                == presenceDirectory.resolvingSymlinksInPath().path
        else { return nil }
        return UUID(uuidString: url.deletingPathExtension().lastPathComponent)
    }
}

/// agy's conversation title, out of `annotations/<id>.pbtxt`.
///
/// The file is protobuf text format, one field: `title:"Single Word Reply Test"`. The title is
/// NOT in the transcript — agy writes it here ~2 s after the first reply, and `/rename` rewrites
/// it at once (probed 2026-10-08: `/rename FD Smoke M` → `title:"FD Smoke M"`).
enum GeminiTitle {
    static func read(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return parse(String(decoding: data, as: UTF8.self))
    }

    /// Text format escapes a quote, a backslash and control bytes, and may write non-ASCII as
    /// octal byte escapes — so the value is unescaped to BYTES and then decoded as UTF-8, or a
    /// title in any non-Latin script would arrive as `\346\227\245`.
    static func parse(_ text: String) -> String? {
        guard let start = text.range(of: "title:")?.upperBound else { return nil }
        var rest = text[start...].drop(while: { $0 == " " })
        guard rest.first == "\"" else { return nil }
        rest = rest.dropFirst()
        var bytes: [UInt8] = []
        var iterator = Array(rest.utf8)[...]
        while let byte = iterator.first {
            iterator = iterator.dropFirst()
            if byte == UInt8(ascii: "\"") {
                let title = String(decoding: bytes, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return title.isEmpty ? nil : title
            }
            guard byte == UInt8(ascii: "\\"), let next = iterator.first else {
                bytes.append(byte)
                continue
            }
            iterator = iterator.dropFirst()
            switch next {
            case UInt8(ascii: "n"): bytes.append(0x0A)
            case UInt8(ascii: "t"): bytes.append(0x09)
            case UInt8(ascii: "r"): bytes.append(0x0D)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                var value = Int(next - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    guard let digit = iterator.first, (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(digit)
                    else { break }
                    value = value * 8 + Int(digit - UInt8(ascii: "0"))
                    iterator = iterator.dropFirst()
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            case UInt8(ascii: "x"):
                var value = 0
                for _ in 0..<2 {
                    guard let digit = iterator.first, let hex = Int(String(UnicodeScalar(digit)), radix: 16)
                    else { break }
                    value = value * 16 + hex
                    iterator = iterator.dropFirst()
                }
                bytes.append(UInt8(truncatingIfNeeded: value))
            default: bytes.append(next)
            }
        }
        // Ran off the end without a closing quote: a torn write, not a title.
        return nil
    }
}
