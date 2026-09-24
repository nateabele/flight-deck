import CoreGraphics
import Foundation

/// Pure camera math for the dependency-graph `Canvas` overlay: an affine that centers+zooms
/// graph-space on a point, and its inverse for hit-testing a view-space click back to a graph
/// point. Kept pure and tested here so the `Canvas` view (Task 11) carries no untested geometry.
struct DAGCamera: Equatable {
    /// Zoom factor: view-space units per graph-space unit.
    var scale: CGFloat
    /// The graph-space point shown at the viewport's center.
    var center: CGPoint

    /// Graph space -> view space: translate the focal point to the origin, scale, then
    /// translate to the viewport's center. Composed as translate(-center) then scale(scale)
    /// then translate(+viewport/2) — `CGAffineTransform.concatenating` applies the receiver
    /// first, so building it in that order (rather than the more natural-looking reverse) is
    /// what makes `graphPoint` (the exact inverse) round-trip.
    func transform(viewport: CGSize) -> CGAffineTransform {
        let toOrigin = CGAffineTransform(translationX: -center.x, y: -center.y)
        let scaled = toOrigin.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        return scaled.concatenating(CGAffineTransform(translationX: viewport.width / 2, y: viewport.height / 2))
    }

    /// View space -> graph space: the exact inverse of `transform`, used to hit-test a click
    /// against node positions.
    func graphPoint(fromViewPoint p: CGPoint, viewport: CGSize) -> CGPoint {
        p.applying(transform(viewport: viewport).inverted())
    }

    /// A camera focused on `point` at `scale`.
    static func centered(on point: CGPoint, scale: CGFloat) -> DAGCamera {
        DAGCamera(scale: scale, center: point)
    }

    /// A camera that fits `rect` (graph-space bounds) entirely inside `viewport`, with
    /// `padding` as a shrink factor (< 1 leaves margin) applied to the tighter of the two
    /// axis-wise scales so neither axis clips.
    func fitting(_ rect: CGRect, viewport: CGSize, padding: CGFloat) -> DAGCamera {
        let widthScale = rect.width > 0 ? viewport.width / rect.width : .infinity
        let heightScale = rect.height > 0 ? viewport.height / rect.height : .infinity
        let fitScale = min(widthScale, heightScale) * padding
        return DAGCamera(scale: fitScale, center: CGPoint(x: rect.midX, y: rect.midY))
    }
}
