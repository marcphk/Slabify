#if DEBUG
import UIKit

/// A simulated iPhone status bar: the time on the left and signal, Wi‑Fi and
/// battery on the right, laid out around the device's Dynamic Island or notch.
///
/// Positions are approximate, like the preset safe-area values.
final class StatusBarView: UIView {

    var cutout: DevicePreset.Cutout = .none {
        didSet { if cutout != oldValue { applyCutout() } }
    }

    var contentColor: UIColor = .black {
        didSet { if contentColor != oldValue { applyColor() } }
    }

    private let timeLabel = UILabel()
    private let leadingIcons = UIStackView()    // Home-button phones: signal and Wi‑Fi on the left
    private let trailingIcons = UIStackView()
    private let signalView = UIImageView(image: UIImage(systemName: "cellularbars"))
    private let wifiView = UIImageView(image: UIImage(systemName: "wifi"))
    private let batteryView = UIImageView(
        image: UIImage(systemName: "battery.100percent") ?? UIImage(systemName: "battery.100")
    )
    private let timeFormat = Date.FormatStyle()
        .hour(.defaultDigits(amPM: .omitted))
        .minute()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true

        for stack in [leadingIcons, trailingIcons] {
            stack.axis = .horizontal
            stack.alignment = .center
            addSubview(stack)
        }
        for icon in [signalView, wifiView, batteryView] {
            icon.contentMode = .scaleAspectFit
        }
        timeLabel.textAlignment = .center
        addSubview(timeLabel)

        updateTime()
        applyCutout()
        applyColor()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Call periodically to keep the clock current.
    func updateTime() {
        let text = Date.now.formatted(timeFormat)
        if timeLabel.text != text {
            timeLabel.text = text
            setNeedsLayout()
        }
    }

    // MARK: - Layout

    private var isClassicBar: Bool {
        if case .none = cutout { return true }
        return false
    }

    private func applyCutout() {
        let classic = isClassicBar
        timeLabel.font = .systemFont(ofSize: classic ? 12 : 17, weight: .semibold)

        let symbolSize: CGFloat = classic ? 11 : 15
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: symbolSize, weight: .semibold)
        for icon in [signalView, wifiView, batteryView] {
            icon.preferredSymbolConfiguration = symbolConfig
        }
        let batteryConfig = UIImage.SymbolConfiguration(pointSize: classic ? 13 : 19, weight: .regular)
        batteryView.preferredSymbolConfiguration = batteryConfig

        // Moving a view into another stack removes it from its old one.
        if classic {
            leadingIcons.addArrangedSubview(signalView)
            leadingIcons.addArrangedSubview(wifiView)
            trailingIcons.addArrangedSubview(batteryView)
        } else {
            trailingIcons.addArrangedSubview(signalView)
            trailingIcons.addArrangedSubview(wifiView)
            trailingIcons.addArrangedSubview(batteryView)
        }
        leadingIcons.spacing = 4
        trailingIcons.spacing = classic ? 4 : 6
        setNeedsLayout()
    }

    private func applyColor() {
        timeLabel.textColor = contentColor
        for icon in [signalView, wifiView, batteryView] {
            icon.tintColor = contentColor
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        timeLabel.sizeToFit()
        let leadingSize = leadingIcons.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let trailingSize = trailingIcons.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)

        switch cutout {
        case .none:
            // The classic 20 pt bar: time centered, signal left, battery right.
            let midY: CGFloat = 10
            timeLabel.center = CGPoint(x: bounds.midX, y: midY)
            leadingIcons.frame = CGRect(
                x: 6, y: midY - leadingSize.height / 2,
                width: leadingSize.width, height: leadingSize.height
            )
            trailingIcons.frame = CGRect(
                x: bounds.maxX - 6 - trailingSize.width, y: midY - trailingSize.height / 2,
                width: trailingSize.width, height: trailingSize.height
            )

        case .notch, .dynamicIsland:
            let cutoutWidth: CGFloat
            let midY: CGFloat
            if case .dynamicIsland(let width) = cutout {
                cutoutWidth = width
                midY = 11 + 37 / 2       // level with the island
            } else {
                cutoutWidth = 162
                midY = 24
            }
            // Center the time and icons in the "ears" either side of the cutout.
            let ear = max(0, (bounds.width - cutoutWidth) / 2)
            timeLabel.center = CGPoint(x: ear / 2 + 4, y: midY)
            leadingIcons.frame = .zero
            trailingIcons.frame = CGRect(
                x: bounds.maxX - ear / 2 - trailingSize.width / 2,
                y: midY - trailingSize.height / 2,
                width: trailingSize.width, height: trailingSize.height
            )
        }
    }
}
#endif
