import SwiftUI

struct StatusBarView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject var document: EditorDocument

    var body: some View {
        HStack(spacing: 0) {
            if let ioStatus = document.ioState.statusText {
                statusItem(ioStatus, icon: "arrow.triangle.2.circlepath", color: .secondary)
            } else {
                statusItem(
                    document.isDirty ? "未保存" : "已保存",
                    icon: document.isDirty ? "circle.fill" : "checkmark.circle.fill",
                    color: document.isDirty ? .orange : .green
                )
            }
            divider
            statusItem(document.encodingName)
            divider
            statusItem(document.language.rawValue)
            if document.isLargeFileMode {
                divider
                performanceMenu
            }
            Spacer(minLength: 12)
            if let message = document.statusMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(message.hasPrefix("JSON 无效") ? .red : .secondary)
                    .lineLimit(1)
                    .help(message)
                divider
            }
            statusItem(
                document.isWordCountEnabled
                    ? "字数：\(document.wordCount)"
                    : "字数统计已暂停"
            )
            divider
            statusItem("行 \(document.cursorLine)，列 \(document.cursorColumn)")
        }
        .padding(.horizontal, 10)
        .frame(height: 25)
        .background(Color(nsColor: .lacEditorBackground))
    }

    private var performanceMenu: some View {
        Menu {
            Text(document.performanceProfile.displayName)
            Divider()
            featureButton(
                "自动换行",
                enabled: document.effectiveWordWrap(
                    globalDefault: appState.isWordWrapEnabled
                ),
                feature: .wordWrap
            )
            featureButton(
                "Markdown 预览",
                enabled: document.isPreviewEffectivelyEnabled,
                feature: .preview
            )
            .disabled(document.language != .markdown)
            featureButton(
                "语法高亮",
                enabled: document.isSyntaxHighlightingEnabled,
                feature: .syntaxHighlighting
            )
            featureButton(
                "代码折叠",
                enabled: document.isFoldingEnabled,
                feature: .folding
            )
            featureButton(
                "实时字数统计",
                enabled: document.isWordCountEnabled,
                feature: .wordCount
            )
            Divider()
            Text("这些设置仅对当前标签有效")
        } label: {
            Label("大文件模式", systemImage: "gauge.with.dots.needle.33percent")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 7)
        .help("查看大文件模式的性能保护选项")
    }

    private func featureButton(
        _ title: String,
        enabled: Bool,
        feature: DocumentManagedFeature
    ) -> some View {
        Button {
            appState.toggleLargeFileFeature(feature)
        } label: {
            Label(title, systemImage: enabled ? "checkmark" : "minus")
        }
    }

    private func statusItem(_ text: String, icon: String? = nil, color: Color = .secondary) -> some View {
        HStack(spacing: 5) {
            if let icon {
                Image(systemName: icon)
                    .font(.system(size: 8))
                    .foregroundStyle(color)
            }
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.horizontal, 7)
    }

    private var divider: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: 1, height: 12)
    }
}
