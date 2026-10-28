// Shows the size, size classes and safe area the app sees, so you can watch Slabify
// at work. Run it on an unfolded iPhone Duo.

import SwiftUI
import Slabify


struct DemoRootView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    var body: some View {
        GeometryReader { proxy in
            NavigationStack {
                List {
                    Section("What the app sees") {
                        LabeledContent("Size", value: "\(Int(proxy.size.width)) × \(Int(proxy.size.height)) pt")
                        LabeledContent("Width class", value: describe(horizontalSizeClass))
                        LabeledContent("Height class", value: describe(verticalSizeClass))
                        LabeledContent("Safe area", value: describe(proxy.safeAreaInsets))
                    }

                    Section("Adaptive layout") {
                        if horizontalSizeClass == .regular {
                            HStack(spacing: 12) {
                                tile("Sidebar", color: .blue)
                                tile("Detail", color: .orange)
                            }
                            .listRowInsets(EdgeInsets())
                        } else {
                            tile("Single column", color: .green)
                                .listRowInsets(EdgeInsets())
                        }
                    }

                    Section("Scrolling content") {
                        ForEach(1...30, id: \.self) { index in
                            Text("Row \(index)")
                        }
                    }
                }
                .navigationTitle("Slabify")
                .toolbar {
                    ToolbarItem(placement: .bottomBar) {
                        Text("Bottom toolbar sits above the home indicator")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private func tile(_ title: String, color: Color) -> some View {
        Text(title)
            .font(.headline)
            .frame(maxWidth: .infinity, minHeight: 80)
            .background(color.opacity(0.2))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func describe(_ sizeClass: UserInterfaceSizeClass?) -> String {
        switch sizeClass {
        case .compact: return "compact"
        case .regular: return "regular"
        default: return "unknown"
        }
    }

    private func describe(_ insets: EdgeInsets) -> String {
        "T \(Int(insets.top))  L \(Int(insets.leading))  B \(Int(insets.bottom))  R \(Int(insets.trailing))"
    }
}
