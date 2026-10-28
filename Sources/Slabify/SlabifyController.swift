#if DEBUG
import UIKit

/// Runs Slabify for one app window. It's the root of the front window, which holds
/// the simulated status bar, Dynamic Island and the controls; it also drives the back
/// window (backdrop and bezel) and resizes the app window to the simulated screen.
///
/// The frame only appears on an iPhone screen at least 560 pt in both directions,
/// i.e. iPhone Duo's inner display. Elsewhere your app's window is left untouched.
///
/// Controls float around the phone:
/// - Above the phone: the device menu, with the size classes, size and scale beside it.
/// - Top left: background and screenshot. Top right: close.
/// - Bottom corners of the screen: buttons that park the phone in that corner. While
///   parked, the other corner's button stays, a button beside the phone's free edge
///   returns it to center, and the other controls move to the free side.
/// - The phone's free corner: the resize arc.
final class SlabifyController: UIViewController, UIGestureRecognizerDelegate {

    /// Your app's window, which Slabify resizes to the simulated phone's screen.
    private weak var appWindow: UIWindow?
    let activation: Slabify.Activation

    // MARK: - Settings

    /// Where the phone sits on the screen.
    enum Placement: Int {
        case center, bottomLeft, bottomRight
    }

    /// The color scheme for the area around the phone. Never affects your app.
    enum Backdrop: Int {
        case system, light, dark

        var style: UIUserInterfaceStyle {
            switch self {
            case .system: return .unspecified
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    /// How the controls are laid out. Chosen automatically to give the phone the most room.
    private enum Arrangement {
        case beside    // round buttons in columns beside the phone
        case stacked   // round buttons in rows above and below the phone
    }

    // MARK: - State

    /// `nil` means a custom, freely dragged size.
    private var preset: DevicePreset?
    /// The current screen size in points, already oriented.
    private var frameSize: CGSize
    private var isLandscape: Bool
    private var isFrameOn: Bool
    private var placement: Placement
    private var backdrop: Backdrop
    private var arrangement: Arrangement = .beside

    // MARK: - Windows and views

    private let backgroundWindow: SlabifyWindow
    private let backgroundController = SlabifyBackgroundController()
    private let overlayWindow: SlabifyPassthroughWindow

    private var backdropView: UIView { backgroundController.backdropView }
    private var bezelView: UIView { backgroundController.bezelView }

    /// Sits exactly over the app window and holds what's drawn on top of the screen.
    private let screenOverlay = UIView()
    private let statusBarView = StatusBarView()
    private let hardwareView = HardwareOverlayView()
    private let resizeHandle = ResizeHandleView()

    private let presetButton = UIButton(configuration: .gray())
    private let sizeLabel = UILabel()
    private let backdropButton = UIButton(configuration: .gray())
    private let screenshotButton = UIButton(configuration: .gray())
    private let hideButton = UIButton(configuration: .gray())
    private let anchorLeftButton = UIButton(configuration: .gray())
    private let anchorRightButton = UIButton(configuration: .gray())
    private let recenterButton = UIButton(configuration: .gray())
    private let showButton = UIButton(configuration: .filled())

    private let snapFeedback = UISelectionFeedbackGenerator()
    private var refreshTimer: Timer?

    /// Everything drawn around the phone, which follows the backdrop's color scheme.
    private var chromeViews: [UIView] {
        [backdropView, resizeHandle, presetButton, sizeLabel, backdropButton, screenshotButton,
         hideButton, anchorLeftButton, anchorRightButton, recenterButton, showButton]
    }

    /// The controls shown while the frame is on.
    private var frameControls: [UIView] {
        [resizeHandle, presetButton, sizeLabel, backdropButton, screenshotButton,
         hideButton, anchorLeftButton, anchorRightButton, recenterButton]
    }

    // MARK: - What Slabify changed on the app window, to put back later

    private var isAppWindowFramed = false
    private var originalCornerRadius: CGFloat = 0
    private var originalCornerCurve: CALayerCornerCurve = .circular
    private var originalMasksToBounds = false
    private var appliedInsets: [ObjectIdentifier: (controller: WeakController, insets: UIEdgeInsets)] = [:]

    private final class WeakController {
        weak var value: UIViewController?
        init(_ value: UIViewController) { self.value = value }
    }

    // MARK: - Layout constants

    private let bezelWidth: CGFloat = 8
    private let edge: CGFloat = 18           // margin between controls and the screen edge, clear of its curved corners
    private let iconSize: CGFloat = 36       // round control buttons
    private let spacing: CGFloat = 8
    private let headerTopMargin: CGFloat = 8 // the device menu keeps this much room from the top of the screen
    private let minimumSide: CGFloat = 200
    private let snapTolerance: CGFloat = 8
    private let minimumScreenSide: CGFloat = 560

    // MARK: - Drag state

    /// The scale and arrangement are frozen while dragging so the handle stays under
    /// your finger.
    private var frozenScale: CGFloat?
    private var frozenArrangement: Arrangement?
    private var dragStartSize: CGSize = .zero
    private var currentScale: CGFloat = 1

    private var isLayingOut = false
    private var lastReportedActive: Bool?

    // MARK: - Lifecycle

    init(appWindow: UIWindow, scene: UIWindowScene, activation: Slabify.Activation) {
        self.appWindow = appWindow
        self.activation = activation
        backgroundWindow = SlabifyWindow(windowScene: scene)
        overlayWindow = SlabifyPassthroughWindow(windowScene: scene)

        let defaults = UserDefaults.standard
        let savedID = defaults.string(forKey: Keys.presetID)
        let savedWidth = defaults.double(forKey: Keys.width)
        let savedHeight = defaults.double(forKey: Keys.height)

        if savedID == Keys.customID, savedWidth > 0, savedHeight > 0 {
            preset = nil
            frameSize = CGSize(width: savedWidth, height: savedHeight)
        } else {
            let restored = DevicePreset.preset(id: savedID) ?? .defaultPreset
            preset = restored
            // Corrected to the screen's orientation on the first layout pass.
            frameSize = restored.size(landscape: false)
        }
        isLandscape = frameSize.width > frameSize.height
        isFrameOn = defaults.object(forKey: Keys.frameOn) as? Bool ?? true
        placement = Placement(rawValue: defaults.integer(forKey: Keys.placement)) ?? .center
        backdrop = Backdrop(rawValue: defaults.integer(forKey: Keys.backdrop)) ?? .system

        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Puts the extra windows in place and does the first layout.
    func start() {
        guard let appWindow else { return }

        originalCornerRadius = appWindow.layer.cornerRadius
        originalCornerCurve = appWindow.layer.cornerCurve
        originalMasksToBounds = appWindow.layer.masksToBounds

        backgroundController.onLayout = { [weak self] in self?.layoutAll() }
        backgroundController.orientations = { [weak self] in self?.appOrientations ?? .all }
        backgroundWindow.rootViewController = backgroundController
        backgroundWindow.windowLevel = UIWindow.Level(rawValue: appWindow.windowLevel.rawValue - 1)
        backgroundWindow.isUserInteractionEnabled = false
        backgroundWindow.backgroundColor = .clear
        backgroundWindow.isHidden = false

        overlayWindow.windowLevel = UIWindow.Level(rawValue: appWindow.windowLevel.rawValue + 1)
        overlayWindow.backgroundColor = .clear
        overlayWindow.rootViewController = self
        overlayWindow.isHidden = false

        setUpActivationGesture(on: appWindow)

        // Keeps the simulated clock current, and picks up status bar changes and new
        // root or presented view controllers in your app.
        refreshTimer = Timer.scheduledTimer(
            timeInterval: 0.5, target: self, selector: #selector(refreshTimerFired),
            userInfo: nil, repeats: true
        )

        layoutAll()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        screenOverlay.isUserInteractionEnabled = false
        screenOverlay.clipsToBounds = true
        screenOverlay.layer.cornerCurve = .continuous
        screenOverlay.addSubview(statusBarView)
        screenOverlay.addSubview(hardwareView)
        view.addSubview(screenOverlay)

        setUpResizeHandle()
        setUpControls()
        setUpShowButton()
        applyBackdrop()
        updateControls()

        // The bezel follows the backdrop's light/dark appearance.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (controller: SlabifyController, _: UITraitCollection) in
            controller.layoutAll()
        }
    }

    // MARK: - System bars and rotation

    /// While the frame is showing, this full-screen front window decides the status bar,
    /// keeping the host's own status bar hidden for more room. Your app's status bar
    /// settings then drive the simulated bar instead.
    override var prefersStatusBarHidden: Bool { isActive }
    override var preferredStatusBarUpdateAnimation: UIStatusBarAnimation { .fade }

    private var appOrientations: UIInterfaceOrientationMask {
        appWindow?.rootViewController?.supportedInterfaceOrientations ?? .all
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { appOrientations }

    // MARK: - Geometry

    /// The whole screen. The back window always covers it.
    private var sceneBounds: CGRect {
        let bounds = backgroundController.viewIfLoaded?.bounds ?? .zero
        if bounds.width > 0, bounds.height > 0 { return bounds }
        return appWindow?.windowScene?.coordinateSpace.bounds ?? .zero
    }

    /// The screen's safe area, for placing controls. While the frame is on, it's measured
    /// from the front window, which hides the status bar; the back window still reserves
    /// room for it.
    private var safeRect: CGRect {
        let frontIsFullScreen = isViewLoaded && overlayWindow.frame == sceneBounds && !overlayWindow.isHidden
        let insets = frontIsFullScreen
            ? view.safeAreaInsets
            : (backgroundController.viewIfLoaded?.safeAreaInsets ?? .zero)
        return sceneBounds.inset(by: insets)
    }

    override func viewSafeAreaInsetsDidChange() {
        super.viewSafeAreaInsetsDidChange()
        layoutAll()
    }

    /// Only iPhone Duo's inner display has room: it's the only iPhone screen at least
    /// 560 pt in both directions. The outer display, other iPhones and iPad don't qualify.
    private var hasRoomForFrame: Bool {
        let bounds = sceneBounds
        return UIDevice.current.userInterfaceIdiom == .phone
            && bounds.width >= minimumScreenSide
            && bounds.height >= minimumScreenSide
    }

    var isActive: Bool { isFrameOn && hasRoomForFrame }

    private var outerSize: CGSize {
        CGSize(width: frameSize.width + bezelWidth * 2, height: frameSize.height + bezelWidth * 2)
    }

    /// Black in light mode, white in dark mode, following the backdrop setting. Your
    /// app's own appearance isn't affected.
    private var bezelColor: UIColor {
        backdropView.traitCollection.userInterfaceStyle == .dark ? .white : .black
    }

    // MARK: - Orientation

    /// The virtual phone follows the host screen's orientation, like a real phone.
    private var screenIsLandscape: Bool { sceneBounds.width > sceneBounds.height }
    private var lastScreenIsLandscape: Bool?

    private func syncOrientationWithScreen() {
        let landscape = screenIsLandscape
        defer { lastScreenIsLandscape = landscape }

        if let preset {
            let size = preset.size(landscape: landscape)
            if isLandscape != landscape || frameSize != size {
                isLandscape = landscape
                frameSize = size
            }
        } else if let last = lastScreenIsLandscape, last != landscape {
            // Turn a custom size with the screen.
            frameSize = CGSize(width: frameSize.height, height: frameSize.width)
            isLandscape = frameSize.width > frameSize.height
            save()
        }
    }

    // MARK: - Layout

    /// Lays out all three windows. Safe to call often: it only changes what differs.
    func layoutAll() {
        guard !isLayingOut, appWindow != nil, sceneBounds.width > 0 else { return }
        isLayingOut = true
        defer { isLayingOut = false }

        loadViewIfNeeded()
        syncOrientationWithScreen()
        let active = isActive

        backdropView.isHidden = !active
        bezelView.isHidden = !active
        screenOverlay.isHidden = !active
        for control in frameControls {
            control.isHidden = !active
        }

        if active {
            if overlayWindow.frame != sceneBounds { overlayWindow.frame = sceneBounds }
            overlayWindow.isHidden = false
            showButton.isHidden = true
            layoutFramed()
        } else {
            layoutHidden()
            restoreAppWindow()
        }

        applyTraitsAndInsets(active: active)
        refreshStatusBar()
        reportActiveChange(active)
    }

    /// While the frame is hidden, the front window shrinks to just the "Slabify"
    /// button (if it's enabled), so it doesn't cover your app or affect its status bar.
    private func layoutHidden() {
        let showsButton = hasRoomForFrame && activation.contains(.button)
        guard showsButton else {
            overlayWindow.isHidden = true
            return
        }
        let size = showButton.intrinsicContentSize
        let safe = safeRect
        let frame = CGRect(x: safe.maxX - 16 - size.width, y: safe.minY + 8, width: size.width, height: size.height)
        if overlayWindow.frame != frame { overlayWindow.frame = frame }
        overlayWindow.isHidden = false
        showButton.isHidden = false
        showButton.frame = CGRect(origin: .zero, size: size)
    }

    private func reportActiveChange(_ active: Bool) {
        guard active != lastReportedActive else { return }
        let wasActive = lastReportedActive == true
        lastReportedActive = active
        setNeedsStatusBarAppearanceUpdate()
        appWindow?.rootViewController?.setNeedsStatusBarAppearanceUpdate()

        // On leaving the frame, the host's status bar comes back and pushes the safe area
        // down. Keep the "Slabify" button hidden until that has settled, then fade it in
        // at its final spot, rather than letting it jump.
        if wasActive && !active {
            showButton.alpha = 0
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, !self.isActive else { return }
                self.layoutAll()
                UIView.animate(withDuration: 0.2) { self.showButton.alpha = 1 }
            }
        }
    }

    /// The device menu row above the phone.
    private var headerHeight: CGFloat { max(presetButton.intrinsicContentSize.height, 24) }

    /// The space a row of round buttons takes from the screen edge.
    private var buttonRowHeight: CGFloat { edge + iconSize + spacing }

    /// The area the phone can occupy. The phone ignores the host's safe areas (its
    /// status bar is hidden), so it can use the full height and reach the edges.
    private func phoneArea(for arrangement: Arrangement) -> CGRect {
        let bounds = sceneBounds
        let safe = safeRect
        let header = headerHeight + spacing
        // Room for the device menu above the phone, keeping it off the top edge.
        let headerTop = safe.minY + headerTopMargin + header

        // When centered, the phone sits in the middle of the space below the device
        // menu, so the menu and phone together are centered.
        switch (placement, arrangement) {
        case (.center, .beside):
            // Round buttons in columns down both sides.
            let side = edge + iconSize + edge
            let left = safe.minX + side
            let right = safe.maxX - side
            return CGRect(x: left, y: headerTop,
                          width: max(0, right - left), height: max(0, bounds.maxY - headerTop))

        case (.center, .stacked):
            // Round buttons in rows along the top and bottom, the device menu between
            // the top row and the phone.
            let top = safe.minY + buttonRowHeight + header
            let bottom = bounds.maxY - buttonRowHeight
            return CGRect(x: safe.minX + edge, y: top,
                          width: max(0, safe.width - edge * 2), height: max(0, bottom - top))

        case (.bottomLeft, .beside), (.bottomRight, .beside):
            // The free side holds the button column at the top and the recenter button
            // beside the phone's middle. The device menu sits above the phone.
            let gutter = edge + iconSize + spacing
            if placement == .bottomLeft {
                return CGRect(x: bounds.minX, y: headerTop,
                              width: max(0, safe.maxX - gutter - bounds.minX), height: max(0, bounds.maxY - headerTop))
            }
            let minX = safe.minX + gutter
            return CGRect(x: minX, y: headerTop, width: max(0, bounds.maxX - minX), height: max(0, bounds.maxY - headerTop))

        case (.bottomLeft, .stacked), (.bottomRight, .stacked):
            // Round buttons in a row along the top, then the device menu, then the phone.
            let top = safe.minY + buttonRowHeight + header
            return CGRect(x: bounds.minX, y: top, width: bounds.width, height: max(0, bounds.maxY - top))
        }
    }

    /// The part of the phone that has to fit on screen. When parked in a corner, the
    /// bezel on the anchored side and the bottom runs off the screen, so the host's own
    /// edge stands in for it.
    private var visibleOuterSize: CGSize {
        let outer = outerSize
        guard placement != .center else { return outer }
        return CGSize(width: outer.width - bezelWidth, height: outer.height - bezelWidth)
    }

    private func fitScale(in area: CGRect) -> CGFloat {
        let outer = visibleOuterSize
        guard outer.width > 0, outer.height > 0 else { return 1 }
        return max(0.1, min(1, area.width / outer.width, area.height / outer.height))
    }

    /// Whichever arrangement shows the phone biggest, preferring "beside" when equal.
    private func preferredArrangement() -> Arrangement {
        let beside = fitScale(in: phoneArea(for: .beside))
        let stacked = fitScale(in: phoneArea(for: .stacked))
        return stacked > beside + 0.001 ? .stacked : .beside
    }

    private func layoutFramed() {
        guard let appWindow else { return }
        arrangement = frozenArrangement ?? preferredArrangement()

        let bounds = sceneBounds
        let area = phoneArea(for: arrangement)
        let scale = frozenScale ?? fitScale(in: area)
        currentScale = scale

        let outer = outerSize
        let visibleSize = CGSize(width: outer.width * scale, height: outer.height * scale)
        let center: CGPoint
        switch placement {
        case .center:
            // Center on the whole screen when the controls leave room, otherwise in
            // the space between them.
            var x = area.midX
            if bounds.midX - visibleSize.width / 2 >= area.minX,
               bounds.midX + visibleSize.width / 2 <= area.maxX {
                x = bounds.midX
            }
            center = CGPoint(x: x, y: area.midY)
        case .bottomLeft:
            // The bezel on the left and bottom sits just off screen.
            let offscreen = bezelWidth * scale
            center = CGPoint(x: area.minX + visibleSize.width / 2 - offscreen,
                             y: area.maxY - visibleSize.height / 2 + offscreen)
        case .bottomRight:
            let offscreen = bezelWidth * scale
            center = CGPoint(x: area.maxX - visibleSize.width / 2 + offscreen,
                             y: area.maxY - visibleSize.height / 2 + offscreen)
        }

        let transform = CGAffineTransform(scaleX: scale, y: scale)
        let radius = preset?.cornerRadius ?? 12
        let bezelRadius = radius > 0 ? radius + bezelWidth : 6

        // The bezel, in the back window.
        place(bezelView, size: outer, center: center, transform: transform)
        bezelView.backgroundColor = bezelColor
        bezelView.layer.cornerRadius = bezelRadius

        // Your app's window, resized to the simulated screen.
        place(appWindow, size: frameSize, center: center, transform: transform)
        appWindow.layer.cornerRadius = radius
        appWindow.layer.cornerCurve = .continuous
        appWindow.layer.masksToBounds = true
        isAppWindowFramed = true

        // The status bar and Dynamic Island, in the front window, exactly over the screen.
        place(screenOverlay, size: frameSize, center: center, transform: transform)
        screenOverlay.layer.cornerRadius = radius
        hardwareView.frame = screenOverlay.bounds
        hardwareView.cutout = preset?.cutout ?? .none
        hardwareView.isLandscape = isLandscape
        hardwareView.isHidden = preset == nil
        let statusBarHeight = max(20, preset?.insets(landscape: false).top ?? 20)
        statusBarView.frame = CGRect(x: 0, y: 0, width: frameSize.width, height: statusBarHeight)
        statusBarView.cutout = preset?.cutout ?? .none

        let phone = bezelView.frame  // on-screen bounds, after scaling
        layoutResizeHandle(phone: phone, scale: scale, bezelRadius: bezelRadius, screenRadius: radius)
        layoutControls(phone: phone, scale: scale)
        layoutRecenterButton(phone: phone)
    }

    /// Sets a view's size and position under a scale transform, only if they changed.
    private func place(_ view: UIView, size: CGSize, center: CGPoint, transform: CGAffineTransform) {
        let bounds = CGRect(origin: .zero, size: size)
        guard view.bounds != bounds || view.center != center || view.transform != transform else { return }
        view.transform = .identity
        view.bounds = bounds
        view.center = center
        view.transform = transform
    }

    /// Gives your app's window back the whole screen.
    private func restoreAppWindow() {
        guard isAppWindowFramed, let appWindow else { return }
        isAppWindowFramed = false
        appWindow.transform = .identity
        appWindow.frame = sceneBounds
        appWindow.layer.cornerRadius = originalCornerRadius
        appWindow.layer.cornerCurve = originalCornerCurve
        appWindow.layer.masksToBounds = originalMasksToBounds
    }

    // MARK: - Control layout

    private func layoutControls(phone: CGRect, scale: CGFloat) {
        let bounds = sceneBounds
        let safe = safeRect
        let top = safe.minY + edge
        let leftEdge = safe.minX + edge
        let rightEdge = safe.maxX - edge

        recenterButton.isHidden = placement == .center

        // The corner buttons sit in the screen's bottom corners, clear of the curves.
        // While parked, the other corner's button stays so you can jump straight there.
        let arrowY = bounds.maxY - edge - iconSize
        anchorLeftButton.frame = CGRect(x: bounds.minX + edge, y: arrowY, width: iconSize, height: iconSize)
        anchorRightButton.frame = CGRect(x: bounds.maxX - edge - iconSize, y: arrowY, width: iconSize, height: iconSize)
        anchorLeftButton.isHidden = placement == .bottomLeft || anchorLeftButton.frame.intersects(phone)
        anchorRightButton.isHidden = placement == .bottomRight || anchorRightButton.frame.intersects(phone)

        let tools = [backdropButton, screenshotButton]
        switch (placement, arrangement) {
        case (.center, .beside):
            // Background and screenshot down the top left, close at top right.
            layoutButtons(tools, from: CGPoint(x: leftEdge, y: top), direction: .down)
            hideButton.frame = CGRect(x: rightEdge - iconSize, y: top, width: iconSize, height: iconSize)
        case (.center, .stacked):
            layoutButtons(tools, from: CGPoint(x: leftEdge, y: top), direction: .right)
            hideButton.frame = CGRect(x: rightEdge - iconSize, y: top, width: iconSize, height: iconSize)
        case (.bottomLeft, .beside):
            // Everything on the free right side, close in the corner.
            layoutButtons([hideButton] + tools, from: CGPoint(x: rightEdge - iconSize, y: top), direction: .down)
        case (.bottomRight, .beside):
            layoutButtons([hideButton] + tools, from: CGPoint(x: leftEdge, y: top), direction: .down)
        case (.bottomLeft, .stacked):
            layoutButtons([hideButton] + tools, from: CGPoint(x: rightEdge - iconSize, y: top), direction: .left)
        case (.bottomRight, .stacked):
            layoutButtons([hideButton] + tools, from: CGPoint(x: leftEdge, y: top), direction: .right)
        }

        layoutHeader(phone: phone, scale: scale)
    }

    private enum Direction { case down, left, right }

    /// Lines up round buttons starting with the first at `origin`.
    private func layoutButtons(_ buttons: [UIButton], from origin: CGPoint, direction: Direction) {
        for (index, button) in buttons.enumerated() {
            let step = CGFloat(index) * (iconSize + spacing)
            let point: CGPoint
            switch direction {
            case .down: point = CGPoint(x: origin.x, y: origin.y + step)
            case .left: point = CGPoint(x: origin.x - step, y: origin.y)
            case .right: point = CGPoint(x: origin.x + step, y: origin.y)
            }
            button.frame = CGRect(origin: point, size: CGSize(width: iconSize, height: iconSize))
        }
    }

    /// The device menu, with the size info to its right, centered just above the phone
    /// and never closer than `headerTopMargin` to the top of the screen.
    private func layoutHeader(phone: CGRect, scale: CGFloat) {
        let safe = safeRect
        sizeLabel.text = sizeDescription(scale: scale)
        let buttonSize = presetButton.intrinsicContentSize
        let labelSize = sizeLabel.sizeThatFits(CGSize(width: 600, height: 100))
        let width = buttonSize.width + spacing + labelSize.width

        let x = min(max(phone.midX - width / 2, safe.minX + edge), safe.maxX - edge - width)
        let y = max(safe.minY + headerTopMargin, phone.minY - spacing - buttonSize.height)

        presetButton.frame = CGRect(origin: CGPoint(x: x, y: y), size: buttonSize)
        sizeLabel.frame = CGRect(
            x: presetButton.frame.maxX + spacing, y: presetButton.frame.midY - labelSize.height / 2,
            width: labelSize.width, height: labelSize.height
        )
    }

    /// Beside the parked phone's free edge, halfway down, pointing back toward the middle.
    private func layoutRecenterButton(phone: CGRect) {
        guard placement != .center else { return }
        let bounds = sceneBounds
        let half = iconSize / 2
        let x = placement == .bottomLeft
            ? phone.maxX + spacing + half
            : phone.minX - spacing - half
        let center = CGPoint(
            x: min(max(x, bounds.minX + edge + half), bounds.maxX - edge - half),
            y: min(max(phone.midY, safeRect.minY + edge + half), bounds.maxY - edge - half)
        )
        recenterButton.frame = CGRect(x: center.x - half, y: center.y - half, width: iconSize, height: iconSize)
    }

    /// Hugs the corner furthest from the anchored one, always just outside the bezel.
    /// If the phone is close to the screen edge, the arc is simply clipped there.
    private func layoutResizeHandle(phone: CGRect, scale: CGFloat, bezelRadius: CGFloat, screenRadius: CGFloat) {
        let corner: ResizeHandleView.Corner
        switch placement {
        case .center: corner = .bottomRight
        case .bottomLeft: corner = .topRight
        case .bottomRight: corner = .topLeft
        }
        let inset = bezelWidth * scale
        resizeHandle.configure(
            corner: corner,
            phone: phone,
            cornerRadius: bezelRadius * scale,
            screen: phone.insetBy(dx: inset, dy: inset),
            screenRadius: screenRadius * scale,
            gap: 8   // from the bezel's edge to the middle of the arc's stroke
        )
    }

    // MARK: - Your app's traits and safe areas

    private func currentSizeClasses() -> (UIUserInterfaceSizeClass, UIUserInterfaceSizeClass) {
        if let preset {
            return preset.sizeClasses(landscape: isLandscape)
        }
        // Custom sizes: roughly follow how iPhones and iPad multitasking behave.
        return (
            frameSize.width < 500 ? .compact : .regular,
            frameSize.height < 500 ? .compact : .regular
        )
    }

    /// Size classes go on the app window, so everything in it, including anything it
    /// presents, uses its iPhone layout. Safe areas are topped up per view controller.
    private func applyTraitsAndInsets(active: Bool) {
        guard let appWindow else { return }

        if active {
            // Reading a trait override that hasn't been set throws an exception,
            // so check contains(_:) before comparing.
            let (horizontal, vertical) = currentSizeClasses()
            let overrides = appWindow.traitOverrides
            if !overrides.contains(UITraitHorizontalSizeClass.self) || overrides.horizontalSizeClass != horizontal {
                appWindow.traitOverrides.horizontalSizeClass = horizontal
            }
            if !overrides.contains(UITraitVerticalSizeClass.self) || overrides.verticalSizeClass != vertical {
                appWindow.traitOverrides.verticalSizeClass = vertical
            }
        } else {
            if appWindow.traitOverrides.contains(UITraitHorizontalSizeClass.self) {
                appWindow.traitOverrides.remove(UITraitHorizontalSizeClass.self)
            }
            if appWindow.traitOverrides.contains(UITraitVerticalSizeClass.self) {
                appWindow.traitOverrides.remove(UITraitVerticalSizeClass.self)
            }
        }

        // The root view controller and everything presented on top of it.
        var chain: [UIViewController] = []
        var next = appWindow.rootViewController
        while let controller = next {
            chain.append(controller)
            next = controller.presentedViewController
        }
        let current = Set(chain.map(ObjectIdentifier.init))

        // Take Slabify's insets back off controllers that have left the window.
        for (id, entry) in appliedInsets where !current.contains(id) {
            if let controller = entry.controller.value {
                setSimulatedInsets(.zero, on: controller)
            } else {
                appliedInsets[id] = nil
            }
        }
        for controller in chain {
            setSimulatedInsets(active ? neededInsets(for: controller) : .zero, on: controller)
        }
        updateSwiftUIPadding(active: active)
    }

    /// The adjustment that gives a view controller exactly the simulated phone's safe
    /// area. iOS may already give the shrunken window some insets of its own (more or
    /// less than the simulated phone has), so this measures them and makes up the
    /// difference, which can be negative.
    private func neededInsets(for controller: UIViewController) -> UIEdgeInsets {
        guard let appWindow, !(controller is UIAlertController) else { return .zero }
        let target = preset?.insets(landscape: isLandscape) ?? .zero

        // What the system gives this view controller, without any additional insets.
        let system: UIEdgeInsets
        if let view = controller.viewIfLoaded, view.window === appWindow {
            let total = view.safeAreaInsets
            let additional = controller.additionalSafeAreaInsets
            system = UIEdgeInsets(
                top: max(0, total.top - additional.top),
                left: max(0, total.left - additional.left),
                bottom: max(0, total.bottom - additional.bottom),
                right: max(0, total.right - additional.right)
            )
        } else {
            // Not on screen yet (about to be presented): the window's insets are the
            // best guess, and the next refresh corrects it.
            system = appWindow.safeAreaInsets
        }

        var needed = UIEdgeInsets(
            top: target.top - system.top,
            left: target.left - system.left,
            bottom: target.bottom - system.bottom,
            right: target.right - system.right
        )
        if controller !== appWindow.rootViewController {
            switch controller.modalPresentationStyle {
            case .fullScreen, .overFullScreen, .currentContext, .overCurrentContext, .custom, .none:
                break
            default:
                // Sheets start below the status bar; only adjust the bottom and sides.
                needed.top = 0
            }
        }
        if Self.isSwiftUIHost(controller) {
            // SwiftUI's hosting controller manages its own bottom inset; the `.slabify()`
            // modifier adds the missing bottom space inside SwiftUI instead.
            needed.bottom = 0
        }
        // Round so tiny measurement differences don't cause endless updates.
        return UIEdgeInsets(top: needed.top.rounded(), left: needed.left.rounded(),
                            bottom: needed.bottom.rounded(), right: needed.right.rounded())
    }

    /// Whether a view controller hosts SwiftUI content (a `UIHostingController`, including
    /// the one a SwiftUI app's window starts with).
    private static func isSwiftUIHost(_ controller: UIViewController) -> Bool {
        NSStringFromClass(type(of: controller)).contains("UIHostingController")
    }

    /// Adds Slabify's share of a view controller's `additionalSafeAreaInsets`, on top
    /// of whatever your app set itself, replacing Slabify's previous share.
    private func setSimulatedInsets(_ insets: UIEdgeInsets, on controller: UIViewController) {
        let id = ObjectIdentifier(controller)
        let previous = appliedInsets[id]?.insets ?? .zero
        guard insets != previous else { return }
        let current = controller.additionalSafeAreaInsets
        controller.additionalSafeAreaInsets = UIEdgeInsets(
            top: current.top - previous.top + insets.top,
            left: current.left - previous.left + insets.left,
            bottom: current.bottom - previous.bottom + insets.bottom,
            right: current.right - previous.right + insets.right
        )
        if insets == .zero {
            appliedInsets[id] = nil
        } else {
            appliedInsets[id] = (controller: WeakController(controller), insets: insets)
        }
    }

    // MARK: - SwiftUI bottom padding

    private final class WeakInsets {
        weak var value: SlabifySwiftUIInsets?
        init(_ value: SlabifySwiftUIInsets) { self.value = value }
    }
    private var swiftUIInsets: [WeakInsets] = []

    /// Called by the `.slabify()` modifier so Slabify can pad SwiftUI's bottom safe area.
    func register(_ insets: SlabifySwiftUIInsets) {
        guard !swiftUIInsets.contains(where: { $0.value === insets }) else { return }
        swiftUIInsets.append(WeakInsets(insets))
        updateSwiftUIPadding(active: isActive)
    }

    /// The bottom space SwiftUI content is missing: the simulated home indicator area,
    /// less what iOS already gives the window.
    private func updateSwiftUIPadding(active: Bool) {
        swiftUIInsets.removeAll { $0.value == nil }
        guard !swiftUIInsets.isEmpty else { return }
        var bottom: CGFloat = 0
        if active, let root = appWindow?.rootViewController, Self.isSwiftUIHost(root),
           let view = root.viewIfLoaded {
            let target = preset?.insets(landscape: isLandscape).bottom ?? 0
            bottom = max(0, (target - view.safeAreaInsets.bottom).rounded())
        }
        for box in swiftUIInsets {
            if let model = box.value, abs(model.bottom - bottom) > 0.5 {
                model.bottom = bottom
            }
        }
    }

    /// Called just before your app presents a view controller in the framed window.
    func prepareForPresentation(of controller: UIViewController) {
        guard isActive else { return }
        setSimulatedInsets(neededInsets(for: controller), on: controller)
    }

    // MARK: - Simulated status bar

    @objc private func refreshTimerFired() {
        guard isActive else { return }
        applyTraitsAndInsets(active: true)
        refreshStatusBar()
    }

    /// The view controller iOS would ask about the status bar: the topmost full-screen
    /// presentation, or the root.
    private func statusBarOwner() -> UIViewController? {
        var owner = appWindow?.rootViewController
        var next = owner?.presentedViewController
        while let controller = next {
            switch controller.modalPresentationStyle {
            case .fullScreen, .overFullScreen:
                owner = controller
            default:
                if controller.modalPresentationCapturesStatusBarAppearance { owner = controller }
            }
            next = controller.presentedViewController
        }
        return owner
    }

    /// Follows the view controller chain the way UIKit does to find who decides.
    private func resolved(_ start: UIViewController, _ next: (UIViewController) -> UIViewController?) -> UIViewController {
        var controller = start
        while let child = next(controller), child !== controller {
            controller = child
        }
        return controller
    }

    /// The simulated status bar follows your app: it hides when your app hides the
    /// status bar, and in landscape like a real iPhone.
    private func refreshStatusBar() {
        guard let owner = statusBarOwner() else {
            statusBarView.isHidden = true
            return
        }
        let appHidesStatusBar = resolved(owner) { $0.childForStatusBarHidden }.prefersStatusBarHidden
        let visible = isActive && preset != nil && !isLandscape && !appHidesStatusBar
        statusBarView.isHidden = !visible
        guard visible else { return }

        // Like iOS: an explicit style wins; otherwise the status bar matches the light or
        // dark appearance of the view controller that decides it (which may override the
        // system setting, e.g. a screen that's always dark).
        let decider = resolved(owner) { $0.childForStatusBarStyle }
        let isDark: Bool
        switch decider.preferredStatusBarStyle {
        case .lightContent: isDark = false
        case .darkContent: isDark = true
        default: isDark = decider.traitCollection.userInterfaceStyle != .dark
        }
        statusBarView.contentColor = isDark ? .black : .white
        statusBarView.updateTime()
    }

    // MARK: - Resizing

    @objc private func handleResize(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            dragStartSize = frameSize
            frozenScale = currentScale
            frozenArrangement = arrangement
            snapFeedback.prepare()

        case .changed:
            let scale = frozenScale ?? 1
            let translation = gesture.translation(in: view)
            let maximum = maximumFrameSize(scale: scale)

            // A centered frame grows on both sides, so each edge moves by half the
            // change. A parked frame only grows away from its anchored corner.
            let delta: CGSize
            switch placement {
            case .center: delta = CGSize(width: 2 * translation.x, height: 2 * translation.y)
            case .bottomLeft: delta = CGSize(width: translation.x, height: -translation.y)
            case .bottomRight: delta = CGSize(width: -translation.x, height: -translation.y)
            }

            let width = min(max(dragStartSize.width + delta.width / scale, minimumSide), maximum.width)
            let height = min(max(dragStartSize.height + delta.height / scale, minimumSide), maximum.height)
            let proposed = CGSize(width: width.rounded(), height: height.rounded())

            let previousID = preset?.id

            if let match = snapMatch(for: proposed) {
                preset = match
                isLandscape = screenIsLandscape
                frameSize = match.size(landscape: isLandscape)
                if previousID != match.id {
                    snapFeedback.selectionChanged()
                }
            } else {
                preset = nil
                isLandscape = proposed.width > proposed.height
                frameSize = proposed
            }

            if previousID != preset?.id { updateControls() }
            layoutAll()

        case .ended, .cancelled, .failed:
            frozenScale = nil
            frozenArrangement = nil
            save()
            animateLayout()

        default:
            break
        }
    }

    private func maximumFrameSize(scale: CGFloat) -> CGSize {
        let area = phoneArea(for: arrangement)
        // Parked phones have one side and the bottom of their bezel off screen.
        let bezels: CGFloat = placement == .center ? 2 : 1
        return CGSize(
            width: max(minimumSide, area.width / scale - bezelWidth * bezels),
            height: max(minimumSide, area.height / scale - bezelWidth * bezels)
        )
    }

    /// Several devices share a size (e.g. 17 Pro and 18 Pro). Keep the current preset
    /// if it matches; otherwise the newest device of that size wins. Only sizes in
    /// the screen's orientation snap, since presets follow it.
    private func snapMatch(for size: CGSize) -> DevicePreset? {
        let landscape = screenIsLandscape
        let candidates = [preset].compactMap { $0 } + DevicePreset.snapOrder
        return candidates.first { candidate in
            let target = candidate.size(landscape: landscape)
            return abs(target.width - size.width) <= snapTolerance
                && abs(target.height - size.height) <= snapTolerance
        }
    }

    // MARK: - Screenshots

    /// Captures the simulated screen, or the whole phone including its bezel, at the
    /// device's native resolution and offers it in the share sheet.
    ///
    /// Captures are sharpest when the phone is shown at 100%.
    private func takeScreenshot(includeFrame: Bool) {
        guard let appWindow else { return }

        let format = UIGraphicsImageRendererFormat()
        format.scale = traitCollection.displayScale
        format.opaque = !includeFrame   // keep the rounded corners transparent

        let screenSize = frameSize
        let radius = preset?.cornerRadius ?? 12
        let showsStatusBar = !statusBarView.isHidden
        let image: UIImage

        if includeFrame {
            // The whole phone: bezel, screen, status bar and Dynamic Island.
            let outer = outerSize
            let bezelRadius = radius > 0 ? radius + bezelWidth : 6
            let screenRect = CGRect(x: bezelWidth, y: bezelWidth, width: screenSize.width, height: screenSize.height)
            let bezel = bezelColor
            image = UIGraphicsImageRenderer(size: outer, format: format).image { _ in
                bezel.setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: outer), cornerRadius: bezelRadius).fill()
                UIBezierPath(roundedRect: screenRect, cornerRadius: radius).addClip()
                appWindow.drawHierarchy(in: screenRect, afterScreenUpdates: true)
                if showsStatusBar {
                    statusBarView.drawHierarchy(in: statusBarView.frame.offsetBy(dx: bezelWidth, dy: bezelWidth),
                                                afterScreenUpdates: true)
                }
                if !hardwareView.isHidden {
                    hardwareView.drawHierarchy(in: screenRect, afterScreenUpdates: true)
                }
            }
        } else {
            // Like a real screenshot: rectangular, with the status bar but no island.
            image = UIGraphicsImageRenderer(size: screenSize, format: format).image { _ in
                appWindow.drawHierarchy(in: CGRect(origin: .zero, size: screenSize), afterScreenUpdates: true)
                if showsStatusBar {
                    statusBarView.drawHierarchy(in: statusBarView.frame, afterScreenUpdates: true)
                }
            }
        }

        flashScreen()
        shareScreenshot(image, includeFrame: includeFrame)
    }

    private func flashScreen() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        let flash = UIView(frame: bezelView.frame)
        flash.backgroundColor = .white
        flash.layer.cornerRadius = bezelView.layer.cornerRadius * currentScale
        flash.layer.cornerCurve = .continuous
        flash.isUserInteractionEnabled = false
        view.addSubview(flash)
        UIView.animate(withDuration: 0.35, delay: 0, options: .curveEaseOut) {
            flash.alpha = 0
        } completion: { _ in
            flash.removeFromSuperview()
        }
    }

    private func shareScreenshot(_ image: UIImage, includeFrame: Bool) {
        guard let data = image.pngData() else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        let deviceName = preset?.name ?? "Custom \(Int(frameSize.width))x\(Int(frameSize.height))"
        let kind = includeFrame ? "Frame" : "Screen"
        let name = "\(deviceName) \(kind) \(formatter.string(from: .now)).png"
            .replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)

        do {
            try data.write(to: url, options: .atomic)
        } catch {
            print("Slabify: couldn't save screenshot: \(error)")
            return
        }

        let activity = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        // "Save Image" needs this key in your Info.plist, so only offer it when present.
        if Bundle.main.object(forInfoDictionaryKey: "NSPhotoLibraryAddUsageDescription") == nil {
            activity.excludedActivityTypes = [.saveToCameraRoll]
        }
        activity.popoverPresentationController?.sourceView = screenshotButton
        activity.popoverPresentationController?.sourceRect = screenshotButton.bounds
        present(activity, animated: true)
    }

    // MARK: - Actions

    private func select(_ newPreset: DevicePreset) {
        preset = newPreset
        isLandscape = screenIsLandscape
        frameSize = newPreset.size(landscape: isLandscape)
        updateControls()
        save()
        animateLayout()
    }

    private func setPlacement(_ newPlacement: Placement) {
        guard newPlacement != placement else { return }
        // The resize arc jumps to a different corner, so fade it out, move the phone,
        // then fade it back in at its new spot rather than sliding it across.
        UIView.animate(withDuration: 0.12, animations: {
            self.resizeHandle.alpha = 0
        }, completion: { _ in
            self.placement = newPlacement
            self.updateControls()
            self.save()
            self.animateLayout {
                UIView.animate(withDuration: 0.2) { self.resizeHandle.alpha = 1 }
            }
        })
    }

    private func setBackdrop(_ newBackdrop: Backdrop) {
        backdrop = newBackdrop
        applyBackdrop()
        updateControls()
        save()
        layoutAll()   // recolors the bezel
    }

    private func setFrameOn(_ on: Bool) {
        isFrameOn = on
        save()
        animateLayout()
    }

    private func animateLayout(completion: (() -> Void)? = nil) {
        UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.9, initialSpringVelocity: 0, options: []) {
            self.layoutAll()
            self.appWindow?.layoutIfNeeded()
        } completion: { _ in
            completion?()
        }
    }

    /// Applies the backdrop's color scheme to everything around the phone. Each view
    /// gets the override individually so it never reaches your app's views.
    private func applyBackdrop() {
        let style = backdrop.style
        for chrome in chromeViews {
            chrome.overrideUserInterfaceStyle = style
        }
    }

    // MARK: - Activation gesture

    private var lastActivationSwipe: Date?

    /// Three-finger swipe up, twice, shows or hides the frame. It watches alongside
    /// your app's own gestures and never cancels their touches.
    private func setUpActivationGesture(on window: UIWindow) {
        guard activation.contains(.threeFingerDoubleSwipe) else { return }
        let swipe = UISwipeGestureRecognizer(target: self, action: #selector(handleActivationSwipe(_:)))
        swipe.direction = .up
        swipe.numberOfTouchesRequired = 3
        swipe.cancelsTouchesInView = false
        swipe.delaysTouchesBegan = false
        swipe.delaysTouchesEnded = false
        swipe.delegate = self
        window.addGestureRecognizer(swipe)
    }

    @objc private func handleActivationSwipe(_ gesture: UISwipeGestureRecognizer) {
        let now = Date()
        if let last = lastActivationSwipe, now.timeIntervalSince(last) < 0.8 {
            lastActivationSwipe = nil
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            setFrameOn(!isFrameOn)
        } else {
            lastActivationSwipe = now
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    // MARK: - Controls

    private func setUpResizeHandle() {
        resizeHandle.addGestureRecognizer(
            UIPanGestureRecognizer(target: self, action: #selector(handleResize(_:)))
        )
        view.addSubview(resizeHandle)
    }

    private func setUpControls() {
        presetButton.showsMenuAsPrimaryAction = true
        presetButton.accessibilityLabel = "Device size"

        configureRoundButton(backdropButton, symbol: "circle.lefthalf.filled", label: "Background")
        backdropButton.showsMenuAsPrimaryAction = true

        configureRoundButton(screenshotButton, symbol: "camera.viewfinder", label: "Take screenshot")
        screenshotButton.showsMenuAsPrimaryAction = true
        screenshotButton.menu = UIMenu(title: "Screenshot", children: [
            UIAction(title: "With Device Frame", image: UIImage(systemName: "iphone")) { [weak self] _ in
                self?.takeScreenshot(includeFrame: true)
            },
            UIAction(title: "Screen Only", image: UIImage(systemName: "rectangle.portrait")) { [weak self] _ in
                self?.takeScreenshot(includeFrame: false)
            },
        ])

        configureRoundButton(hideButton, symbol: "xmark", label: "Hide Slabify")
        hideButton.addAction(UIAction { [weak self] _ in self?.setFrameOn(false) }, for: .primaryActionTriggered)

        configureRoundButton(anchorLeftButton, symbol: "arrow.down.left", label: "Move to bottom left")
        anchorLeftButton.addAction(UIAction { [weak self] _ in self?.setPlacement(.bottomLeft) }, for: .primaryActionTriggered)

        configureRoundButton(anchorRightButton, symbol: "arrow.down.right", label: "Move to bottom right")
        anchorRightButton.addAction(UIAction { [weak self] _ in self?.setPlacement(.bottomRight) }, for: .primaryActionTriggered)

        configureRoundButton(recenterButton, symbol: "arrow.up.right", label: "Move to center")
        recenterButton.addAction(UIAction { [weak self] _ in self?.setPlacement(.center) }, for: .primaryActionTriggered)

        sizeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        sizeLabel.textColor = .secondaryLabel
        sizeLabel.textAlignment = .left
        sizeLabel.numberOfLines = 1

        // Above the resize arc, so they win taps where they overlap its touch area.
        for control in [presetButton, sizeLabel, backdropButton, screenshotButton, hideButton,
                        anchorLeftButton, anchorRightButton, recenterButton] as [UIView] {
            view.addSubview(control)
        }
    }

    private func symbol(_ name: String, fallback: String) -> UIImage? {
        UIImage(systemName: name) ?? UIImage(systemName: fallback)
    }

    private func configureRoundButton(_ button: UIButton, symbol name: String, label: String) {
        var config = UIButton.Configuration.gray()
        config.image = symbol(name, fallback: "circle")
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
        config.cornerStyle = .capsule
        config.contentInsets = .zero
        config.baseForegroundColor = .label
        button.configuration = config
        button.accessibilityLabel = label
    }

    private func setUpShowButton() {
        var config = UIButton.Configuration.filled()
        config.title = "Slabify"
        config.cornerStyle = .capsule
        config.buttonSize = .small
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 13, weight: .bold)
            return attributes
        }
        showButton.configuration = config
        showButton.addAction(UIAction { [weak self] _ in self?.setFrameOn(true) }, for: .primaryActionTriggered)
        view.addSubview(showButton)
    }

    private func updateControls() {
        var config = UIButton.Configuration.gray()
        config.title = preset?.name ?? "Custom"
        config.image = UIImage(systemName: "chevron.down")
        config.imagePlacement = .trailing
        config.imagePadding = 4
        config.cornerStyle = .capsule
        config.baseForegroundColor = .label
        config.contentInsets = NSDirectionalEdgeInsets(top: 7, leading: 12, bottom: 7, trailing: 10)
        config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 9, weight: .bold)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer { attributes in
            var attributes = attributes
            attributes.font = .systemFont(ofSize: 13, weight: .semibold)
            return attributes
        }
        presetButton.configuration = config
        presetButton.menu = makePresetMenu()

        backdropButton.configuration?.image = backdropSymbol(backdrop)
        backdropButton.menu = makeBackdropMenu()

        // Points from the parked phone's free side back toward the middle.
        recenterButton.configuration?.image = UIImage(
            systemName: placement == .bottomRight ? "arrow.up.left" : "arrow.up.right"
        )
    }

    private func makePresetMenu() -> UIMenu {
        var elements: [UIMenuElement] = DevicePreset.all.map { option in
            UIAction(
                title: option.name,
                subtitle: "\(Int(option.portraitSize.width)) × \(Int(option.portraitSize.height)) pt",
                state: option.id == preset?.id ? .on : .off
            ) { [weak self] _ in
                self?.select(option)
            }
        }
        if preset == nil {
            let custom = UIAction(
                title: "Custom",
                subtitle: "Drag the corner arc to resize",
                attributes: .disabled,
                state: .on
            ) { _ in }
            elements.append(UIMenu(options: .displayInline, children: [custom]))
        }
        return UIMenu(title: "Device Size", children: elements)
    }

    private func makeBackdropMenu() -> UIMenu {
        let options: [(Backdrop, String)] = [
            (.system, "System"),
            (.light, "Light"),
            (.dark, "Dark"),
        ]
        return UIMenu(title: "Background", children: options.map { option, title in
            UIAction(
                title: title,
                image: backdropSymbol(option),
                state: option == backdrop ? .on : .off
            ) { [weak self] _ in
                self?.setBackdrop(option)
            }
        })
    }

    private func backdropSymbol(_ backdrop: Backdrop) -> UIImage? {
        switch backdrop {
        case .system: return symbol("circle.lefthalf.filled", fallback: "circle")
        case .light: return symbol("sun.max", fallback: "circle")
        case .dark: return symbol("moon", fallback: "circle.fill")
        }
    }

    /// One line next to the device menu, e.g. "wC hR · 402 × 874 pt · 100%".
    private func sizeDescription(scale: CGFloat) -> String {
        let (horizontal, vertical) = currentSizeClasses()
        let size = "\(Int(frameSize.width.rounded())) × \(Int(frameSize.height.rounded())) pt"
        let percent = Int((scale * 100).rounded())
        return "w\(shortName(horizontal)) h\(shortName(vertical)) · \(size) · \(percent)%"
    }

    private func shortName(_ sizeClass: UIUserInterfaceSizeClass) -> String {
        switch sizeClass {
        case .compact: return "C"
        case .regular: return "R"
        default: return "?"
        }
    }

    // MARK: - Persistence

    private enum Keys {
        static let presetID = "Slabify.presetID"
        static let width = "Slabify.width"
        static let height = "Slabify.height"
        static let frameOn = "Slabify.frameOn"
        static let placement = "Slabify.placement"
        static let backdrop = "Slabify.backdrop"
        static let customID = "custom"
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(preset?.id ?? Keys.customID, forKey: Keys.presetID)
        defaults.set(Double(frameSize.width), forKey: Keys.width)
        defaults.set(Double(frameSize.height), forKey: Keys.height)
        defaults.set(isFrameOn, forKey: Keys.frameOn)
        defaults.set(placement.rawValue, forKey: Keys.placement)
        defaults.set(backdrop.rawValue, forKey: Keys.backdrop)
    }
}
#endif
