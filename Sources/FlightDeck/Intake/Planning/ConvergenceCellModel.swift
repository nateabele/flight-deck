import Foundation

/// The LCD's CONVERGENCE cell (spec §8.1): the state word, the latest round's change count and
/// the sparkline of changes per round in the current cycle.
///
/// A placeholder shape so `LCDModel` and `ControlBar` can draw the cell now. Task 13 derives it
/// from `ConvergenceCycle` (`init?(cycles:)`) and adds the discontinuities, card lines and
/// suggested action; these four fields keep their names so nothing here changes when it does.
struct ConvergenceCellModel: Equatable {
    /// "CONVERGING ↘", "PLATEAU →", "DIVERGING ↗" or "TOO EARLY".
    var word: String
    var latest: Int
    var spark: [Double]
    /// Amber only for diverging (spec §8.1) — colour for exceptions only.
    var tone: LCDCell.Tone
}
