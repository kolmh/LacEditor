import AppKit
import SwiftUI

struct TabBarView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var windowManager: WindowManager
    @State private var draggedDocumentID: UUID?
    @State private var tabFrames: [UUID: CGRect] = [:]
    @State private var tabContentFrame: CGRect = .zero
    @State private var tabViewportWidth: CGFloat = 0

    var body: some View {
        HStack(spacing: 0) {
            ScrollViewReader { proxy in
                GeometryReader { viewport in
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
                        .background {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: TabContentFramePreferenceKey.self,
                                    value: geometry.frame(in: .named("tabScrollViewport"))
                                )
                            }
                        }
                    }
                    .coordinateSpace(name: "tabScrollViewport")
                    .overlay(HorizontalWheelScrollBridge())
                    .overlay(alignment: .leading) {
                        if tabContentFrame.minX < -0.5 {
                            edgeFade(isLeading: true)
                        }
                    }
                    .overlay(alignment: .trailing) {
                        if tabContentFrame.maxX > tabViewportWidth + 0.5 {
                            edgeFade(isLeading: false)
                        }
                    }
                    .onAppear {
                        tabViewportWidth = viewport.size.width
                    }
                    .onChange(of: viewport.size.width) { _, width in
                        tabViewportWidth = width
                    }
                }
                .onChange(of: appState.selectedDocumentID) { _, selectedID in
                    guard let selectedID else { return }
                    withAnimation(.easeOut(duration: 0.16)) {
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
        .onPreferenceChange(TabContentFramePreferenceKey.self) { tabContentFrame = $0 }
        .frame(height: 36)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55))
    }

    private func edgeFade(isLeading: Bool) -> some View {
        LinearGradient(
            colors: [
                Color(nsColor: .controlBackgroundColor),
                Color(nsColor: .controlBackgroundColor).opacity(0)
            ],
            startPoint: isLeading ? .leading : .trailing,
            endPoint: isLeading ? .trailing : .leading
        )
        .frame(width: 18)
        .allowsHitTesting(false)
    }

    private func dragGesture(for document: EditorDocument) -> some Gesture {
        DragGesture(minimumDistance: 5, coordinateSpace: .named("tabBar"))
            .onChanged { value in
                if draggedDocumentID == nil {
                    draggedDocumentID = document.id
                }
                guard let targetID = tabFrames.first(where: {
                    $0.value.contains(value.location)
                })?.key, targetID != document.id else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    appState.moveDocument(document.id, relativeTo: targetID)
                }
            }
            .onEnded { _ in
                defer { draggedDocumentID = nil }
                guard let window = appState.hostWindow else { return }
                let mouseLocation = NSEvent.mouseLocation
                guard !window.frame.insetBy(dx: -8, dy: -8).contains(mouseLocation) else {
                    return
                }
                windowManager.detach(document, from: appState)
            }
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

private struct TabContentFramePreferenceKey: PreferenceKey {
    static var defaultValue = CGRect.zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        value = nextValue()
    }
}

private struct HorizontalWheelScrollBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> HorizontalWheelMonitorView {
        HorizontalWheelMonitorView()
    }

    func updateNSView(_ nsView: HorizontalWheelMonitorView, context: Context) {}
}

private final class HorizontalWheelMonitorView: NSView {
    private var eventMonitor: Any?

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
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window,
              event.window === window,
              bounds.contains(convert(event.locationInWindow, from: nil)),
              let scrollView = horizontalScrollView(
                  below: window.contentView,
                  at: event.locationInWindow
              ),
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
        return nil
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
