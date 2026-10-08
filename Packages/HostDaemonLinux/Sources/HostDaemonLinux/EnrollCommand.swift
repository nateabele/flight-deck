import Foundation
import HostKit

/// `flightdeck-hostd enroll --file PATH`: redeems the one-time enrollment file a cloud machine's
/// user-data wrote, by handing its payload to the running `serve` (whose store is the only one
/// that matters: it read `controllers.json` once at start).
///
/// The file is deleted once it is spent: after a successful enroll, and when it has expired,
/// since neither can ever enroll again and the file holds a controller's secret. Any other
/// refusal leaves it in place for someone to inspect. Expiry and format are checked here first
/// so a dead file never reaches hostd; hostd checks again, because the admin socket is the
/// boundary that matters.
///
/// A payload from "the future" means this machine's clock is behind the Mac's, usually a fresh
/// VM before NTP has synced. That file is never deleted: `run` re-checks it every
/// `clockRetry` for up to `clockWait`, and if the clock still has not caught up it exits 1 and
/// keeps the file, so a later `enroll` can still redeem it.
enum EnrollCommand {
    struct Outcome: Equatable {
        let exitCode: Int32
        let message: String
        /// Said on stderr whatever the exit code: a spent file that could not be deleted.
        var warnings: [String] = []
    }

    static let clockWait: TimeInterval = 120
    static let clockRetry: TimeInterval = 5

    /// `now` and `sleep` are injected so the clock wait is testable without sleeping, and
    /// `remove` so the undeletable-file warning is: the test container runs as root, which
    /// deletes from a directory it has no write bit on, so no on-disk setup reaches that path.
    static func run(file: URL, now: () -> Date = Date.init,
                    sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
                    remove: (URL) throws -> Void = { try FileManager.default.removeItem(at: $0) },
                    send: (AdminRequest) -> AdminReply) -> Outcome {
        let payload: EnrollmentPayload
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            payload = try decoder.decode(EnrollmentPayload.self, from: Data(contentsOf: file))
        } catch {
            return Outcome(exitCode: 1, message: "cannot read enrollment file \(file.path): \(error)")
        }
        var waited: TimeInterval = 0
        while true {
            do {
                _ = try payload.validate(now: now())
                break
            } catch EnrollmentError.notYetValid where waited < clockWait {
                sleep(clockRetry)
                waited += clockRetry
            } catch EnrollmentError.notYetValid {
                return Outcome(exitCode: 1, message: "enrollment is not valid yet: this machine's clock is behind "
                    + "the controller's (issued \(payload.issuedAt), now \(now())); kept \(file.path) to retry")
            } catch let error as EnrollmentError {
                let warnings = error == .expired ? spend(file, remove: remove) : []
                return Outcome(exitCode: 1, message: "enrollment \(LinuxHostd.describe(error))", warnings: warnings)
            } catch {
                return Outcome(exitCode: 1, message: "enrollment refused: \(error)")
            }
        }
        switch send(.enroll(payload)) {
        case .ok:
            return Outcome(exitCode: 0, message: "enrolled \(payload.controllerName) in slot \(payload.slot.uuidString)",
                           warnings: spend(file, remove: remove))
        case .failed(let message):
            return Outcome(exitCode: 1, message: message)
        case let other:
            return Outcome(exitCode: 1, message: "unexpected reply \(other)")
        }
    }

    /// A spent file that survives still holds a controller's secret, so failing to delete it is
    /// worth saying, though the outcome itself stands: an enroll still exits 0.
    private static func spend(_ file: URL, remove: (URL) throws -> Void) -> [String] {
        do { try remove(file); return [] } catch {
            return ["could not delete \(file.path): \(error); it still holds a controller's secret, so delete it by hand"]
        }
    }
}
