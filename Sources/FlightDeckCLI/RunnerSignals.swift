import Dispatch
import Foundation

/// Wires the signals `intake run` gets terminated by to cancel its Task, rather than letting
/// their default disposition kill this process outright.
///
/// Every harness child `RoundExecutor` spawns runs in its own process group precisely so a
/// cancelled `Task` can `killpg` the whole subtree (see `CommandRunner`'s `onCancel` handler) —
/// but that only happens if something actually cancels the Task. Left at their default
/// disposition, SIGTERM/SIGINT/SIGHUP just kill this process outright and leave those children,
/// and the model CLI each one wraps, running orphaned with nothing left alive to reap them —
/// still spending tokens on a round nobody is watching.
public enum RunnerSignals {
    /// What `intake run` catches in production. A parameter on `install` rather than baked in,
    /// so a test can pass something harmless (`SIGUSR1`) instead of ever raising a real
    /// termination signal in the test process itself.
    public static let terminationSignals: [Int32] = [SIGTERM, SIGINT, SIGHUP]

    /// Ignores each of `signals` — so the signal's default action (dying) never runs — then
    /// installs one `DispatchSourceSignal` per signal that calls `cancel()` when it fires.
    ///
    /// Returns the sources so the caller can hold them: a `DispatchSourceSignal` with nothing
    /// retaining it is released, and its handler stops firing, before it ever gets a chance to.
    @discardableResult
    public static func install(signals: [Int32] = terminationSignals,
                                cancel: @escaping () -> Void) -> [DispatchSourceSignal] {
        signals.map { sig in
            // Must happen before the source is created: `DispatchSourceSignal` delivers the
            // signal instead of the default action, but the default action still runs for any
            // occurrence the source's queue hasn't gotten to yet unless the signal itself is
            // ignored first.
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler(handler: cancel)
            source.resume()
            return source
        }
    }
}
