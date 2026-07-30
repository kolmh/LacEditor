import SwiftUI

struct StatusBarView: View {
    @ObservedObject var document: EditorDocument

    var body: some View {
        HStack(spacing: 0) {
            statusItem(
                document.isDirty ? "未保存" : "已保存",
                icon: document.isDirty ? "circle.fill" : "checkmark.circle.fill",
                color: document.isDirty ? .orange : .green
            )
            divider
            statusItem(document.encodingName)
            divider
            statusItem(document.language.rawValue)
            Spacer(minLength: 12)
            if let message = document.statusMessage {
                Text(message)
                    .font(.system(size: 11))
                    .foregroundStyle(message.hasPrefix("JSON 无效") ? .red : .secondary)
                    .lineLimit(1)
                    .help(message)
                divider
            }
            statusItem("字数：\(document.wordCount)")
            divider
            statusItem("行 \(document.cursorLine)，列 \(document.cursorColumn)")
        }
        .padding(.horizontal, 10)
        .frame(height: 25)
        .background(Color(nsColor: .windowBackgroundColor))
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
