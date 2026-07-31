import AppKit
import SwiftUI

private enum TabDropEdge {
    case leading
    case trailing
}

private struct TabDropPosition: Equatable {
    let documentID: UUID
    let edge: TabDropEdge
}

struct TabBarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var windowManager: WindowManager
    @State private var dropTargetPosition: TabDropPosition?
    @State private var canScrollLeading = false
    @State private var canScrollTrailing = false
    @State private var isAddButtonHovering = false
    private let barHeight: CGFloat = 32
    private let endDropZoneWidth: CGFloat = 18

    var body: some View {
        HStack(spacing: 4) {
            ScrollViewReader { proxy in
                GeometryReader { geometry in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 0) {
                            ForEach(appState.documents) { document in
                                EditorTabView(
                                    document: document,
                                    isSelected: appState.selectedDocumentID == document.id,
                                    isDragging: windowManager.draggedDocumentID == document.id,
                                    dropTargetEdge: dropTargetPosition?.documentID == document.id
                                        && windowManager.draggedDocumentID != document.id
                                        ? dropTargetPosition?.edge
                                        : nil,
                                    select: { appState.selectedDocumentID = document.id },
                                    close: { appState.close(document) },
                                    beginDrag: {
                                        windowManager.beginTabDrag(
                                            document,
                                            from: appState
                                        )
                                    },
                                    finishDrag: { screenPoint in
                                        dropTargetPosition = nil
                                        windowManager.finishTabDrag(at: screenPoint)
                                    },
                                    dropTargetChanged: { edge in
                                        dropTargetPosition = TabDropPosition(
                                            documentID: document.id,
                                            edge: edge
                                        )
                                        windowManager.setTabDragTarget(
                                            in: appState,
                                            before: insertionTarget(
                                                for: document,
                                                edge: edge
                                            )
                                        )
                                    },
                                    dropExited: { edge in
                                        let position = TabDropPosition(
                                            documentID: document.id,
                                            edge: edge
                                        )
                                        if dropTargetPosition == position {
                                            dropTargetPosition = nil
                                        }
                                        windowManager.clearTabDragTarget(
                                            in: appState,
                                            before: insertionTarget(
                                                for: document,
                                                edge: edge
                                            )
                                        )
                                    },
                                    acceptDrop: { edge in
                                        dropTargetPosition = nil
                                        return windowManager.acceptTabDrag(
                                            into: appState,
                                            before: insertionTarget(
                                                for: document,
                                                edge: edge
                                            )
                                        )
                                    },
                                    showsTrailingSeparator: showsTrailingSeparator(
                                        after: document
                                    )
                                )
                                .frame(
                                    width: tabWidth(in: geometry.size.width),
                                    height: barHeight
                                )
                                .id(document.id)
                                .transition(.asymmetric(
                                    insertion: .offset(x: 8).combined(with: .opacity),
                                    removal: .scale(scale: 0.98).combined(with: .opacity)
                                ))
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

                            NativeTabDropZone(
                                canAcceptDrop: {
                                    windowManager.draggedDocumentID != nil
                                },
                                dropEntered: {
                                    if let lastDocument = appState.documents.last {
                                        dropTargetPosition = TabDropPosition(
                                            documentID: lastDocument.id,
                                            edge: .trailing
                                        )
                                    }
                                    windowManager.setTabDragTarget(
                                        in: appState,
                                        before: nil
                                    )
                                },
                                dropExited: {
                                    if dropTargetPosition?.documentID
                                        == appState.documents.last?.id,
                                       dropTargetPosition?.edge == .trailing {
                                        dropTargetPosition = nil
                                    }
                                    windowManager.clearTabDragTarget(
                                        in: appState,
                                        before: nil
                                    )
                                },
                                acceptDrop: {
                                    dropTargetPosition = nil
                                    return windowManager.acceptTabDrag(
                                        into: appState,
                                        before: nil
                                    )
                                }
                            )
                            .frame(width: endDropZoneWidth, height: barHeight)
                        }
                        .animation(
                            .smooth(duration: 0.2),
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

            Button {
                appState.newDocument()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .medium))
                    .frame(width: 26, height: 26)
                    .background {
                        Circle()
                            .fill(
                                Color.primary.opacity(
                                    isAddButtonHovering ? 0.09 : 0.035
                                )
                            )
                    }
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isAddButtonHovering ? .primary : .secondary)
            .onHover { isAddButtonHovering = $0 }
            .stableHelp("新建标签页", shortcut: "⌘T")
            .padding(.trailing, 5)
        }
        .coordinateSpace(name: "tabBar")
        .frame(height: barHeight)
        .background(.ultraThinMaterial)
    }

    private func tabWidth(in availableWidth: CGFloat) -> CGFloat {
        let count = CGFloat(max(1, appState.documents.count))
        let flexibleWidth = max(0, availableWidth - endDropZoneWidth) / count
        return min(220, max(132, flexibleWidth))
    }

    private func showsTrailingSeparator(after document: EditorDocument) -> Bool {
        guard let index = appState.documents.firstIndex(where: {
            $0.id == document.id
        }) else {
            return false
        }
        let nextIndex = appState.documents.index(after: index)
        guard appState.documents.indices.contains(nextIndex) else {
            return false
        }
        let selectedID = appState.selectedDocumentID
        return document.id != selectedID
            && appState.documents[nextIndex].id != selectedID
    }

    private func insertionTarget(
        for document: EditorDocument,
        edge: TabDropEdge
    ) -> UUID? {
        guard edge == .trailing,
              let index = appState.documents.firstIndex(where: {
                  $0.id == document.id
              }) else {
            return document.id
        }
        let nextIndex = appState.documents.index(after: index)
        return appState.documents.indices.contains(nextIndex)
            ? appState.documents[nextIndex].id
            : nil
    }

    private func edgeFade(isLeading: Bool) -> some View {
        LinearGradient(
            colors: [
                Color(nsColor: .windowBackgroundColor).opacity(0.98),
                Color(nsColor: .windowBackgroundColor).opacity(0.8),
                Color(nsColor: .windowBackgroundColor).opacity(0.32),
                Color(nsColor: .windowBackgroundColor).opacity(0)
            ],
            startPoint: isLeading ? .leading : .trailing,
            endPoint: isLeading ? .trailing : .leading
        )
        .frame(width: 30)
        .allowsHitTesting(false)
    }
}

private struct EditorTabView: View {
    @ObservedObject var document: EditorDocument
    let isSelected: Bool
    let isDragging: Bool
    let dropTargetEdge: TabDropEdge?
    let select: () -> Void
    let close: () -> Void
    let beginDrag: () -> Void
    let finishDrag: (NSPoint) -> Void
    let dropTargetChanged: (TabDropEdge) -> Void
    let dropExited: (TabDropEdge) -> Void
    let acceptDrop: (TabDropEdge) -> Bool
    let showsTrailingSeparator: Bool
    @Environment(\.colorScheme) private var colorScheme
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: document.language.icon)
                .font(.system(size: 11))
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                .frame(width: 14, height: 14)

            Text(document.displayName)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.82))
                    .frame(width: 6, height: 6)
                    .opacity(document.isDirty ? 1 : 0)
                    .accessibilityLabel("未保存")
                    .accessibilityHidden(!document.isDirty)
            }
            .frame(width: 8, height: 18)

            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .background {
                        Circle()
                            .fill(Color.primary.opacity(isHovering ? 0.06 : 0))
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .opacity(isHovering ? 1 : 0)
            .allowsHitTesting(isHovering)
            .accessibilityHidden(!isHovering)
            .stableHelp("关闭标签页", shortcut: "⌘W")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(maxWidth: .infinity, minHeight: 32, maxHeight: 32)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(
                        colorScheme == .dark
                            ? Color.white.opacity(0.075)
                            : Color(nsColor: .controlBackgroundColor).opacity(0.92)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(
                                Color(nsColor: .separatorColor).opacity(0.62),
                                lineWidth: 0.65
                            )
                    }
                    .shadow(
                        color: Color.black.opacity(
                            colorScheme == .dark ? 0.16 : 0.06
                        ),
                        radius: 1.5,
                        y: 0.5
                    )
                    .padding(.horizontal, 2)
                    .padding(.vertical, 3)
            } else if isHovering {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
                    .padding(.horizontal, 2)
                    .padding(.vertical, 3)
            }
        }
        .overlay(alignment: .trailing) {
            if showsTrailingSeparator, !isHovering {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.58))
                    .frame(width: 1, height: 16)
            }
        }
        .overlay(alignment: .leading) {
            if dropTargetEdge == .leading {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: 26)
                    .transition(.opacity)
            }
        }
        .overlay(alignment: .trailing) {
            if dropTargetEdge == .trailing {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2, height: 26)
                    .transition(.opacity)
            }
        }
        .overlay {
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    NativeTabDragHandle(
                        documentID: document.id,
                        title: document.displayName,
                        iconName: document.language.icon,
                        isDirty: document.isDirty,
                        select: select,
                        beginDrag: beginDrag,
                        finishDrag: finishDrag,
                        canAcceptDrop: { !isDragging },
                        dropTargetChanged: dropTargetChanged,
                        dropExited: dropExited,
                        acceptDrop: acceptDrop
                    )
                    .frame(width: max(0, geometry.size.width - 31))

                    Spacer(minLength: 0)
                }
            }
        }
        .contentShape(Rectangle())
        .opacity(isDragging ? 0.48 : 1)
        .scaleEffect(isDragging ? 0.98 : 1)
        .animation(.easeInOut(duration: 0.14), value: isSelected)
        .animation(.easeOut(duration: 0.1), value: isHovering)
        .animation(.easeOut(duration: 0.12), value: isDragging)
        .animation(.easeOut(duration: 0.1), value: dropTargetEdge)
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
    }
}

private struct NativeTabDragHandle: NSViewRepresentable {
    let documentID: UUID
    let title: String
    let iconName: String
    let isDirty: Bool
    let select: () -> Void
    let beginDrag: () -> Void
    let finishDrag: (NSPoint) -> Void
    let canAcceptDrop: () -> Bool
    let dropTargetChanged: (TabDropEdge) -> Void
    let dropExited: (TabDropEdge) -> Void
    let acceptDrop: (TabDropEdge) -> Bool

    func makeNSView(context: Context) -> TabDragHandleView {
        let view = TabDragHandleView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: TabDragHandleView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: TabDragHandleView) {
        view.documentID = documentID
        view.title = title
        view.iconName = iconName
        view.isDirty = isDirty
        view.onSelect = select
        view.onDragBegan = beginDrag
        view.onDragEnded = finishDrag
        view.canAcceptDrop = canAcceptDrop
        view.onDropTargetChanged = dropTargetChanged
        view.onDropExited = dropExited
        view.onAcceptDrop = acceptDrop
    }
}

private final class TabDragHandleView: NSView, NSDraggingSource {
    var documentID = UUID()
    var title = ""
    var iconName = "doc.plaintext"
    var isDirty = false
    var onSelect: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: ((NSPoint) -> Void)?
    var canAcceptDrop: (() -> Bool)?
    var onDropTargetChanged: ((TabDropEdge) -> Void)?
    var onDropExited: ((TabDropEdge) -> Void)?
    var onAcceptDrop: ((TabDropEdge) -> Bool)?

    private var mouseDownLocation: NSPoint?
    private var hasStartedDragging = false
    private var activeDropEdge: TabDropEdge?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setAccessibilityElement(false)
        registerForDraggedTypes([WindowManager.tabPasteboardType])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if NSApp.currentEvent?.type == .rightMouseDown {
            return nil
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownLocation = convert(event.locationInWindow, from: nil)
        hasStartedDragging = false
        onSelect?()
    }

    override func mouseDragged(with event: NSEvent) {
        guard !hasStartedDragging, let mouseDownLocation else { return }
        let current = convert(event.locationInWindow, from: nil)
        guard hypot(
            current.x - mouseDownLocation.x,
            current.y - mouseDownLocation.y
        ) >= 4 else {
            return
        }

        hasStartedDragging = true
        onDragBegan?()
        NSCursor.closedHand.set()

        let item = NSPasteboardItem()
        item.setString(
            documentID.uuidString,
            forType: WindowManager.tabPasteboardType
        )
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = dragImage()
        draggingItem.setDraggingFrame(
            NSRect(origin: .zero, size: image.size),
            contents: image
        )
        let session = beginDraggingSession(
            with: [draggingItem],
            event: event,
            source: self
        )
        session.animatesToStartingPositionsOnCancelOrFail = false
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownLocation = nil
        if !hasStartedDragging {
            NSCursor.arrow.set()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        let scrollView = enclosingScrollView
            ?? TabScrollViewLocator.find(for: event, in: window)
        if scrollView?.scrollTabs(with: event) == true {
            return
        }
        super.scrollWheel(with: event)
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        .move
    }

    func ignoreModifierKeys(
        for session: NSDraggingSession
    ) -> Bool {
        true
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        mouseDownLocation = nil
        hasStartedDragging = false
        NSCursor.arrow.set()
        onDragEnded?(screenPoint)
    }

    override func draggingEntered(
        _ sender: any NSDraggingInfo
    ) -> NSDragOperation {
        guard accepts(sender) else { return [] }
        updateDropTarget(for: sender)
        return .move
    }

    override func draggingUpdated(
        _ sender: any NSDraggingInfo
    ) -> NSDragOperation {
        guard accepts(sender) else { return [] }
        updateDropTarget(for: sender)
        return .move
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        clearDropTarget()
    }

    override func performDragOperation(
        _ sender: any NSDraggingInfo
    ) -> Bool {
        guard accepts(sender) else { return false }
        let edge = activeDropEdge ?? dropEdge(for: sender)
        activeDropEdge = nil
        return onAcceptDrop?(edge) ?? false
    }

    private func updateDropTarget(for sender: any NSDraggingInfo) {
        let edge = dropEdge(for: sender)
        guard edge != activeDropEdge else { return }
        if let previousEdge = activeDropEdge {
            onDropExited?(previousEdge)
        }
        activeDropEdge = edge
        onDropTargetChanged?(edge)
    }

    private func clearDropTarget() {
        guard let edge = activeDropEdge else { return }
        activeDropEdge = nil
        onDropExited?(edge)
    }

    private func dropEdge(for sender: any NSDraggingInfo) -> TabDropEdge {
        let point = convert(sender.draggingLocation, from: nil)
        return point.x < bounds.midX ? .leading : .trailing
    }

    private func accepts(_ sender: any NSDraggingInfo) -> Bool {
        canAcceptDrop?() == true
            && sender.draggingPasteboard.availableType(
                from: [WindowManager.tabPasteboardType]
            ) != nil
    }

    private func dragImage() -> NSImage {
        let size = NSSize(width: max(132, bounds.width + 31), height: 32)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let rect = NSRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.16)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = NSSize(width: 0, height: -1)
        shadow.set()

        NSColor.windowBackgroundColor.withAlphaComponent(0.98).setFill()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
        NSGraphicsContext.current?.saveGraphicsState()
        NSShadow().set()
        NSColor.separatorColor.setStroke()
        NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).stroke()

        if let icon = NSImage(
            systemSymbolName: iconName,
            accessibilityDescription: nil
        ) {
            icon.draw(
                in: NSRect(x: 12, y: 9, width: 14, height: 14),
                from: .zero,
                operation: .sourceOver,
                fraction: 0.78
            )
        }

        let titleRect = NSRect(
            x: 33,
            y: 7,
            width: max(20, size.width - (isDirty ? 58 : 43)),
            height: 17
        )
        (title as NSString).draw(
            with: titleRect,
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
        )
        if isDirty {
            NSColor.secondaryLabelColor.setFill()
            NSBezierPath(
                ovalIn: NSRect(x: size.width - 17, y: 13, width: 6, height: 6)
            ).fill()
        }
        NSGraphicsContext.current?.restoreGraphicsState()
        return image
    }
}

private struct NativeTabDropZone: NSViewRepresentable {
    let canAcceptDrop: () -> Bool
    let dropEntered: () -> Void
    let dropExited: () -> Void
    let acceptDrop: () -> Bool

    func makeNSView(context: Context) -> TabDropZoneView {
        let view = TabDropZoneView()
        configure(view)
        return view
    }

    func updateNSView(_ nsView: TabDropZoneView, context: Context) {
        configure(nsView)
    }

    private func configure(_ view: TabDropZoneView) {
        view.canAcceptDrop = canAcceptDrop
        view.onDropEntered = dropEntered
        view.onDropExited = dropExited
        view.onAcceptDrop = acceptDrop
    }
}

private final class TabDropZoneView: NSView {
    var canAcceptDrop: (() -> Bool)?
    var onDropEntered: (() -> Void)?
    var onDropExited: (() -> Void)?
    var onAcceptDrop: (() -> Bool)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([WindowManager.tabPasteboardType])
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func scrollWheel(with event: NSEvent) {
        let scrollView = enclosingScrollView
            ?? TabScrollViewLocator.find(for: event, in: window)
        if scrollView?.scrollTabs(with: event) == true {
            return
        }
        super.scrollWheel(with: event)
    }

    override func draggingEntered(
        _ sender: any NSDraggingInfo
    ) -> NSDragOperation {
        guard accepts(sender) else { return [] }
        onDropEntered?()
        return .move
    }

    override func draggingUpdated(
        _ sender: any NSDraggingInfo
    ) -> NSDragOperation {
        accepts(sender) ? .move : []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        onDropExited?()
    }

    override func performDragOperation(
        _ sender: any NSDraggingInfo
    ) -> Bool {
        guard accepts(sender) else { return false }
        onDropExited?()
        return onAcceptDrop?() ?? false
    }

    private func accepts(_ sender: any NSDraggingInfo) -> Bool {
        canAcceptDrop?() == true
            && sender.draggingPasteboard.availableType(
                from: [WindowManager.tabPasteboardType]
            ) != nil
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

private enum TabScrollViewLocator {
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

private extension NSScrollView {
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
