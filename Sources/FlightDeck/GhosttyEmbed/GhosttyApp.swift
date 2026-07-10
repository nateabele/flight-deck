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
    /// The underlying libghostty app handle.
    private(set) var app: ghostty_app_t!

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
        ghostty_config_load_default_files(cfg)
        ghostty_config_load_recursive_files(cfg)
        ghostty_config_finalize(cfg)
        self.config = cfg

        // The "runtime" config is how libghostty calls back into the host app.
        // These callbacks are intentionally minimal for the walking skeleton; a
        // full embedding would route them into host state (clipboard, actions, ...).
        var runtime = ghostty_runtime_config_s(
            userdata: Unmanaged.passUnretained(self).toOpaque(),
            supports_selection_clipboard: false,
            wakeup_cb: { userdata in GhosttyApp.wakeup(userdata) },
            action_cb: { _, _, _ in false },
            read_clipboard_cb: { _, _, _ in false },
            confirm_read_clipboard_cb: { _, _, _, _ in },
            write_clipboard_cb: { _, _, _, _, _ in },
            close_surface_cb: { _, _ in }
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

    /// libghostty asks the host to tick soon; may be called off the main thread.
    private static func wakeup(_ userdata: UnsafeMutableRawPointer?) {
        guard let userdata else { return }
        let ghostty = Unmanaged<GhosttyApp>.fromOpaque(userdata).takeUnretainedValue()
        DispatchQueue.main.async { ghostty.tick() }
    }
}
