#if DEBUG
import UIKit

/// Draws a fake Dynamic Island / notch and home indicator over the framed app,
/// so you can see what your content would sit under on a real phone.
final class HardwareOverlayView: UIView {

    var cutout: DevicePreset.Cutout = .none {
        didSet { if cutout != oldValue { setNeedsDisplay() } }
    }
    var isLandscape = false {
        didSet { if isLandscape != oldValue { setNeedsDisplay() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        contentMode = .redraw
        // The home indicator color follows light/dark mode.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: HardwareOverlayView, _: UITraitCollection) in
            view.setNeedsDisplay()
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func draw(_ rect: CGRect) {
        UIColor.black.setFill()

        switch cutout {
        case .none:
            return

        case .dynamicIsland(let length):
            let thickness: CGFloat = 37, inset: CGFloat = 11
            let island = isLandscape
                ? CGRect(x: inset, y: bounds.midY - length / 2, width: thickness, height: length)
                : CGRect(x: bounds.midX - length / 2, y: inset, width: length, height: thickness)
            UIBezierPath(roundedRect: island, cornerRadius: thickness / 2).fill()

        case .notch:
            let length: CGFloat = 162, thickness: CGFloat = 33
            let notch = isLandscape
                ? CGRect(x: 0, y: bounds.midY - length / 2, width: thickness, height: length)
                : CGRect(x: bounds.midX - length / 2, y: 0, width: length, height: thickness)
            let corners: UIRectCorner = isLandscape
                ? [.topRight, .bottomRight]
                : [.bottomLeft, .bottomRight]
            UIBezierPath(
                roundedRect: notch,
                byRoundingCorners: corners,
                cornerRadii: CGSize(width: 20, height: 20)
            ).fill()
        }

        // Home indicator
        let width: CGFloat = isLandscape ? 210 : 134
        let indicator = CGRect(x: bounds.midX - width / 2, y: bounds.maxY - 8 - 5, width: width, height: 5)
        UIColor.label.withAlphaComponent(0.3).setFill()
        UIBezierPath(roundedRect: indicator, cornerRadius: 2.5).fill()
    }
}
#endif
