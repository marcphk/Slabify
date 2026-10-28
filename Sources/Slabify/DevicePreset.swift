#if DEBUG
import UIKit

/// A real iPhone size the frame can snap to.
///
/// Sizes are in points, portrait orientation. Safe-area values are typical
/// for each device; double-check them against the Simulator if exact values
/// matter for your layout.
struct DevicePreset: Equatable {

    enum Cutout: Equatable {
        case none            // Home button phones (no home indicator either)
        case notch
        /// `width` is the island's long side in points.
        case dynamicIsland(width: CGFloat)
    }

    /// The original Dynamic Island, iPhone 14 Pro through iPhone 17 Pro Max.
    static let standardIslandWidth: CGFloat = 126
    /// iPhone 18 Pro's island is about 35% narrower. This is an estimate; adjust it if
    /// you have an exact figure.
    static let compactIslandWidth: CGFloat = 82

    let id: String
    let name: String
    let portraitSize: CGSize
    let portraitInsets: UIEdgeInsets
    let landscapeInsets: UIEdgeInsets
    /// Plus/Max-size phones report a regular horizontal size class in landscape.
    let isRegularWidthInLandscape: Bool
    let cutout: Cutout
    let cornerRadius: CGFloat

    func size(landscape: Bool) -> CGSize {
        landscape
            ? CGSize(width: portraitSize.height, height: portraitSize.width)
            : portraitSize
    }

    func insets(landscape: Bool) -> UIEdgeInsets {
        landscape ? landscapeInsets : portraitInsets
    }

    func sizeClasses(landscape: Bool) -> (UIUserInterfaceSizeClass, UIUserInterfaceSizeClass) {
        landscape
            ? (isRegularWidthInLandscape ? .regular : .compact, .compact)
            : (.compact, .regular)
    }
}

extension DevicePreset {

    private static let islandPortrait = UIEdgeInsets(top: 62, left: 0, bottom: 34, right: 0)
    private static let islandLandscape = UIEdgeInsets(top: 0, left: 62, bottom: 20, right: 62)

    static let all: [DevicePreset] = [
        DevicePreset(
            id: "se3",
            name: "iPhone SE (3rd gen)",
            portraitSize: CGSize(width: 375, height: 667),
            portraitInsets: UIEdgeInsets(top: 20, left: 0, bottom: 0, right: 0),
            landscapeInsets: .zero,
            isRegularWidthInLandscape: false,
            cutout: .none,
            cornerRadius: 0
        ),
        DevicePreset(
            id: "16e",
            name: "iPhone 16e",
            portraitSize: CGSize(width: 390, height: 844),
            portraitInsets: UIEdgeInsets(top: 47, left: 0, bottom: 34, right: 0),
            landscapeInsets: UIEdgeInsets(top: 0, left: 47, bottom: 20, right: 47),
            isRegularWidthInLandscape: false,
            cutout: .notch,
            cornerRadius: 47
        ),
        DevicePreset(
            id: "17",
            name: "iPhone 17 / 17 Pro",
            portraitSize: CGSize(width: 402, height: 874),
            portraitInsets: islandPortrait,
            landscapeInsets: islandLandscape,
            isRegularWidthInLandscape: false,
            cutout: .dynamicIsland(width: standardIslandWidth),
            cornerRadius: 55
        ),
        DevicePreset(
            id: "air",
            name: "iPhone Air",
            portraitSize: CGSize(width: 420, height: 912),
            portraitInsets: UIEdgeInsets(top: 68, left: 0, bottom: 34, right: 0),
            landscapeInsets: UIEdgeInsets(top: 0, left: 68, bottom: 20, right: 68),
            isRegularWidthInLandscape: true,
            cutout: .dynamicIsland(width: standardIslandWidth),
            cornerRadius: 55
        ),
        DevicePreset(
            id: "17promax",
            name: "iPhone 17 Pro Max",
            portraitSize: CGSize(width: 440, height: 956),
            portraitInsets: islandPortrait,
            landscapeInsets: islandLandscape,
            isRegularWidthInLandscape: true,
            cutout: .dynamicIsland(width: standardIslandWidth),
            cornerRadius: 55
        ),
        DevicePreset(
            id: "18pro",
            name: "iPhone 18 Pro",
            portraitSize: CGSize(width: 402, height: 874),
            portraitInsets: islandPortrait,
            landscapeInsets: islandLandscape,
            isRegularWidthInLandscape: false,
            cutout: .dynamicIsland(width: compactIslandWidth),
            cornerRadius: 55
        ),
        DevicePreset(
            id: "18promax",
            name: "iPhone 18 Pro Max",
            portraitSize: CGSize(width: 440, height: 956),
            portraitInsets: islandPortrait,
            landscapeInsets: islandLandscape,
            isRegularWidthInLandscape: true,
            cutout: .dynamicIsland(width: compactIslandWidth),
            cornerRadius: 55
        ),
    ]

    static let defaultPreset = preset(id: "18pro") ?? all[0]

    /// The order used when snapping to a size several devices share:
    /// newest first, so 402 × 874 snaps to iPhone 18 Pro rather than 17 Pro.
    static var snapOrder: [DevicePreset] { all.reversed() }

    static func preset(id: String?) -> DevicePreset? {
        all.first { $0.id == id }
    }
}
#endif
