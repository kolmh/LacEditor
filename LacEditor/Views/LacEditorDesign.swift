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
    static let sidebarDisclosureAnimation = Animation.easeInOut(duration: 0.22)
}

/// The same native material used by Finder's sidebar. AppKit follows the
/// window active state automatically, including the dimmed inactive variant.
struct SidebarMaterialBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = .sidebar
        nsView.blendingMode = .behindWindow
        nsView.state = .followsWindowActiveState
    }
}

/// Keeps SwiftUI List's underlying scroll view on the native overlay style,
/// which follows the window's active appearance instead of drawing a dark
/// legacy track.
struct NativeScrollViewConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfiguratorView {
        ConfiguratorView()
    }

    func updateNSView(_ nsView: ConfiguratorView, context: Context) {
        nsView.configureScrollViews()
    }

    final class ConfiguratorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureScrollViews()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configureScrollViews()
        }

        override func layout() {
            super.layout()
            configureScrollViews()
        }

        func configureScrollViews() {
            let configure = { [weak self] in
                guard let self, let root = self.window?.contentView else { return }
                // SwiftUI may attach the representable beside the List/ScrollView
                // rather than inside it. Walk the completed window hierarchy so
                // the real AppKit scrollers are configured after layout.
                Self.walk(root)
            }
            configure()
            DispatchQueue.main.async(execute: configure)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: configure)
        }

        private static func walk(_ view: NSView) {
            if let scrollView = view as? NSScrollView {
                configure(scrollView)
            }
            view.subviews.forEach(walk)
        }

        private static func configure(_ scrollView: NSScrollView) {
            scrollView.scrollerStyle = .overlay
            scrollView.autohidesScrollers = true
            // On a light macOS appearance AppKit's dark knob is the native
            // Finder style; a low alpha keeps it readable without becoming a
            // black bar. (The previous `.light` style produced the opposite
            // result on macOS 26.)
            scrollView.verticalScroller?.knobStyle = .dark
            scrollView.horizontalScroller?.knobStyle = .dark
            scrollView.verticalScroller?.alphaValue = 0.32
            scrollView.horizontalScroller?.alphaValue = 0.32
            scrollView.verticalScroller?.needsDisplay = true
            scrollView.horizontalScroller?.needsDisplay = true
        }
    }
}
