import AppKit
import SwiftUI

enum LacEditorDesign {
    static let sidebarWidth: CGFloat = 240
    static let sidebarRowHeight: CGFloat = 36
    static let tabBarHeight: CGFloat = 34
    static let tabHeight: CGFloat = 28
    static let statusBarHeight: CGFloat = 24
    static let compactCornerRadius: CGFloat = 6
    static let edgeFadeWidth: CGFloat = 24

    static let structuralAnimation = Animation.easeOut(duration: 0.18)
    static let chromeAnimation = Animation.easeInOut(duration: 0.16)
    static let hoverAnimation = Animation.easeOut(duration: 0.09)
}

struct LacSidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}
