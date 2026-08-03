import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("通用设置")
                .font(.system(size: 20, weight: .semibold))
                .padding(.bottom, 18)

            Divider()

            Grid(alignment: .leading, horizontalSpacing: 24, verticalSpacing: 22) {
                GridRow {
                    settingLabel(
                        title: "外观",
                        detail: "选择界面主题，或跟随 macOS 系统设置。"
                    )
                    Picker("外观", selection: $appState.theme) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.rawValue).tag(theme)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 250)
                }

                GridRow {
                    settingLabel(
                        title: "性能",
                        detail: "超过 20 MB 或 25 万行时自动启用大文件模式；超过 50 MB 时使用更严格的保护模式。阈值暂不支持自定义。"
                    )
                    Label("自动管理", systemImage: "gauge.with.dots.needle.33percent")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                GridRow {
                    settingLabel(
                        title: "文本换行",
                        detail: "让长行保持在当前编辑区域内。"
                    )
                    Toggle("自动换行", isOn: $appState.isWordWrapEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                GridRow {
                    settingLabel(
                        title: "编辑器字体",
                        detail: "调整所有标签页的等宽字体大小。"
                    )
                    Stepper(
                        "\(Int(appState.editorFontSize)) pt",
                        value: $appState.editorFontSize,
                        in: 9...32
                    )
                    .fixedSize()
                }
            }
            .padding(.top, 22)

            Spacer(minLength: 24)
        }
        .padding(28)
        .frame(width: 540, height: 410)
    }

    private func settingLabel(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 205, alignment: .leading)
    }
}
