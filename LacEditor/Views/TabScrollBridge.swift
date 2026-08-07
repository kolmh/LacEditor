import AppKit
import SwiftUI

struct HorizontalWheelScrollBridge: NSViewRepresentable {
    @Binding var canScrollLeading: Bool
    @Binding var canScrollTrailing: Bool

    func makeNSView(context: Context) -> HorizontalWheelMonitorView {
        let view = HorizontalWheelMonitorView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: HorizontalWheelMonitorView, context: Context) {
        configure(nsView)
        nsView.refreshMetrics()
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: HorizontalWheelMonitorView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width, let height = proposal.height else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    private func configure(_ view: HorizontalWheelMonitorView) {
        view.onMetricsChanged = { leading, trailing in
            if canScrollLeading != leading {
                canScrollLeading = leading
            }
            if canScrollTrailing != trailing {
                canScrollTrailing = trailing
            }
        }
    }
}

final class HorizontalWheelMonitorView: NSView {
    var onMetricsChanged: ((Bool, Bool) -> Void)?
    private var eventMonitor: Any?
    private var observerTokens: [NSObjectProtocol] = []
    private weak var observedScrollView: NSScrollView?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            self?.handle(event) ?? event
        }
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
        removeScrollObservers()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async { [weak self] in
            self?.attachToScrollView()
        }
    }

    override func layout() {
        super.layout()
        attachToScrollView()
    }

    func refreshMetrics() {
        DispatchQueue.main.async { [weak self] in
            self?.attachToScrollView()
            self?.publishMetrics()
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window,
              contains(event: event, in: window),
              let scrollView = observedScrollView
        else {
            return event
        }

        guard scrollView.scrollTabs(with: event) else { return event }
        publishMetrics(for: scrollView)
        return nil
    }

    private func contains(event: NSEvent, in window: NSWindow) -> Bool {
        let screenPoint: NSPoint
        if let eventWindow = event.window {
            screenPoint = eventWindow.convertPoint(toScreen: event.locationInWindow)
        } else {
            screenPoint = NSEvent.mouseLocation
        }
        let pointInWindow = window.convertPoint(fromScreen: screenPoint)
        return bounds.contains(convert(pointInWindow, from: nil))
    }

    private func attachToScrollView() {
        guard let window else { return }
        let centerInWindow = convert(
            NSPoint(x: bounds.midX, y: bounds.midY),
            to: nil
        )
        guard let scrollView = TabScrollViewLocator.find(
            in: window,
            at: centerInWindow
        ) else {
            publishMetrics(for: nil)
            return
        }
        guard observedScrollView !== scrollView else {
            publishMetrics(for: scrollView)
            return
        }

        removeScrollObservers()
        observedScrollView = scrollView
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.contentView.postsFrameChangedNotifications = true
        scrollView.documentView?.postsFrameChangedNotifications = true

        let center = NotificationCenter.default
        observerTokens.append(center.addObserver(
            forName: NSView.boundsDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.publishMetrics()
        })
        observerTokens.append(center.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: scrollView.contentView,
            queue: .main
        ) { [weak self] _ in
            self?.publishMetrics()
        })
        if let documentView = scrollView.documentView {
            observerTokens.append(center.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: documentView,
                queue: .main
            ) { [weak self] _ in
                self?.publishMetrics()
            })
        }
        publishMetrics(for: scrollView)
    }

    private func removeScrollObservers() {
        observerTokens.forEach(NotificationCenter.default.removeObserver)
        observerTokens.removeAll()
        observedScrollView = nil
    }

    private func publishMetrics() {
        publishMetrics(for: observedScrollView)
    }

    private func publishMetrics(for scrollView: NSScrollView?) {
        guard let scrollView, let documentView = scrollView.documentView else {
            onMetricsChanged?(false, false)
            return
        }
        let clipView = scrollView.contentView
        let maximumX = max(0, documentView.bounds.width - clipView.bounds.width)
        let currentX = min(max(clipView.bounds.origin.x, 0), maximumX)
        onMetricsChanged?(currentX > 0.5, currentX < maximumX - 0.5)
    }
}

enum TabScrollViewLocator {
    static func find(for event: NSEvent, in window: NSWindow?) -> NSScrollView? {
        guard let window else { return nil }
        let pointInWindow: NSPoint
        if let eventWindow = event.window {
            let screenPoint = eventWindow.convertPoint(toScreen: event.locationInWindow)
            pointInWindow = window.convertPoint(fromScreen: screenPoint)
        } else {
            pointInWindow = window.convertPoint(fromScreen: NSEvent.mouseLocation)
        }
        return find(in: window, at: pointInWindow)
    }

    static func find(in window: NSWindow, at point: NSPoint) -> NSScrollView? {
        guard let root = window.contentView else { return nil }
        return find(below: root, at: point)
    }

    private static func find(below root: NSView, at point: NSPoint) -> NSScrollView? {
        var candidates: [NSScrollView] = []
        collectScrollViews(in: root, point: point, result: &candidates)
        return candidates
            .filter { $0.documentView != nil }
            .min { $0.frame.height < $1.frame.height }
    }

    private static func collectScrollViews(
        in view: NSView,
        point: NSPoint,
        result: inout [NSScrollView]
    ) {
        if let scrollView = view as? NSScrollView {
            let frameInWindow = scrollView.convert(scrollView.bounds, to: nil)
            if frameInWindow.contains(point) {
                result.append(scrollView)
            }
        }
        view.subviews.forEach {
            collectScrollViews(in: $0, point: point, result: &result)
        }
    }
}

extension NSScrollView {
    func scrollTabs(with event: NSEvent) -> Bool {
        guard let documentView else { return false }
        let clipView = contentView
        let maximumX = max(0, documentView.bounds.width - clipView.bounds.width)
        guard maximumX > 0.5 else { return false }

        let dominantDelta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX
            : event.scrollingDeltaY
        guard abs(dominantDelta) > 0.001 else { return true }

        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 22
        let targetX = min(
            max(clipView.bounds.origin.x - dominantDelta * multiplier, 0),
            maximumX
        )
        guard abs(targetX - clipView.bounds.origin.x) > 0.01 else { return true }

        clipView.scroll(to: NSPoint(x: targetX, y: clipView.bounds.origin.y))
        reflectScrolledClipView(clipView)
        return true
    }
}
