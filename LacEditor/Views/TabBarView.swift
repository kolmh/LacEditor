import AppKit
import SwiftUI

enum TabDropEdge {
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dropTargetPosition: TabDropPosition?
    @State private var canScrollLeading = false
    @State private var canScrollTrailing = false
    @State private var isAddButtonHovering = false
    private let barHeight = LacEditorDesign.tabBarHeight
    private let minimumEndDropZoneWidth: CGFloat = 64

    var body: some View {
        HStack(spacing: 2) {
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
                                    insertion: reduceMotion
                                        ? .opacity
                                        : .offset(x: 6).combined(with: .opacity),
                                    removal: .opacity
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
                            .frame(
                                width: endDropZoneWidth(
                                    in: geometry.size.width
                                ),
                                height: barHeight
                            )
                        }
                        .animation(
                            reduceMotion ? nil : .smooth(duration: 0.18),
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
                    .animation(reduceMotion ? nil : LacEditorDesign.hoverAnimation, value: canScrollLeading)
                    .animation(reduceMotion ? nil : LacEditorDesign.hoverAnimation, value: canScrollTrailing)
                }
                .onChange(of: appState.selectedDocumentID) { _, selectedID in
                    guard let selectedID else { return }
                    withAnimation(reduceMotion ? nil : LacEditorDesign.hoverAnimation) {
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
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(
                                Color.primary.opacity(
                                    isAddButtonHovering ? 0.075 : 0.028
                                )
                            )
                    }
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(isAddButtonHovering ? .primary : .secondary)
            .onHover { isAddButtonHovering = $0 }
            .stableHelp("新建标签页", shortcut: "⌘T")
            .padding(.trailing, 5)
        }
        .coordinateSpace(name: "tabBar")
        .frame(height: barHeight)
        .background(Color(nsColor: .controlBackgroundColor))
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.42))
                .frame(height: 0.5)
                .allowsHitTesting(false)
        }
    }

    private func tabWidth(in availableWidth: CGFloat) -> CGFloat {
        let count = CGFloat(max(1, appState.documents.count))
        let flexibleWidth = max(
            0,
            availableWidth - minimumEndDropZoneWidth
        ) / count
        return min(208, max(128, flexibleWidth))
    }

    private func endDropZoneWidth(in availableWidth: CGFloat) -> CGFloat {
        let tabsWidth = tabWidth(in: availableWidth)
            * CGFloat(appState.documents.count)
        return max(minimumEndDropZoneWidth, availableWidth - tabsWidth)
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
                Color(nsColor: .lacEditorBackground).opacity(0.98),
                Color(nsColor: .lacEditorBackground).opacity(0.8),
                Color(nsColor: .lacEditorBackground).opacity(0.32),
                Color(nsColor: .lacEditorBackground).opacity(0)
            ],
            startPoint: isLeading ? .leading : .trailing,
            endPoint: isLeading ? .trailing : .leading
        )
        .frame(width: LacEditorDesign.edgeFadeWidth)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: document.language.icon)
                .font(.system(size: 11))
                .foregroundStyle(
                    isSelected
                        ? Color(nsColor: .controlAccentColor)
                        : Color(nsColor: .secondaryLabelColor)
                )
                .frame(width: 14, height: 14)

            Text(document.displayName)
                .font(.system(size: 12, weight: isSelected ? .medium : .regular))
                .foregroundStyle(
                    isSelected
                        ? Color(nsColor: .labelColor)
                        : Color(nsColor: .secondaryLabelColor)
                )
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity)

            ZStack {
                Circle()
                    .fill(Color.accentColor.opacity(0.82))
                    .frame(width: 6, height: 6)
                    .opacity(document.isDirty && !isHovering ? 1 : 0)
                    .accessibilityLabel("未保存")
                    .accessibilityHidden(!document.isDirty)

                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .frame(width: 18, height: 18)
                        .background {
                            Circle()
                                .fill(Color.primary.opacity(0.06))
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
            .frame(width: 18, height: 18)
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .frame(
            maxWidth: .infinity,
            minHeight: LacEditorDesign.tabBarHeight,
            maxHeight: LacEditorDesign.tabBarHeight
        )
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: LacEditorDesign.compactCornerRadius, style: .continuous)
                    .fill(
                        colorScheme == .dark
                            ? Color.white.opacity(0.065)
                            : Color(nsColor: .controlBackgroundColor).opacity(0.74)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: LacEditorDesign.compactCornerRadius, style: .continuous)
                            .stroke(
                                Color(nsColor: .separatorColor).opacity(0.46),
                                lineWidth: 0.6
                            )
                    }
                    .padding(.horizontal, 2)
                    .padding(.vertical, 3)
            } else if isHovering {
                RoundedRectangle(cornerRadius: LacEditorDesign.compactCornerRadius, style: .continuous)
                    .fill(Color.primary.opacity(0.04))
                    .padding(.horizontal, 2)
                    .padding(.vertical, 3)
            }
        }
        .overlay(alignment: .trailing) {
            if showsTrailingSeparator, !isHovering {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.58))
                    .frame(width: 1, height: 14)
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
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isSelected)
        .animation(reduceMotion ? nil : LacEditorDesign.hoverAnimation, value: isHovering)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: isDragging)
        .animation(reduceMotion ? nil : LacEditorDesign.hoverAnimation, value: dropTargetEdge)
        .onTapGesture(perform: select)
        .onHover { isHovering = $0 }
    }
}
