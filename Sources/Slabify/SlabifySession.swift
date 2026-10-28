#if DEBUG
import ObjectiveC
import UIKit

// How Slabify is put together
// ----------------------------
// Rather than moving your app into a container, Slabify resizes your app's own
// window to the simulated phone's screen. That way anything iOS presents in your
// window (modals, sheets, alerts, popovers) stays inside the phone, and
// `window.rootViewController` is still your own view controller.
//
// Two extra windows go around it:
// - Behind: the backdrop and the phone's bezel. Never interactive.
// - In front: the simulated status bar and Dynamic Island, plus Slabify's controls.
//   Touches anywhere except on a control pass straight through to your app.

/// Attaches Slabify to an app window, once.
@MainActor
enum SlabifySession {

    private static var controllerKey: UInt8 = 0

    /// The Slabify controller attached to a window, if any.
    static func controller(for window: UIWindow) -> SlabifyController? {
        objc_getAssociatedObject(window, &controllerKey) as? SlabifyController
    }

    static func attach(to window: UIWindow, activation: Slabify.Activation,
                       swiftUIInsets: SlabifySwiftUIInsets? = nil, attempts: Int = 20) {
        guard !(window is SlabifyWindow) else { return }
        if let existing = controller(for: window) {
            if let swiftUIInsets { existing.register(swiftUIInsets) }
            return
        }

        // The window needs its scene before the extra windows can join it.
        guard let scene = window.windowScene else {
            if attempts > 0 {
                DispatchQueue.main.async {
                    attach(to: window, activation: activation, swiftUIInsets: swiftUIInsets, attempts: attempts - 1)
                }
            }
            return
        }

        PresentationHook.install()
        let controller = SlabifyController(appWindow: window, scene: scene, activation: activation)
        // The app window keeps Slabify alive for as long as it exists.
        objc_setAssociatedObject(window, &controllerKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        if let swiftUIInsets { controller.register(swiftUIInsets) }
        controller.start()
    }
}

/// Slabify's own windows never become key, so your app's window keeps keyboard
/// focus and stays in charge of rotation.
class SlabifyWindow: UIWindow {
    override var canBecomeKey: Bool { false }
}

/// The front window: only Slabify's controls take touches. Everything else falls
/// through to your app's window underneath.
final class SlabifyPassthroughWindow: SlabifyWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        if hit === self || hit === rootViewController?.view { return nil }
        return hit
    }
}

/// The back window's content: the backdrop and the bezel. It always covers the whole
/// screen, so it also tells Slabify when the screen's size changes (rotating,
/// unfolding).
final class SlabifyBackgroundController: UIViewController {

    let backdropView = UIView()
    let bezelView = UIView()

    /// Called whenever the screen lays out or rotates.
    var onLayout: (() -> Void)?
    /// Rotation follows your app.
    var orientations: () -> UIInterfaceOrientationMask = { .all }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        backdropView.backgroundColor = .secondarySystemBackground
        view.addSubview(backdropView)
        bezelView.layer.cornerCurve = .continuous
        view.addSubview(bezelView)
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        backdropView.frame = view.bounds
        onLayout?()
        // iOS may resize the app window after this pass (e.g. while rotating), so
        // apply the layout again once it has settled.
        DispatchQueue.main.async { [weak self] in self?.onLayout?() }
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: { [weak self] _ in
            self?.onLayout?()
        }, completion: { [weak self] _ in
            self?.onLayout?()
        })
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { orientations() }
}

/// Attaches Slabify to whichever window the view ends up in. Used by `wrap(_:)` and
/// the SwiftUI modifier, which don't have the window yet when they're called.
final class SlabifyAnchorView: UIView {
    var activation: Slabify.Activation = .all
    /// Set when used from the SwiftUI modifier.
    weak var swiftUIInsets: SlabifySwiftUIInsets?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let window {
            SlabifySession.attach(to: window, activation: activation, swiftUIInsets: swiftUIInsets)
        }
    }
}

/// Gives view controllers presented in a framed window the simulated phone's safe
/// areas before they appear, so a full-screen modal's content clears the simulated
/// status bar and home indicator from its very first layout.
@MainActor
enum PresentationHook {
    private static var isInstalled = false

    static func install() {
        guard !isInstalled else { return }
        isInstalled = true
        let type = UIViewController.self
        guard
            let original = class_getInstanceMethod(type, #selector(UIViewController.present(_:animated:completion:))),
            let replacement = class_getInstanceMethod(type, #selector(UIViewController.slabify_present(_:animated:completion:)))
        else { return }
        method_exchangeImplementations(original, replacement)
    }
}

extension UIViewController {
    /// Swapped with `present(_:animated:completion:)` by `PresentationHook`, so calling
    /// it here runs the original.
    @objc func slabify_present(_ viewController: UIViewController, animated: Bool, completion: (() -> Void)?) {
        if let window = viewIfLoaded?.window, let controller = SlabifySession.controller(for: window) {
            controller.prepareForPresentation(of: viewController)
        }
        slabify_present(viewController, animated: animated, completion: completion)
    }
}
#endif
