import Foundation
import Network
import HostKit
import HostKitDarwin
#if canImport(AppKit)
import AppKit
#endif

// flightdeck-hostd for macOS, launched by `dev.flightdeck.hostd.plist` as a GUI-session
// LaunchAgent: `flightdeck-hostd serve`. The admin socket at `<root>/admin.sock` is how the
// app's Hosting tab arms pairing, lists and revokes controllers.
//
// AGENTS.md rule 2 applies to this binary too: never run the copy inside a DerivedData app
// bundle by hand. It binds the real host port and state root, beside whichever hostd the
// installed app's LaunchAgent already runs.

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("flightdeck-hostd: \(message)\n".utf8))
    exit(code)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.first ?? "serve" == "serve" else {
    fail("usage: flightdeck-hostd serve", code: 64)
}

/// Held only while a controller is connected: a host that is mid-request must not idle-sleep
/// under it, but an idle host holding the assertion would keep the Mac awake forever for
/// nothing. Touched only from the server's queue, which is where the callback fires.
nonisolated(unsafe) var activity: NSObjectProtocol?

/// Read once: `Host.current()` can block on name resolution, and the core asks for the name on
/// every hello and every host.info. A Mac renamed while hostd runs shows the new name after the
/// next launch.
let hostName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

let root = HostStateRoot.default()

// Delegated execution (§4–§6): runs and their checkouts under the state root. A Mac host has
// a screen, so it takes screen runs, with IOKit's sleep assertions and the console session's
// lock state; HostKit alone knows neither.
let delegation = DelegationHost.standard(root: root, power: IOKitPowerAssertions(), console: DarwinConsoleSession(),
                                         screenSupported: true)

// Advertised in every helloAck, so a controller that paired over Bonjour on the LAN also
// learns this Mac's tailnet address and can still reach it after leaving the room.
let server = DarwinHostServer(root: root, port: 47410, hostName: { hostName },
                              endpoints: { LocalEndpoints.advertised(port: $0) }, delegation: delegation)

#if canImport(AppKit)
// The "UI tests running — don't touch" panel is up exactly while a run holds the screen
// lease (§6.3), so whoever sits at the Mac does not grab the mouse mid-test. Each change
// re-reads the holder on the main actor rather than passing it along: a grant and a release
// in quick succession must leave the panel showing the current state, whatever order the
// two hops land in.
let screen = delegation.screen
screen.observe { [screen] in
    Task { @MainActor in
        if let holder = screen.holder { ScreenPanel.show(holder: holder) } else { ScreenPanel.hide() }
    }
}
#endif
server.onConnectionCountChanged = { count in
    if count > 0, activity == nil {
        activity = ProcessInfo.processInfo.beginActivity(
            options: .userInitiated,  // includes .idleSystemSleepDisabled
            reason: "A Flight Deck controller is connected"
        )
    } else if count == 0, let held = activity {
        ProcessInfo.processInfo.endActivity(held)
        activity = nil
    }
}

// SIGTERM (launchd's stop, and `SMAppService.unregister`) runs this instead of killing the
// process outright, so the admin socket file is unlinked rather than left for the next
// launch to probe and clear.
let signals = [SIGTERM, SIGINT].map { sig in
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
    source.setEventHandler {
        server.stop()
        exit(0)
    }
    source.resume()
    return source
}

Task {
    do {
        let port = try await server.start()
        FileHandle.standardOutput.write(Data("listening on \(port)\n".utf8))
    } catch {
        // Non-zero so launchd's KeepAlive retries: a port still held by a previous instance
        // that is exiting is the ordinary way in.
        fail("could not start: \(error)", code: 1)
    }
}

#if canImport(AppKit)
// An accessory app rather than `dispatchMain()`: the panel needs AppKit's main run loop, and
// hostd is a LaunchAgent in the Aqua session (the plist), so it has a window server. No Dock
// icon and no menu bar; the main queue is still serviced as before.
withExtendedLifetime(signals) {
    NSApplication.shared.setActivationPolicy(.accessory)
    NSApplication.shared.run()
}
#else
withExtendedLifetime(signals) { dispatchMain() }
#endif
