import AppKit
import SwiftUI

struct NativeTabDragHandle: NSViewRepresentable {
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

final class TabDragHandleView: NSView, NSDraggingSource {
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

        NSColor.lacEditorBackground.withAlphaComponent(0.98).setFill()
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

struct NativeTabDropZone: NSViewRepresentable {
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

final class TabDropZoneView: NSView {
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
