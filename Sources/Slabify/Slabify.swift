import SwiftUI
import UIKit

/// A debug-only tool that shows your app inside a resizable "device" frame
/// on large screens such as iPhone Duo's inner display.
///
/// It only appears on iPhone Duo's inner display, the only iPhone screen with room
/// for it. Elsewhere (other iPhones, iPad, the Duo's outer display) your app runs as
/// usual. In Release builds every entry point is a no-op, so call sites never need
/// `#if DEBUG`.
public enum Slabify {

    /// Slabify only runs on iPhone. On iPad, wrapping is skipped entirely.
    @MainActor
    static var isSupportedDevice: Bool {
        UIDevice.current.userInterfaceIdiom == .phone
    }

    /// Ways to show and hide the frame.
    public struct Activation: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        /// A small "Slabify" button in the top-right corner while the frame is
        /// hidden. Leave it out if you'd rather nothing sits over your UI.
        public static let button = Activation(rawValue: 1 << 0)

        /// Swipe up with three fingers twice in quick succession to show or hide the frame.
        public static let threeFingerDoubleSwipe = Activation(rawValue: 1 << 1)

        /// The button and the gesture. The default.
        public static let all: Activation = [.button, .threeFingerDoubleSwipe]
    }

    /// Sets up Slabify for the window this view controller ends up in, and returns
    /// the same view controller.
    ///
    /// ```swift
    /// window.rootViewController = Slabify.wrap(rootViewController)
    /// // Gesture only, no button over your UI:
    /// window.rootViewController = Slabify.wrap(rootViewController, activation: .threeFingerDoubleSwipe)
    /// ```
    ///
    /// Your view controller stays the window's root: Slabify resizes the window itself
    /// rather than wrapping it in a container. In Release builds this does nothing.
    @MainActor
    public static func wrap(_ root: UIViewController, activation: Activation = .all) -> UIViewController {
        #if DEBUG
        guard isSupportedDevice else { return root }
        let anchor = SlabifyAnchorView()
        anchor.activation = activation
        root.view.addSubview(anchor)
        #endif
        return root
    }

    /// Sets up Slabify for a window, e.g. in `scene(_:willConnectTo:options:)`:
    ///
    /// ```swift
    /// Slabify.install(in: window)
    /// ```
    ///
    /// The window's root view controller isn't changed, and can be replaced later
    /// without calling this again. Safe to call more than once. Does nothing in
    /// Release builds.
    @MainActor
    public static func install(in window: UIWindow?, activation: Activation = .all) {
        #if DEBUG
        guard isSupportedDevice, let window else { return }
        SlabifySession.attach(to: window, activation: activation)
        #endif
    }
}

/// The Objective-C entry point. In Swift, use ``Slabify`` instead.
///
/// ```objc
/// @import Slabify;
///
/// self.window.rootViewController = [Slabify wrapViewController:root];
/// // or, for a storyboard-based app:
/// [Slabify installInWindow:self.window];
/// // Gesture only, no button over your UI:
/// [Slabify installInWindow:self.window showsButton:NO];
/// ```
@objc(Slabify)
public final class SlabifyObjC: NSObject {

    /// See ``Slabify/wrap(_:activation:)``.
    @MainActor
    @objc(wrapViewController:)
    public static func wrap(_ root: UIViewController) -> UIViewController {
        Slabify.wrap(root)
    }

    /// Like `wrapViewController:`, choosing whether the "Slabify" button appears.
    /// The three-finger double swipe always works.
    @MainActor
    @objc(wrapViewController:showsButton:)
    public static func wrap(_ root: UIViewController, showsButton: Bool) -> UIViewController {
        Slabify.wrap(root, activation: showsButton ? .all : .threeFingerDoubleSwipe)
    }

    /// See ``Slabify/install(in:activation:)``.
    @MainActor
    @objc(installInWindow:)
    public static func install(in window: UIWindow?) {
        Slabify.install(in: window)
    }

    /// Like `installInWindow:`, choosing whether the "Slabify" button appears.
    /// The three-finger double swipe always works.
    @MainActor
    @objc(installInWindow:showsButton:)
    public static func install(in window: UIWindow?, showsButton: Bool) {
        Slabify.install(in: window, activation: showsButton ? .all : .threeFingerDoubleSwipe)
    }
}

public extension View {

    /// Sets up Slabify for the window this view is shown in.
    ///
    /// ```swift
    /// ContentView().slabify()
    /// // Gesture only, no button over your UI:
    /// ContentView().slabify(activation: .threeFingerDoubleSwipe)
    /// ```
    ///
    /// Your view isn't moved or re-hosted, so it can go anywhere in your root view.
    /// In Release builds this returns the view unchanged.
    @ViewBuilder
    func slabify(activation: Slabify.Activation = .all) -> some View {
        #if DEBUG
        if Slabify.isSupportedDevice {
            modifier(SlabifyModifier(activation: activation))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if DEBUG
/// Extra bottom safe area for SwiftUI content. SwiftUI's hosting controller manages its
/// own bottom inset (it uses it for keyboard avoidance), so Slabify can't add the
/// simulated phone's home indicator space there. It's added inside SwiftUI instead.
final class SlabifySwiftUIInsets: ObservableObject {
    @Published var bottom: CGFloat = 0
}

/// Sets up Slabify for the window and pads the bottom safe area as needed.
struct SlabifyModifier: ViewModifier {
    let activation: Slabify.Activation
    @StateObject private var insets = SlabifySwiftUIInsets()

    func body(content: Content) -> some View {
        content
            .safeAreaPadding(.bottom, insets.bottom)
            .background { SlabifyAnchor(activation: activation, insets: insets) }
    }
}

/// An invisible view that sets up Slabify for the window it's placed in.
struct SlabifyAnchor: UIViewRepresentable {
    let activation: Slabify.Activation
    let insets: SlabifySwiftUIInsets

    func makeUIView(context: Context) -> SlabifyAnchorView {
        let anchor = SlabifyAnchorView()
        anchor.activation = activation
        anchor.swiftUIInsets = insets
        return anchor
    }

    func updateUIView(_ anchor: SlabifyAnchorView, context: Context) {}
}
#endif
