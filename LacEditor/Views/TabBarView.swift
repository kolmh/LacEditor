import AppKit
import SwiftUI

struct TabBarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var windowManager: WindowManager
    @State private var draggedDocumentID: UUID?
    @State private var dragTargetDocumentID: UUID?
    @State private var dragTranslationX: CGFloat = 0
    @State private var tabFrames: [UUID: CGRect] = [:]
    @State private var dragStartFrames: [UUID: CGRect] = [:]
    @State private var canScrollLeading = false
    @State private var canScrollTrailing = false

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                GeometryReader { _ in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(appState.documents) { document in
                                EditorTabView(
                                    document: document,
                                    isSelected: appState.selectedDocumentID == document.id,
                                    isDragging: draggedDocumentID == document.id,
                                    select: { appState.selectedDocumentID = document.id },
                                    close: { appState.close(document) }
                                )
                                .id(document.id)
                                .offset(x: tabOffset(for: document.id))
                                .zIndex(draggedDocumentID == document.id ? 2 : 0)
                                .shadow(
                                    color: .black.opacity(draggedDocumentID == document.id ? 0.12 : 0),
                                    radius: 5,
                                    y: 2
                                )
                                .animation(
                                    .interactiveSpring(response: 0.2, dampingFraction: 0.86),
                                    value: dragTargetDocumentID
                                )
                                .transition(.asymmetric(
                                    insertion: .offset(x: 12).combined(with: .opacity),
                                    removal: .scale(scale: 0.96).combined(with: .opacity)
                                ))
                                .background {
                                    GeometryReader { geometry in
                                        Color.clear.preference(
                                            key: TabFramePreferenceKey.self,
                                            value: [
                                                document.id: geometry.frame(in: .named("tabBar"))
                                            ]
                                        )
                                    }
                                }
                                .simultaneousGesture(dragGesture(for: document))
                                .contextMenu {
                                    Button("关闭") { appState.close(document) }
                                    Button("关闭其他标签页") {
                                        appState.closeOtherDocuments(keeping: document)
                                    }
                                    Button("关闭右侧标签页") {
                                        appState.closeDocumentsToRight(of: document)
                                    }
                                }
                            }
                        }
                        .animation(
                            .smooth(duration: 0.24),
                            value: appState.documents.map(\.id)
                        )
                    }
                    .coordinateSpace(name: "tabScrollViewport")
                    .overlay(
                        HorizontalWheelScrollBridge(
                            canScrollLeading: $canScrollLeading,
                            canScrollTrailing: $canScrollTrailing
                        )
                    )
                    .overlay(alignment: .leading) {
                        if canScrollLeading {
                            edgeFade(isLeading: true)
                                .transition(.opacity)
                        }
                    }
                    .overlay(alignment: .trailing) {
                        if canScrollTrailing {
                            edgeFade(isLeading: false)
                                .transition(.opacity)
                        }
                    }
                    .animation(.easeOut(duration: 0.14), value: canScrollLeading)
                    .animation(.easeOut(duration: 0.14), value: canScrollTrailing)
                }
                .onChange(of: appState.selectedDocumentID) { _, selectedID in
                    guard let selectedID else { return }
                    withAnimation(.easeOut(duration: 0.1)) {
                        proxy.scrollTo(selectedID, anchor: .center)
                    }
                }
            }

            Divider()
                .frame(height: 20)

            Button {
                appState.newDocument()
            } label: {
                Image(systemName: "plus")
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .stableHelp("新建标签页", shortcut: "⌘T")
        }
        .coordinateSpace(name: "tabBar")
        .onPreferenceChange(TabFramePreferenceKey.self) { tabFrames = $0 }
        .frame(height: 36)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private func edgeFade(isLeading: Bool) -> some View {
        LinearGradient(
            colors: [
                Color(nsColor: .controlBackgroundColor).opacity(0.98),
                Color(nsColor: .controlBackgroundColor).opacity(0.78),
                Color(nsColor: .controlBackgroundColor).opacity(0.3),
                Color(nsColor: .controlBackgroundColor).opacity(0)
            ],
            startPoint: isLeading ? .leading : .trailing,
            endPoint: isLeading ? .trailing : .leading
        )
        .frame(width: 30)
        .allowsHitTesting(false)
    }

    private func dragGesture(for document: EditorDocument) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("tabBar"))
            .onChanged { value in
                if draggedDocumentID == nil {
                    draggedDocumentID = document.id
                    dragStartFrames = tabFrames
                    appState.selectedDocumentID = document.id
                }
                guard draggedDocumentID == document.id else { return }
                dragTranslationX = value.translation.width
                dragTargetDocumentID = nearestTab(to: value.location.x)
            }
            .onEnded { _ in
                let targetID = dragTargetDocumentID
                let shouldDetach: Bool
                if let window = appState.hostWindow {
                    shouldDetach = !window.frame
                        .insetBy(dx: -12, dy: -12)
                        .contains(NSEvent.mouseLocation)
                } else {
                    shouldDetach = false
                }

                if shouldDetach {
                    withAnimation(.easeOut(duration: 0.1)) {
                        clearDragState()
                    }
                    windowManager.detach(document, from: appState)
                } else if let targetID, targetID != document.id {
                    withAnimation(.smooth(duration: 0.18)) {
                        appState.moveDocument(document.id, relativeTo: targetID)
                        clearDragState()
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.1)) {
                        clearDragState()
                    }
                }
            }
    }

    private func nearestTab(to horizontalLocation: CGFloat) -> UUID? {
        let frames = dragStartFrames.isEmpty ? tabFrames : dragStartFrames
        return frames.min {
            abs($0.value.midX - horizontalLocation)
                < abs($1.value.midX - horizontalLocation)
        }?.key
    }

    private func clearDragState() {
        draggedDocumentID = nil
        dragTargetDocumentID = nil
        dragTranslationX = 0
        dragStartFrames = [:]
    }

    private func tabOffset(for documentID: UUID) -> CGFloat {
        guard let draggedDocumentID,
              let sourceIndex = appState.documents.firstIndex(where: {
                  $0.id == draggedDocumentID
              }),
              let targetID = dragTargetDocumentID,
              let targetIndex = appState.documents.firstIndex(where: {
                  $0.id == targetID
              }),
              let sourceWidth = (
                  dragStartFrames[draggedDocumentID]
                  ?? tabFrames[draggedDocumentID]
              )?.width
        else {
            return 0
        }

        if documentID == draggedDocumentID {
            return dragTranslationX
        }
        guard let index = appState.documents.firstIndex(where: {
            $0.id == documentID
        }) else {
            return 0
        }

        if sourceIndex < targetIndex,
           index > sourceIndex,
           index <= targetIndex {
            return -sourceWidth
        }
        if targetIndex < sourceIndex,
           index >= targetIndex,
           index < sourceIndex {
            return sourceWidth
        }
        return 0
    }
}

private struct EditorTabView: View {
    @ObservedObject var document: EditorDocument
    let isSelected: Bool
    let isDragging: Bool
    let select: () -> Void
    let close: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: document.language.icon)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)

            Text(document.displayName)
                .font(.system(size: 12))
                .lineLimit(1)

            if document.isDirty {
                Circle()
                    .fill(Color.secondary)
                    .frame(width: 6, height: 6)
                    .accessibilityLabel("未保存")
            }

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            .accessibilityHidden(!isHovering)
            .stableHelp("关闭标签页", shortcut: "⌘W")
        }
        .padding(.leading, 11)
        .padding(.trailing, 7)
        .frame(minWidth: 128, maxWidth: 178, minHeight: 36)
        .background {
            if isSelected {
                Color(nsColor: .lacEditorBackground)
            } else if isHovering {
                Color.primary.opacity(0.045)
            }
        }
        .overlay(alignment: .bottom) {
            if isSelected {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor))
                .frame(width: 1)
        }
        .contentShape(Rectangle())
        .opacity(isDragging ? 0.72 : 1)
        .animation(.easeInOut(duration: 0.16), value: isSelected)
        .animation(.easeInOut(duration: 0.12), value: isDragging)
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
    }
}

private struct TabFramePreferenceKey: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

private struct HorizontalWheelScrollBridge: NSViewRepresentable {
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

private final class HorizontalWheelMonitorView: NSView {
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
              event.window === window,
              bounds.contains(convert(event.locationInWindow, from: nil)),
              let scrollView = observedScrollView,
              let documentView = scrollView.documentView
        else {
            return event
        }

        let clipView = scrollView.contentView
        let maximumX = max(0, documentView.bounds.width - clipView.bounds.width)
        guard maximumX > 0.5 else { return event }

        let dominantDelta = abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY)
            ? event.scrollingDeltaX
            : event.scrollingDeltaY
        guard abs(dominantDelta) > 0.001 else { return nil }

        let multiplier: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 22
        let targetX = min(
            max(clipView.bounds.origin.x - dominantDelta * multiplier, 0),
            maximumX
        )
        guard abs(targetX - clipView.bounds.origin.x) > 0.01 else { return nil }

        clipView.scroll(to: NSPoint(x: targetX, y: clipView.bounds.origin.y))
        scrollView.reflectScrolledClipView(clipView)
        publishMetrics(for: scrollView)
        return nil
    }

    private func attachToScrollView() {
        guard let window else { return }
        let centerInWindow = convert(
            NSPoint(x: bounds.midX, y: bounds.midY),
            to: nil
        )
        guard let scrollView = horizontalScrollView(
            below: window.contentView,
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

    private func horizontalScrollView(below root: NSView?, at point: NSPoint) -> NSScrollView? {
        guard let root else { return nil }
        var candidates: [NSScrollView] = []
        collectScrollViews(in: root, point: point, result: &candidates)
        return candidates
            .filter {
                guard let documentView = $0.documentView else { return false }
                return documentView.bounds.width > $0.contentView.bounds.width + 0.5
            }
            .min { $0.frame.height < $1.frame.height }
    }

    private func collectScrollViews(
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
