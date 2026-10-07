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
enum EnrollCommand {
    struct Outcome: Equatable {
        let exitCode: Int32
        let message: String
    }

    static func run(file: URL, now: Date, send: (AdminRequest) -> AdminReply) -> Outcome {
        let payload: EnrollmentPayload
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            payload = try decoder.decode(EnrollmentPayload.self, from: Data(contentsOf: file))
        } catch {
            return Outcome(exitCode: 1, message: "cannot read enrollment file \(file.path): \(error)")
        }
        do {
            _ = try payload.validate(now: now)
        } catch let error as EnrollmentError {
            if error == .expired { try? FileManager.default.removeItem(at: file) }
            return Outcome(exitCode: 1, message: "enrollment \(LinuxHostd.describe(error))")
        } catch {
            return Outcome(exitCode: 1, message: "enrollment refused: \(error)")
        }
        switch send(.enroll(payload)) {
        case .ok:
            try? FileManager.default.removeItem(at: file)
            return Outcome(exitCode: 0, message: "enrolled \(payload.controllerName) in slot \(payload.slot.uuidString)")
        case .failed(let message):
            return Outcome(exitCode: 1, message: message)
        case let other:
            return Outcome(exitCode: 1, message: "unexpected reply \(other)")
        }
    }
}
