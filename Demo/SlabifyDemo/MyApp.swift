import SwiftUI
import Slabify

@main struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            DemoRootView()
                .slabify()   // Debug builds only; does nothing in Release.
        }
    }
}
