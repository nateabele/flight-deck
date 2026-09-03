// Flight Deck-owned minimal libghostty app wrapper.
//
// This is deliberately NOT a copy of Ghostty's `Ghostty.App`
// (ghostty v1.3.1 macos/Sources/Ghostty/Ghostty.App.swift is ~2200 lines and is
// tightly coupled to the macOS app shell: AppDelegate, terminal controllers,
// config reloading, clipboard confirmation UI, notifications, etc.).
//
// It reproduces only the libghostty C-API bring-up sequence that a single embedded
// surface needs, following the sequence in `Ghostty.App.init`:
//   ghostty_init
//     -> ghostty_config_new / load_default_files / load_recursive_files / finalize
//     -> ghostty_runtime_config_s (minimal callbacks)
//     -> ghostty_app_new
//     -> ghostty_app_tick
// and hands out `Ghostty.SurfaceView`s bound to the resulting `ghostty_app_t`.

import AppKit
import GhosttyKit

/// Minimal owner of a libghostty `ghostty_app_t` for a single embedded surface.
final class GhosttyApp {
    /// The one libghostty app for the process.
    ///
    /// A lazy static rather than something owned by a particular object: it is created on
    /// first access, is never freed, and therefore cannot be outlived by a surface — which
    /// is the same teardown-lifetime guarantee `AppDelegate` ownership was giving us, minus
    /// any dependency on *when* the app delegate happens to be constructed.
    static let shared: GhosttyApp? = GhosttyApp()

    /// The underlying libghostty app handle.
    private(set) var app: ghostty_app_t!

    /// True while the underlying libghostty app handle is valid. Used by the
    /// surface-lifetime regression test to prove the app outlives surface frees.
    var hasValidApp: Bool { app != nil }

    /// libghostty's configured `font-size`, read once during `init`. This is what
    /// `TerminalFontSize.resolved` falls back to when `Preferences.terminalFontSize` is `nil`,
    /// i.e. before the user has ever changed the size.
    private(set) var defaultFontSize: Float = 12

    /// The finalized libghostty configuration backing `app`.
    private var config: ghostty_config_t!

    /// One-time global libghostty initialization. libghostty requires
    /// `ghostty_init` exactly once per process before any other API call.
    private static let didInit: Bool = {
        ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) == GHOSTTY_SUCCESS
    }()

    init?() {
        guard GhosttyApp.didInit else {
            Ghostty.logger.critical("ghostty_init failed")
            return nil
        }

        // Build a finalized configuration from the user's default config files.
        // A full embedding would wrap this in a richer type (see Ghostty.Config);
        // the skeleton only needs a valid finalized handle.
        guard let cfg = ghostty_config_new() else {
            Ghostty.logger.critical("ghostty_config_new failed")
            return nil
        }
        // Flight Deck's own defaults go in FIRST, so the user's config files below can still
        // override anything here. See GhosttyDefaults.conf for what and why.
        GhosttyApp.loadBundledDefaults(into: cfg)
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)
        GhosttyApp.logConfigDiagnostics(cfg)
        self.config = cfg
        self.defaultFontSize = GhosttyApp.readDefaultFontSize(from: cfg)

        // The "runtime" config is how libghostty calls back into the host app.
        //
        // libghostty never touches `NSPasteboard` itself — every clipboard operation is
        // delegated here. These were empty stubs, which is why ⌘C/⌘V did nothing: both the
        // menu route (`SurfaceView.copy(_:)` → `copy_to_clipboard`) and the key route
        // (`performKeyEquivalent` → `keyDown`) bottom out in these callbacks.
        //
        // Note the `userdata` for the clipboard and close callbacks is the *surface*
        // userdata (set in `SurfaceConfiguration.withCValue`), not `self`.
        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            // Enables `paste_from_selection` and the middle-click selection clipboard.
            supports_selection_clipboard: true,
            wakeup_cb: { userdata in GhosttyApp.wakeup(userdata) },
            action_cb: { app, target, action in
                GhosttyApp.perform(action: action, target: target, app: app)
            },
            read_clipboard_cb: { userdata, location, state in
                GhosttyApp.readClipboard(userdata, location: location, state: state)
            },
            confirm_read_clipboard_cb: { userdata, string, state, request in
                GhosttyApp.confirmReadClipboard(
                    userdata, string: string, state: state, request: request
                )
            },
            write_clipboard_cb: { userdata, location, content, len, confirm in
                GhosttyApp.writeClipboard(
                    userdata, location: location, content: content, len: len, confirm: confirm
                )
            },
            close_surface_cb: { userdata, processAlive in
                GhosttyApp.closeSurface(userdata, processAlive: processAlive)
            }
        )

        guard let app = ghostty_app_new(&runtime, cfg) else {
            Ghostty.logger.critical("ghostty_app_new failed")
            ghostty_config_free(cfg)
            self.config = nil
            return nil
        }
        self.app = app
        ghostty_app_set_focus(app, NSApp.isActive)
    }

    deinit {
        if let app { ghostty_app_free(app) }
        if let config { ghostty_config_free(config) }
    }

    /// Drive libghostty's event loop once. Call in response to `wakeup_cb`.
    func tick() {
        guard let app else { return }
        ghostty_app_tick(app)
    }

    /// Create a new terminal surface view bound to this app.
    func makeSurfaceView(baseConfig: Ghostty.SurfaceConfiguration? = nil) -> Ghostty.SurfaceView {
        Ghostty.SurfaceView(app, baseConfig: baseConfig)
    }

    // MARK: - Runtime callbacks

    /// Loads `GhosttyDefaults.conf` from the app bundle into `config`.
    ///
    /// libghostty exposes no "parse this string" entry point — only `load_file` — so the
    /// defaults ship as a real file inside the bundle rather than as a Swift string literal.
    /// That also makes them inspectable in the installed app.
    ///
    /// A missing file is logged and ignored rather than fatal: every default in there is a
    /// nicety, and refusing to launch over one would be the wrong trade.
    private static func loadBundledDefaults(into config: ghostty_config_t) {
        guard let url = Bundle.main.url(forResource: "GhosttyDefaults", withExtension: "conf")
        else {
            Ghostty.logger.warning("GhosttyDefaults.conf missing from bundle; skipping defaults")
            return
        }
        url.path.withCString { ghostty_config_load_file(config, $0) }
    }

    /// Surfaces whatever diagnostics libghostty recorded while parsing the config.
    ///
    /// Measured caveat, so nobody mistakes silence for proof: an unparseable `keybind` line
    /// in a file loaded via `ghostty_config_load_file` does **not** show up here. A bad
    /// trigger was added to `GhosttyDefaults.conf` deliberately and this reported nothing —
    /// the binding just silently fails to exist. So this catches some config problems, but
    /// it is not a validator for the defaults file, and an empty log says little.
    private static func logConfigDiagnostics(_ config: ghostty_config_t) {
        let count = ghostty_config_diagnostics_count(config)
        guard count > 0 else { return }
        for i in 0..<count {
            let diagnostic = ghostty_config_get_diagnostic(config, i)
            guard let message = diagnostic.message else { continue }
            Ghostty.logger.warning("ghostty config: \(String(cString: message))")
        }
    }

    /// Reads libghostty's configured `font-size` (an `f32` in `Config.zig`) out of the
    /// finalized config, so a surface created with no explicit `fontSize` and a freshly
    /// bumped `set_font_size` binding action agree on what "default" means. A failed read is
    /// logged and falls back to the property's initializer default rather than crashing —
    /// this is a nicety, not something worth refusing to launch over.
    private static func readDefaultFontSize(from config: ghostty_config_t) -> Float {
        var value: Float = 12
        let key = "font-size"
        guard ghostty_config_get(config, &value, key, UInt(key.lengthOfBytes(using: .utf8))) else {
            Ghostty.logger.warning("ghostty_config_get failed for font-size; using fallback")
            return 12
        }
        return value
    }

    /// Dispatches an app-level action from libghostty to its host equivalent.
    ///
    /// Most actions are still unhandled — see `docs/FOLLOWUPS.md`. This wires only the ones
    /// with a real meaning for Flight Deck today; returning `false` tells libghostty the
    /// action was not handled, which remains the honest answer for the rest.
    ///
    /// `quit` matters because a Ghostty keybind can resolve to it without any menu item
    /// being involved. When a Quit menu item *does* exist, `MenuKeyEquivalents` routes the
    /// shortcut to the menu first and this path never runs — the two are complementary, not
    /// redundant.
    ///
    /// This is a C callback, so it must not capture context; hence a static.
    private static func perform(
        action: ghostty_action_s,
        target: ghostty_target_s,
        app: ghostty_app_t?
    ) -> Bool {
        switch action.tag {
        case GHOSTTY_ACTION_QUIT:
            // Hop to the main queue: libghostty may emit this from inside a tick, and
            // terminating mid-tick would tear down state the call is still using.
            DispatchQueue.main.async { NSApp.terminate(nil) }
            return true

        case GHOSTTY_ACTION_OPEN_URL:
            return openURL(action.action.open_url)

        case GHOSTTY_ACTION_MOUSE_OVER_LINK:
            let v = action.action.mouse_over_link
            let hovered: String? = v.len > 0 && v.url != nil
                ? String(data: Data(bytes: v.url!, count: v.len), encoding: .utf8)
                : nil
            // Guarded assign: this fires as the pointer crosses link boundaries and
            // re-sends `nil` for every move over non-link cells. `@Published` publishes on
            // assignment, not on change, so the unguarded version invalidated observers at
            // pointer-move rate.
            return withSurfaceView(target) { if $0.hoverUrl != hovered { $0.hoverUrl = hovered } }

        case GHOSTTY_ACTION_MOUSE_SHAPE:
            let shape = action.action.mouse_shape
            return withSurfaceView(target) { $0.setCursorShape(shape) }

        case GHOSTTY_ACTION_MOUSE_VISIBILITY:
            switch action.action.mouse_visibility {
            case GHOSTTY_MOUSE_VISIBLE:
                return withSurfaceView(target) { $0.setCursorVisibility(true) }
            case GHOSTTY_MOUSE_HIDDEN:
                return withSurfaceView(target) { $0.setCursorVisibility(false) }
            default:
                return false
            }

        case GHOSTTY_ACTION_PWD:
            guard let pwdPtr = action.action.pwd.pwd,
                  let pwd = String(cString: pwdPtr, encoding: .utf8) else { return false }
            // Guarded assign: shells emit OSC 7 on every prompt, so this arrives once per
            // command with — almost always — the directory it already held.
            return withSurfaceView(target) { if $0.pwd != pwd { $0.pwd = pwd } }

        case GHOSTTY_ACTION_START_SEARCH:
            let startSearch = Ghostty.Action.StartSearch(c: action.action.start_search)
            return withSurfaceView(target) { view in
                if let searchState = view.searchState {
                    if let needle = startSearch.needle, !needle.isEmpty {
                        searchState.needle = needle
                    }
                } else {
                    view.searchState = Ghostty.SurfaceView.SearchState(from: startSearch)
                }
                NotificationCenter.default.post(name: .ghosttySearchFocus, object: view)
            }

        case GHOSTTY_ACTION_END_SEARCH:
            return withSurfaceView(target) { $0.searchState = nil }

        case GHOSTTY_ACTION_SEARCH_TOTAL:
            let total = action.action.search_total.total
            return withSurfaceView(target) { $0.searchState?.total = total >= 0 ? UInt(total) : nil }

        case GHOSTTY_ACTION_SEARCH_SELECTED:
            let selected = action.action.search_selected.selected
            return withSurfaceView(target) {
                $0.searchState?.selected = selected >= 0 ? UInt(selected) : nil
            }

        default:
            return false
        }
    }

    /// Resolves a surface-targeted action to its `SurfaceView` and applies `body` on the main
    /// queue. Returns whether the action was for a surface at all — i.e. whether we handled it.
    ///
    /// The main-queue hop matters: libghostty emits these from inside a tick, and everything
    /// these handlers touch is `@Published` state driving SwiftUI.
    @discardableResult
    private static func withSurfaceView(
        _ target: ghostty_target_s,
        _ body: @escaping (Ghostty.SurfaceView) -> Void
    ) -> Bool {
        guard let view = surfaceView(from: target) else { return false }
        DispatchQueue.main.async { body(view) }
        return true
    }

    private static func surfaceView(from target: ghostty_target_s) -> Ghostty.SurfaceView? {
        guard target.tag == GHOSTTY_TARGET_SURFACE,
              let surface = target.target.surface else { return nil }
        return surfaceView(from: surface)
    }

    /// The surface's `userdata` is the `SurfaceView` itself — see
    /// `SurfaceConfiguration.withCValue`, which sets it with `passUnretained`.
    private static func surfaceView(from surface: ghostty_surface_t) -> Ghostty.SurfaceView? {
        guard let userdata = ghostty_surface_userdata(surface) else { return nil }
        return Unmanaged<Ghostty.SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// The `userdata` passed to the surface-scoped runtime callbacks (clipboard, close).
    private static func surfaceView(
        fromUserdata userdata: UnsafeMutableRawPointer?
    ) -> Ghostty.SurfaceView? {
        guard let userdata else { return nil }
        return Unmanaged<Ghostty.SurfaceView>.fromOpaque(userdata).takeUnretainedValue()
    }

    /// Opens a URL the terminal asked us to open (⌘-click on a link, `open_url` binding).
    private static func openURL(_ v: ghostty_action_open_url_s) -> Bool {
        let action = Ghostty.Action.OpenURL(c: v)

        // A URL without a scheme is a file path. `URL(string:)` happily accepts bare paths and
        // produces a schemeless URL that will not open, so detect that and expand instead.
        let url: URL
        if let candidate = URL(string: action.url), candidate.scheme != nil {
            url = candidate
        } else {
            url = URL(fileURLWithPath: NSString(string: action.url).standardizingPath)
        }

        DispatchQueue.main.async {
            switch action.kind {
            case .text:
                // Text opens in an editor rather than whatever app claims the extension, so
                // clicking e.g. a `.sh` path opens it to read instead of running it.
                let editor = NSWorkspace.shared.defaultApplicationURL(forExtension: url.pathExtension)
                    ?? NSWorkspace.shared.defaultTextEditor
                if let editor {
                    NSWorkspace.shared.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
                } else {
                    NSWorkspace.shared.open(url)
                }

            default:
                NSWorkspace.shared.open(url)
            }
        }
        return true
    }

    // MARK: Clipboard

    /// Reads the pasteboard on libghostty's behalf and completes the pending request.
    ///
    /// Returning `false` is meaningful, not just an error path: `paste_from_clipboard` is a
    /// *performable* binding, so a `false` here lets ⌘V fall through to the terminal instead
    /// of being swallowed when there is nothing text-like to paste.
    private static func readClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        state: UnsafeMutableRawPointer?
    ) -> Bool {
        guard let view = surfaceView(fromUserdata: userdata),
              let surface = view.surface,
              let pasteboard = NSPasteboard.ghostty(location),
              let str = pasteboard.getOpinionatedStringContents()
        else { return false }

        completeClipboardRequest(surface, data: str, state: state)
        return true
    }

    private static func completeClipboardRequest(
        _ surface: ghostty_surface_t,
        data: String,
        state: UnsafeMutableRawPointer?,
        confirmed: Bool = false
    ) {
        data.withCString { ptr in
            ghostty_surface_complete_clipboard_request(surface, ptr, state, confirmed)
        }
    }

    /// Writes terminal-supplied content to the pasteboard (⌘C, OSC 52 write).
    private static func writeClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        location: ghostty_clipboard_e,
        content: UnsafePointer<ghostty_clipboard_content_s>?,
        len: Int,
        confirm: Bool
    ) {
        // No `surfaceView` lookup here: unlike the read path, writing needs no surface —
        // nothing is completed back into libghostty.
        guard let pasteboard = NSPasteboard.ghostty(location),
              let content, len > 0
        else { return }

        let items = (0..<len).compactMap { Ghostty.ClipboardContent.from(content: content[$0]) }
        guard !items.isEmpty else { return }

        guard confirm else {
            pasteboard.declareTypes(
                items.compactMap { NSPasteboard.PasteboardType(mimeType: $0.mime) },
                owner: nil
            )
            for item in items {
                guard let type = NSPasteboard.PasteboardType(mimeType: item.mime) else { continue }
                pasteboard.setString(item.data, forType: type)
            }
            return
        }

        // Confirmation only ever covers the text/plain entry: the prompt shows one body of
        // text, so approving a multi-type write would be approving something unseen.
        guard let text = items.first(where: { $0.mime == "text/plain" }) else { return }
        DispatchQueue.main.async {
            guard confirmClipboard(request: .osc_52_write(nil), contents: text.data) else { return }
            pasteboard.declareTypes([.string], owner: nil)
            pasteboard.setString(text.data, forType: .string)
        }
    }

    /// Asks the user before handing clipboard contents to (or taking them from) the terminal.
    ///
    /// Upstream Ghostty posts a notification that its window controller turns into a sheet.
    /// This app has no such controller, so it prompts with an `NSAlert` directly — same
    /// decision, far less plumbing. Skipping the prompt is not an option: with the default
    /// `clipboard-read = ask`, a no-op here is exactly what made paste silently fail.
    private static func confirmReadClipboard(
        _ userdata: UnsafeMutableRawPointer?,
        string: UnsafePointer<CChar>?,
        state: UnsafeMutableRawPointer?,
        request: ghostty_clipboard_request_e
    ) {
        guard let view = surfaceView(fromUserdata: userdata),
              let string,
              let contents = String(cString: string, encoding: .utf8),
              let request = Ghostty.ClipboardRequest.from(request: request)
        else { return }

        DispatchQueue.main.async {
            guard let surface = view.surface else { return }
            let allowed = confirmClipboard(request: request, contents: contents)
            // Always `confirmed: true`, even on denial — it means "the confirmation step is
            // finished", not "the user said yes". Denial is expressed by completing with an
            // empty string. Passing `false` here would send the request back around for
            // confirmation and prompt forever. Matches upstream's
            // `BaseTerminalController.clipboardConfirmationComplete`.
            completeClipboardRequest(
                surface,
                data: allowed ? contents : "",
                state: state,
                confirmed: true
            )
        }
    }

    @MainActor
    private static func confirmClipboard(
        request: Ghostty.ClipboardRequest,
        contents: String
    ) -> Bool {
        let alert = NSAlert()
        alert.messageText = "Authorize Clipboard Access"
        alert.informativeText = request.text()
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Deny")
        alert.addButton(withTitle: "Allow")

        // The contents go in an accessory view rather than `informativeText` so a long or
        // multi-line payload scrolls instead of stretching the alert off-screen.
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        text.string = contents
        text.isEditable = false
        text.drawsBackground = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 100))
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        alert.accessoryView = scroll

        return alert.runModal() == .alertSecondButtonReturn
    }

    // MARK: Surface lifecycle

    /// The shell exited (or a `close_surface` binding fired). Without this the pane was left
    /// on screen showing a dead terminal — see docs/FOLLOWUPS.md.
    private static func closeSurface(
        _ userdata: UnsafeMutableRawPointer?,
        processAlive: Bool
    ) {
        guard let view = surfaceView(fromUserdata: userdata) else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: Ghostty.Notification.ghosttyCloseSurface,
                object: view,
                userInfo: ["process_alive": processAlive]
            )
        }
    }

    /// libghostty asks the host to tick soon; may be called off the main thread.
    private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let ghostty = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
        DispatchQueue.main.async { ghostty.tick() }
    }
}
