import Foundation
import Network
import HostKit

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

let server = DarwinHostServer(root: HostStateRoot.default(), port: 47410, hostName: { hostName })
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

withExtendedLifetime(signals) { dispatchMain() }
