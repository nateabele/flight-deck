import JavaScriptCore
import MarkdownUI
import SwiftUI
import UIKit

/// Colours a fenced code block the way the Mac's terminal does when Claude Code prints it.
///
/// **What "the same" means here, and why it is not a theme picked to look close.** On the Mac a
/// fence is drawn by Claude Code inside Ghostty: highlight.js tokenises it, a fixed table maps
/// each token scope to a chalk style (keyword → blue, string → red, type → dim cyan…), and the
/// terminal resolves those ANSI colours through its palette. Both halves are reproduced rather
/// than imitated. `claude-code-highlight.js` runs the same highlight.js release (11.11.1, every
/// language) with that table and chalk's own nesting rules — checked character for character
/// against chalk and highlight.js on the fences in real conversations — and the palette is
/// Flight Deck's own `GhosttyThemeDark.conf`/`GhosttyThemeLight.conf`, the files the Mac's
/// terminal loads, bundled into this app rather than copied into it.
///
/// A fence with no language is not highlighted on the Mac either: Claude Code draws it whole in
/// its theme's `permission` colour, and so does this.
struct ClaudeCodeHighlighter: CodeSyntaxHighlighter {
    func highlightCode(_ code: String, language: String?) -> Text {
        // MarkdownUI hands over the block with its closing newline; the terminal has no line
        // there, and a trailing newline in a `Text` is an empty last line.
        let code = code.hasSuffix("\n") ? String(code.dropLast()) : code
        guard let runs = ClaudeCodeHighlightEngine.shared.runs(for: code, language: language) else {
            return Text(code).foregroundColor(TerminalPalette.permission)
        }
        return Text(Self.attributed(runs))
    }

    static func attributed(_ runs: [HighlightRun]) -> AttributedString {
        var out = AttributedString()
        for run in runs {
            var piece = AttributedString(run.text)
            var color = run.paletteIndex.map(TerminalPalette.ansi) ?? TerminalPalette.foreground
            // Ghostty draws faint text at `faint-opacity`, 0.5 unless configured.
            if run.faint { color = color.opacity(0.5) }
            piece.foregroundColor = color
            var intent: InlinePresentationIntent = []
            if run.bold { intent.insert(.stronglyEmphasized) }
            if run.italic { intent.insert(.emphasized) }
            if !intent.isEmpty { piece.inlinePresentationIntent = intent }
            if run.underline { piece.underlineStyle = .single }
            out += piece
        }
        return out
    }
}

extension CodeSyntaxHighlighter where Self == ClaudeCodeHighlighter {
    static var claudeCode: Self { ClaudeCodeHighlighter() }
}

/// One stretch of a highlighted block in one style — the JS side's `[text, fg, flags]`.
struct HighlightRun: Equatable, Sendable {
    let text: String
    /// An ANSI palette index 0–15, or nil for the terminal's default foreground.
    let paletteIndex: Int?
    let bold: Bool
    let faint: Bool
    let italic: Bool
    let underline: Bool
}

/// highlight.js in a `JSContext`, loaded once, shared by every code block.
///
/// Loading is ~1.2 MB of script, so `prewarm()` starts it off the main thread at launch and a
/// block that renders before it is done waits on the lock rather than loading a second copy.
/// Results are cached by language and text: SwiftUI re-runs a row's body far more often than
/// its content changes, and the runs are appearance-independent (colours resolve later).
final class ClaudeCodeHighlightEngine: @unchecked Sendable {
    static let shared = ClaudeCodeHighlightEngine()

    private let lock = NSLock()
    private var context: JSContext?
    private var function: JSValue?
    private var loadFailed = false
    private var cache: [String: [HighlightRun]?] = [:]
    private var order: [String] = []
    private let capacity = 200

    func prewarm() {
        DispatchQueue.global(qos: .utility).async { [self] in
            lock.lock()
            defer { lock.unlock() }
            loadIfNeeded()
        }
    }

    /// The block's runs, or nil when Claude Code would not highlight it (no language given).
    func runs(for code: String, language: String?) -> [HighlightRun]? {
        let language = language?.trimmingCharacters(in: .whitespaces)
        guard let language, !language.isEmpty else { return nil }
        let key = language + "\u{0}" + code
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        loadIfNeeded()
        let value: [HighlightRun]?
        if let function, let json = function.call(withArguments: [code, language]), json.isString,
           let parsed = Self.parse(json.toString()) {
            value = parsed
        } else {
            // A failed load or a throwing grammar: plain text in the default colour, which is
            // what Claude Code shows when highlight.js gives it nothing back.
            value = [HighlightRun(text: code, paletteIndex: nil, bold: false, faint: false, italic: false, underline: false)]
        }
        cache[key] = value
        order.append(key)
        if order.count > capacity { cache.removeValue(forKey: order.removeFirst()) }
        return value
    }

    private func loadIfNeeded() {
        guard context == nil, !loadFailed else { return }
        let bundle = Bundle(for: ClaudeCodeHighlightEngine.self)
        guard let ctx = JSContext(),
              let core = bundle.url(forResource: "highlight-11.11.1.min", withExtension: "js"),
              let shim = bundle.url(forResource: "claude-code-highlight", withExtension: "js"),
              let coreSource = try? String(contentsOf: core, encoding: .utf8),
              let shimSource = try? String(contentsOf: shim, encoding: .utf8)
        else { loadFailed = true; return }
        ctx.evaluateScript(coreSource)
        ctx.evaluateScript(shimSource)
        guard let fn = ctx.objectForKeyedSubscript("claudeCodeHighlight"), !fn.isUndefined else {
            loadFailed = true
            return
        }
        context = ctx
        function = fn
    }

    private static func parse(_ json: String) -> [HighlightRun]? {
        guard let data = json.data(using: .utf8),
              let rows = try? JSONSerialization.jsonObject(with: data) as? [[Any]]
        else { return nil }
        return rows.compactMap { row in
            guard row.count == 3, let text = row[0] as? String,
                  let fg = row[1] as? Int, let flags = row[2] as? Int else { return nil }
            return HighlightRun(text: text, paletteIndex: fg < 0 ? nil : fg,
                                bold: flags & 1 != 0, faint: flags & 2 != 0,
                                italic: flags & 4 != 0, underline: flags & 8 != 0)
        }
    }
}

/// The Mac terminal's colours, read from the theme files Flight Deck's Ghostty loads, each a
/// light/dark pair that follows the phone's appearance the way the terminal follows the Mac's.
enum TerminalPalette {
    struct Theme {
        var background = UIColor.black
        var foreground = UIColor.white
        var ansi = [UIColor](repeating: .gray, count: 16)
    }

    static let dark = load("GhosttyThemeDark")
    static let light = load("GhosttyThemeLight")

    static let background = dynamic { $0.background }
    static let foreground = dynamic { $0.foreground }
    private static let ansiColors = (0..<16).map { i in dynamic { $0.ansi[i] } }
    static func ansi(_ index: Int) -> Color { ansiColors[max(0, min(15, index))] }

    /// Claude Code's `permission` colour in its default `dark` theme, which is what it draws an
    /// unlabelled fence in. A literal RGB there, not a palette slot,
    /// so the terminal does not change it between light and dark either.
    static let permission = Color(red: 177 / 255, green: 185 / 255, blue: 249 / 255)

    private static func dynamic(_ pick: @escaping @Sendable (Theme) -> UIColor) -> Color {
        Color(uiColor: UIColor { traits in pick(traits.userInterfaceStyle == .dark ? dark : light) })
    }

    static func load(_ name: String) -> Theme {
        let bundle = Bundle(for: ClaudeCodeHighlightEngine.self)
        guard let url = bundle.url(forResource: name, withExtension: "conf"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return Theme() }
        return parse(text)
    }

    /// The three keys the theme files set: `background`, `foreground`, `palette = N=#rrggbb`.
    static func parse(_ text: String) -> Theme {
        var theme = Theme()
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.hasPrefix("#"), let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "background": if let c = color(value) { theme.background = c }
            case "foreground": if let c = color(value) { theme.foreground = c }
            case "palette":
                let parts = value.split(separator: "=", maxSplits: 1)
                if parts.count == 2, let i = Int(parts[0]), (0..<16).contains(i), let c = color(String(parts[1])) {
                    theme.ansi[i] = c
                }
            default: break
            }
        }
        return theme
    }

    private static func color(_ hex: String) -> UIColor? {
        let h = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return UIColor(red: CGFloat(v >> 16 & 0xff) / 255, green: CGFloat(v >> 8 & 0xff) / 255,
                       blue: CGFloat(v & 0xff) / 255, alpha: 1)
    }
}
