import AppKit
import SwiftUI

/// Window-local feedback; never participates in the document undo stack.
@MainActor
final class InlineFeedbackState: ObservableObject {
    struct Item: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let canUndo: Bool
        let symbol: String
    }
    @Published private(set) var item: Item?
    private var undoAction: (() -> Bool)?
    private var expiration: Task<Void, Never>?
    private var isInteracting = false
    private let duration: Duration

    init(duration: Duration = .seconds(6)) { self.duration = duration }
    deinit { expiration?.cancel() }

    func show(_ title: String, symbol: String = "checkmark.circle", undo: (() -> Bool)? = nil) {
        expiration?.cancel()
        undoAction = undo
        item = Item(title: title, canUndo: undo != nil, symbol: symbol)
        scheduleExpiration()
    }

    func setInteracting(_ interacting: Bool) {
        guard interacting != isInteracting else { return }
        isInteracting = interacting
        if interacting { expiration?.cancel(); expiration = nil }
        else { scheduleExpiration() }
    }

    func undo() {
        guard let action = undoAction else { return }
        undoAction = nil
        if action() { show("已撤销上次操作") }
        else { show("列表已变化，未撤销", symbol: "info.circle") }
    }

    func clear() {
        expiration?.cancel(); expiration = nil
        undoAction = nil
        item = nil
        isInteracting = false
    }

    private func scheduleExpiration() {
        expiration?.cancel()
        guard let id = item?.id, !isInteracting else { return }
        let delay = duration
        expiration = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            guard let self, self.item?.id == id else { return }
            self.clear()
        }
    }
}

/// An overlay keeps keyboard focus distinct from selection, without reflow.
private struct EditorFocusRing: ViewModifier {
    let focused: Bool
    let radius: CGFloat
    @Environment(\.isEnabled) private var enabled
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content.focusEffectDisabled()
            .overlay {
                if focused && enabled && activeState != .inactive {
                    RoundedRectangle(cornerRadius: radius)
                        .strokeBorder(LacEditorDesign.accent, lineWidth: contrast == .increased ? 3 : 2)
                        .allowsHitTesting(false).accessibilityHidden(true)
                }
            }
    }
}

extension View {
    func editorFocusRing(_ focused: Bool, radius: CGFloat = 6) -> some View {
        modifier(EditorFocusRing(focused: focused, radius: radius))
    }
}

enum LacEditorDesign {
    static let sidebarWidth: CGFloat = 250
    static let sidebarRowHeight: CGFloat = 34
    static let tabHeight: CGFloat = 28
    static let statusBarHeight: CGFloat = 24
    static let compactCornerRadius: CGFloat = 6
    static let edgeFadeWidth: CGFloat = 24

    static let structuralAnimation = Animation.easeOut(duration: 0.18)
    static let chromeAnimation = Animation.easeInOut(duration: 0.16)
    static let hoverAnimation = Animation.easeOut(duration: 0.09)
    // One non-overshooting curve in both directions: a reversal starts from
    // the visible state without a spring's momentum or a delayed collapse.
    static let sidebarDisclosureAnimation = Animation.timingCurve(0.25, 0.1, 0.25, 1, duration: 0.20)

    static let accent = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            ? NSColor(red: 0.63, green: 0.65, blue: 0.95, alpha: 1)
            : NSColor(red: 0.36, green: 0.38, blue: 0.73, alpha: 1)
    })
    static let hoverFill = Color.primary.opacity(0.045)
    static let selectionFill = accent.opacity(0.12)
    static let canvas = adaptiveColor(light: (0.953, 0.957, 0.969), dark: (0.12, 0.125, 0.14))
    static let surface = adaptiveColor(light: (1, 1, 1), dark: (0.16, 0.165, 0.185))
    static let outline = Color(nsColor: .separatorColor).opacity(0.4)
    private static let dataFileTint = adaptiveColor(light: (0.23, 0.48, 0.44), dark: (0.48, 0.71, 0.64))
    private static let scriptFileTint = adaptiveColor(light: (0.55, 0.43, 0.24), dark: (0.78, 0.68, 0.43))
    private static let markupFileTint = adaptiveColor(light: (0.61, 0.39, 0.32), dark: (0.80, 0.58, 0.48))
    private static let codeFileTint = adaptiveColor(light: (0.32, 0.46, 0.61), dark: (0.55, 0.69, 0.83))

    static func fileTint(for language: EditorLanguage) -> Color {
        switch language {
        case .markdown: accent
        case .json, .yaml, .sql: dataFileTint
        case .javascript, .typescript: scriptFileTint
        case .swift, .html, .css: markupFileTint
        case .python, .cFamily, .shell: codeFileTint
        case .plainText: .secondary
        }
    }

    private static func adaptiveColor(light: (CGFloat, CGFloat, CGFloat), dark: (CGFloat, CGFloat, CGFloat)) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let rgb = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
            return NSColor(red: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        })
    }
}

/// Shared by settings and utility windows; the editor remains a flat canvas.
struct PreferenceGroup<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 3)
            VStack(spacing: 0) { content() }
                .background(LacEditorDesign.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(LacEditorDesign.outline, lineWidth: 0.5))
        }
    }
}

struct PreferenceRow<Control: View>: View {
    let title: String
    let detail: String
    @ViewBuilder var control: () -> Control
    var body: some View {
        HStack(spacing: 20) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 13, weight: .medium))
                if !detail.isEmpty {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            control().controlSize(.regular).fixedSize(horizontal: true, vertical: false)
        }.padding(16).frame(minHeight: 64)
    }
}

struct UtilityHeading: View {
    let title: String
    let subtitle: String
    let symbol: String
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 18, weight: .medium))
                .foregroundStyle(LacEditorDesign.accent).frame(width: 40, height: 40)
                .background(LacEditorDesign.selectionFill, in: RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 19, weight: .semibold))
                Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
    }
}

struct UtilityWindowRoot<Content: View>: View {
    @ObservedObject var appState: AppState
    @ViewBuilder var content: () -> Content
    var body: some View {
        content().environmentObject(appState)
            .preferredColorScheme(appState.preferredColorScheme)
            .tint(LacEditorDesign.accent)
            .background(WindowThemeCoordinator(theme: appState.theme,
                                               systemAppearanceDidChange: appState.refreshSystemAppearance))
    }
}

struct SoftRowButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(configuration.isPressed ? LacEditorDesign.accent.opacity(0.15) : .clear,
                        in: RoundedRectangle(cornerRadius: 6))
            .animation(reduceMotion || configuration.isPressed ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

struct QuietActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Feedback(configuration: configuration) }

    private struct Feedback: View {
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        var body: some View {
            configuration.label
                .background(configuration.isPressed ? LacEditorDesign.accent.opacity(0.13)
                            : (isHovering ? LacEditorDesign.hoverFill : .clear),
                            in: RoundedRectangle(cornerRadius: 6))
                .onHover { isHovering = $0 }
                .animation(reduceMotion || configuration.isPressed ? nil : LacEditorDesign.hoverAnimation,
                           value: isHovering)
        }
    }
}

/// Animate only the clipped body. Headers never participate in the reveal's
/// placement, and children keep their natural size throughout the animation.
struct SidebarDisclosure<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isExpanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        SidebarRevealLayout(progress: isExpanded ? 1 : 0) {
            VStack(spacing: 2) { content() }
                .transaction { $0.animation = nil }
        }
        .clipped()
        // SwiftUI clipping affects drawing, not hit testing. Rows below the
        // animated reveal must not intercept the following header or a drop.
        .contentShape(Rectangle())
        .allowsHitTesting(isExpanded)
        .accessibilityHidden(!isExpanded)
        .animation(reduceMotion ? nil : LacEditorDesign.sidebarDisclosureAnimation, value: isExpanded)
    }
}

struct SidebarRevealLayout: Layout {
    var progress: CGFloat
    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        return CGSize(width: proposal.width ?? size.width, height: size.height * min(max(progress, 0), 1))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                             proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
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

/// Configures only the owning scroll view and respects the system's scrollbar
/// policy, including users who choose to always show scrollbars.
struct NativeScrollViewConfigurator: NSViewRepresentable {
    var indicatorOpacity: CGFloat = 1

    func makeNSView(context: Context) -> ConfiguratorView {
        let view = ConfiguratorView()
        view.indicatorOpacity = indicatorOpacity
        return view
    }

    func updateNSView(_ nsView: ConfiguratorView, context: Context) {
        nsView.indicatorOpacity = indicatorOpacity
        nsView.configureScrollViews()
    }

    final class ConfiguratorView: NSView {
        var indicatorOpacity: CGFloat = 1
        private weak var configuredScrollView: NSScrollView?
        private var pendingConfiguration: DispatchWorkItem?
        private var preferenceObservers: [(NotificationCenter, NSObjectProtocol)] = []

        deinit {
            pendingConfiguration?.cancel()
            preferenceObservers.forEach { $0.0.removeObserver($0.1) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            configureScrollViews()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            configureScrollViews()
        }

        func configureScrollViews() {
            pendingConfiguration?.cancel()
            if preferenceObservers.isEmpty {
                for (center, name) in [
                    (NotificationCenter.default, NSScroller.preferredScrollerStyleDidChangeNotification),
                    (NSWorkspace.shared.notificationCenter, NSWorkspace.accessibilityDisplayOptionsDidChangeNotification)
                ] {
                    let observer = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                        MainActor.assumeIsolated {
                            self?.configuredScrollView = nil
                            self?.configureScrollViews()
                        }
                    }
                    preferenceObservers.append((center, observer))
                }
            }
            if let scrollView = enclosingScrollView {
                apply(to: scrollView)
            } else if window != nil {
                // SwiftUI attaches this bridge inside the scroll content. One
                // deferred attempt handles attachment without walking a window.
                let work = DispatchWorkItem { [weak self] in
                    guard let self, let scrollView = self.enclosingScrollView else { return }
                    self.apply(to: scrollView)
                }
                pendingConfiguration = work
                DispatchQueue.main.async(execute: work)
            }
        }

        private func apply(to scrollView: NSScrollView) {
            if configuredScrollView !== scrollView {
                configuredScrollView = scrollView
                scrollView.scrollerStyle = NSScroller.preferredScrollerStyle
                scrollView.autohidesScrollers = true
            }
            // Keep the system knob, geometry, fade and hit testing. Only the
            // sidebar requests lower emphasis; increased contrast takes priority.
            let opacity = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                ? 1 : min(max(indicatorOpacity, 0), 1)
            scrollView.verticalScroller?.alphaValue = opacity
            scrollView.horizontalScroller?.alphaValue = opacity
        }
    }
}
