// Adapted from ghostty v1.3.1: macos/Sources/Helpers/Extensions/Double+Extension.swift
extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        return Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
