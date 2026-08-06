import AppKit
import SwiftUI

enum TextTransformationWindowIdentity {
    static let identifier = NSUserInterfaceItemIdentifier(
        "LacEditor.TextTransformationWindow"
    )
}

struct TextTransformationPreview: Equatable {
    let documentID: UUID
    let range: NSRange
    let input: String
    let output: String
    let editorRevision: UInt
    let operation: TextTransformationOperation
    let detectedKind: TextCodecKind?

    var title: String { operation.title }
}

@MainActor
final class TextTransformationPreviewState: ObservableObject {
    @Published private(set) var preview: TextTransformationPreview?
    @Published var message: String?
    @Published private(set) var canReplace = false

    func present(_ preview: TextTransformationPreview) {
        self.preview = preview
        message = nil
        canReplace = preview.input != preview.output
    }

    func invalidate(documentID: UUID) {
        guard preview?.documentID == documentID else { return }
        canReplace = false
        message = "编辑内容已变化，请重新执行转换"
    }

    func clear() {
        preview = nil
        message = nil
        canReplace = false
    }
}

struct TextTransformationView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var state: TextTransformationPreviewState
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let preview = state.preview {
                HStack {
                    Label(preview.title, systemImage: "arrow.left.arrow.right")
                        .font(.system(size: 13, weight: .semibold))
                    Spacer()
                    Text("仅在确认后修改正文")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                HSplitView {
                    previewPane(title: "原文", text: preview.input)
                        .frame(minWidth: 240)
                    previewPane(title: "结果", text: preview.output)
                        .frame(minWidth: 240)
                }

                HStack {
                    if let message = state.message {
                        Text(message)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button("关闭", action: close)
                        .keyboardShortcut(.cancelAction)
                    Button("复制结果") {
                        appState.copyTextTransformationResult()
                    }
                    Button("替换原文") {
                        appState.applyTextTransformationPreview()
                    }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!state.canReplace)
                }
            } else {
                ContentUnavailableView(
                    "没有转换结果",
                    systemImage: "text.badge.xmark"
                )
            }
        }
        .padding(18)
        .frame(minWidth: 600, minHeight: 420)
    }

    private func previewPane(title: String, text: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\((text as NSString).length) 字符")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            ScrollView(.vertical) {
                Text(previewText(text))
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(9)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            }
        }
    }

    private func previewText(_ text: String) -> String {
        let limit = 20_000
        guard text.count > limit else { return text }
        return String(text.prefix(limit))
            + "\n\n…预览已截断，替换仍会使用完整结果"
    }
}

@MainActor
final class TextTransformationWindowController: NSWindowController, NSWindowDelegate {
    private weak var state: TextTransformationPreviewState?

    init(appState: AppState) {
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: panel)
        state = appState.textTransformation
        panel.title = "编码与解码"
        panel.identifier = TextTransformationWindowIdentity.identifier
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .documentWindow
        panel.collectionBehavior.insert(.fullScreenAuxiliary)
        panel.minSize = NSSize(width: 600, height: 420)
        panel.delegate = self
        panel.contentViewController = NSHostingController(
            rootView: TextTransformationView(
                state: appState.textTransformation,
                close: { [weak panel] in panel?.performClose(nil) }
            )
            .environmentObject(appState)
        )
    }

    required init?(coder: NSCoder) { nil }

    func present(relativeTo parentWindow: NSWindow) {
        guard let panel = window else { return }
        if !panel.isVisible {
            position(panel, over: parentWindow)
        }
        showWindow(nil)
        panel.makeKeyAndOrderFront(nil)
    }

    func dismiss() {
        window?.orderOut(nil)
        state?.clear()
    }

    func dispose() {
        window?.delegate = nil
        window?.contentViewController = nil
        window?.close()
        state?.clear()
        state = nil
    }

    func windowWillClose(_ notification: Notification) {
        state?.clear()
    }

    private func position(_ panel: NSWindow, over parent: NSWindow) {
        var origin = NSPoint(
            x: parent.frame.midX - panel.frame.width / 2,
            y: parent.frame.midY - panel.frame.height / 2
        )
        if let visible = parent.screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX), visible.maxX - panel.frame.width)
            origin.y = min(max(origin.y, visible.minY), visible.maxY - panel.frame.height)
        }
        panel.setFrameOrigin(origin)
    }
}
