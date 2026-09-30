import FleetKit
import Foundation

/// One key of the transport strip. `ack` is the in-progress word a key wears while the Mac is
/// acting on it, so a tap never looks ignored.
struct TransportKey: Equatable, Identifiable {
    let id: String
    let symbol: String
    let caption: String
    let enabled: Bool
    let isDefault: Bool
    let ack: String?
    let accessibilityLabel: String
}

/// Which keys the strip shows and which it will let a person press. Pure: the Mac's
/// `controls.enabled` is the authority, the in-flight set only ever narrows it.
enum TransportKeys {
    private static let table: [(id: String, symbol: String, caption: String, label: String)] = [
        ("pause", "pause.fill", "PAUSE", "Pause"),
        ("step", "forward.end.fill", "STEP", "Step one round"),
        ("nextMajor", "forward.end.alt.fill", "MAJOR", "Play to the next major stop"),
        ("toReview", "forward.fill", "REVIEW", "Play to review"),
        ("stop", "stop.fill", "STOP", "Stop the run"),
    ]

    /// `[]` unless the Mac said it accepts commands (`steer`), the intake is shaping, and the
    /// board carries controls: an older Mac drops the socket on a command it doesn't know.
    static func keys(detail: WireIntakeDetail, inFlight: Set<IntakeAction>) -> [TransportKey] {
        guard detail.steer == true, detail.summary.state == "shaping",
              let board = detail.board, let controls = board.controls else { return [] }
        let stopping = detail.halt == "stopping" || inFlight.contains(.tape("stop"))
        let pausing = detail.halt == "pausing" || inFlight.contains(.tape("pause"))
        return table.map { row in
            let ack: String? = row.id == "stop" && stopping ? "Stopping…"
                : row.id == "pause" && pausing ? "Pausing…" : nil
            return TransportKey(
                id: row.id, symbol: row.symbol, caption: row.caption,
                enabled: controls.enabled.contains(row.id) && !stopping
                    && !inFlight.contains(.tape(row.id)),
                isDefault: row.id == board.defaultPlay, ack: ack, accessibilityLabel: row.label)
        }
    }

    static func stopConfirmation(detail: WireIntakeDetail) -> (title: String, message: String) {
        let name = detail.board?.nowName ?? "The current round"
        return ("Stop the run?",
                "\(name)'s work in progress is discarded. Landed rounds and your notes are kept.")
    }
}

/// The Rounds header's "Refine ×N − +".
struct RoundsControl: Equatable {
    let title: String
    let canTrim: Bool
    let canExtend: Bool
    let stage: String
}

enum RoundsControlModel {
    /// The Mac derives `cycleName`/`cyclePlanned` from `extendStage ?? trimStage`, so that is the
    /// stage the label names. A button whose stage differs from it stays off: never offer a −
    /// that would trim a different stage than the one the label says.
    static func make(detail: WireIntakeDetail, inFlight: Set<IntakeAction>) -> RoundsControl? {
        guard detail.steer == true, detail.summary.state == "shaping",
              let controls = detail.board?.controls,
              let name = controls.cycleName, let planned = controls.cyclePlanned,
              let stage = controls.extendStage ?? controls.trimStage else { return nil }
        return RoundsControl(
            title: "\(name) ×\(planned)",
            canTrim: controls.enabled.contains("trim") && controls.trimStage == stage
                && !inFlight.contains(.tape("trim")),
            canExtend: controls.enabled.contains("extend") && controls.extendStage == stage
                && !inFlight.contains(.tape("extend")),
            stage: stage)
    }
}
