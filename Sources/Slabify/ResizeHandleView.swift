#if DEBUG
import UIKit

/// The resize handle: a rounded arc that follows one of the phone's corners, a
/// constant distance outside the bezel.
///
/// The arc is cut from a rounded rectangle drawn around the phone, so it uses the same
/// continuous ("squircle") corner curve as the bezel and stays evenly spaced from it,
/// right up to where the corner meets the straight edges.
///
/// The view covers a generous box around the corner so the arc is easy to grab, even
/// when part of it is off screen. Touches on the phone's screen pass through.
final class ResizeHandleView: UIView {

    enum Corner {
        case bottomRight, topRight, topLeft
    }

    private let arcLayer = CAShapeLayer()
    private let lineWidth: CGFloat = 6
    /// How far outside the arc the grab area extends.
    private let outerGrab: CGFloat = 44
    /// How far past the ends of the arc, along the phone's edges, the grab area extends.
    private let edgeGrab: CGFloat = 20
    /// The phone's screen, in this view's coordinates. Touches there pass through.
    private var screenPath: UIBezierPath?

    override init(frame: CGRect) {
        super.init(frame: frame)
        arcLayer.fillColor = nil
        arcLayer.lineWidth = lineWidth
        arcLayer.lineCap = .round
        arcLayer.lineJoin = .round
        // Draw only the middle of the corner curve; the full curve wraps too far
        // along the edges. The grab area still covers the whole corner.
        arcLayer.strokeStart = 0.2
        arcLayer.strokeEnd = 0.8
        layer.addSublayer(arcLayer)

        isAccessibilityElement = true
        accessibilityLabel = "Resize device frame"

        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (handle: ResizeHandleView, _: UITraitCollection) in
            handle.updateColor()
        }
        updateColor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Places the arc around one corner of the phone. All values are in the
    /// superview's coordinate space, already scaled.
    ///
    /// - Parameters:
    ///   - phone: the bezel's outer frame.
    ///   - cornerRadius: the bezel's outer corner radius.
    ///   - screen: the screen's frame inside the bezel, and its corner radius.
    ///   - gap: distance from the bezel's edge to the middle of the arc's stroke.
    func configure(corner: Corner, phone: CGRect, cornerRadius: CGFloat,
                   screen: CGRect, screenRadius: CGFloat, gap: CGFloat) {
        // The outline the arc follows: a rounded rectangle `gap` outside the bezel.
        let outline = phone.insetBy(dx: -gap, dy: -gap)
        let radius = max(1, cornerRadius + gap)

        // The outline's sharp corner, and which way is "inward" along each axis.
        let (cornerPoint, inX, inY): (CGPoint, CGFloat, CGFloat) = {
            switch corner {
            case .bottomRight: return (CGPoint(x: outline.maxX, y: outline.maxY), -1, -1)
            case .topRight: return (CGPoint(x: outline.maxX, y: outline.minY), -1, 1)
            case .topLeft: return (CGPoint(x: outline.minX, y: outline.minY), 1, 1)
            }
        }()

        let arc = Self.cornerArc(of: outline, radius: radius, near: cornerPoint)
            ?? Self.fallbackArc(corner: cornerPoint, inX: inX, inY: inY, radius: radius)

        // The grab box: well outside the arc, and a little past its ends.
        let arcBounds = arc.bounds
        let minX = inX < 0 ? arcBounds.minX - edgeGrab : arcBounds.minX - outerGrab
        let maxX = inX < 0 ? arcBounds.maxX + outerGrab : arcBounds.maxX + edgeGrab
        let minY = inY < 0 ? arcBounds.minY - edgeGrab : arcBounds.minY - outerGrab
        let maxY = inY < 0 ? arcBounds.maxY + outerGrab : arcBounds.maxY + edgeGrab
        frame = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)

        let toLocal = CGAffineTransform(translationX: -frame.minX, y: -frame.minY)
        arc.apply(toLocal)
        screenPath = UIBezierPath(roundedRect: screen.applying(toLocal), cornerRadius: screenRadius)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        arcLayer.frame = bounds
        arcLayer.path = arc.cgPath
        CATransaction.commit()
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard bounds.contains(point) else { return false }
        // Let touches on the phone's screen reach your app.
        return !(screenPath?.contains(point) ?? false)
    }

    private func updateColor() {
        arcLayer.strokeColor = UIColor.label.withAlphaComponent(0.8).resolvedColor(with: traitCollection).cgColor
    }

    // MARK: - Building the arc

    private struct Segment {
        enum Kind {
            case line
            case quad(CGPoint)
            case cubic(CGPoint, CGPoint)
        }
        var start: CGPoint
        var end: CGPoint
        var kind: Kind
    }

    /// Cuts the curved corner nearest `corner` out of a UIKit rounded rectangle, which
    /// uses the same continuous corners as the bezel (`cornerCurve = .continuous`).
    private static func cornerArc(of rect: CGRect, radius: CGFloat, near corner: CGPoint) -> UIBezierPath? {
        let full = UIBezierPath(roundedRect: rect, cornerRadius: radius).cgPath

        // Break the outline into segments.
        var segments: [Segment] = []
        var current = CGPoint.zero
        var subpathStart = CGPoint.zero
        full.applyWithBlock { pointer in
            let element = pointer.pointee
            let points = element.points
            switch element.type {
            case .moveToPoint:
                current = points[0]
                subpathStart = current
            case .addLineToPoint:
                segments.append(Segment(start: current, end: points[0], kind: .line))
                current = points[0]
            case .addQuadCurveToPoint:
                segments.append(Segment(start: current, end: points[1], kind: .quad(points[0])))
                current = points[1]
            case .addCurveToPoint:
                segments.append(Segment(start: current, end: points[2], kind: .cubic(points[0], points[1])))
                current = points[2]
            case .closeSubpath:
                segments.append(Segment(start: current, end: subpathStart, kind: .line))
                current = subpathStart
            @unknown default:
                break
            }
        }

        // Keep the pieces that lie within the corner's curve. A continuous corner runs
        // about 1.53 × its radius along each edge.
        let reach = min(1.6 * radius, min(rect.width, rect.height) / 2) + 0.5
        func isNearCorner(_ point: CGPoint) -> Bool {
            abs(point.x - corner.x) <= reach && abs(point.y - corner.y) <= reach
        }
        var pieces = segments.filter { segment in
            isNearCorner(segment.start) && isNearCorner(segment.end) && segment.start != segment.end
        }
        guard !pieces.isEmpty else { return nil }

        // Chain them in order (the outline's starting point may fall mid-corner).
        func same(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 0.5 && abs(a.y - b.y) < 0.5 }
        let firstIndex = pieces.firstIndex { piece in
            !pieces.contains { same($0.end, piece.start) }
        } ?? 0
        var piece = pieces.remove(at: firstIndex)

        let path = UIBezierPath()
        path.move(to: piece.start)
        while true {
            switch piece.kind {
            case .line: path.addLine(to: piece.end)
            case .quad(let control): path.addQuadCurve(to: piece.end, controlPoint: control)
            case .cubic(let c1, let c2): path.addCurve(to: piece.end, controlPoint1: c1, controlPoint2: c2)
            }
            guard let next = pieces.firstIndex(where: { same($0.start, piece.end) }) else { break }
            piece = pieces.remove(at: next)
        }
        return path
    }

    /// An approximation used if the rounded rectangle can't be taken apart.
    private static func fallbackArc(corner: CGPoint, inX: CGFloat, inY: CGFloat, radius: CGFloat) -> UIBezierPath {
        let reach = 1.528 * radius
        let pull = 0.28 * radius
        let path = UIBezierPath()
        path.move(to: CGPoint(x: corner.x, y: corner.y + inY * reach))
        path.addCurve(
            to: CGPoint(x: corner.x + inX * reach, y: corner.y),
            controlPoint1: CGPoint(x: corner.x, y: corner.y + inY * pull),
            controlPoint2: CGPoint(x: corner.x + inX * pull, y: corner.y)
        )
        return path
    }
}
#endif
