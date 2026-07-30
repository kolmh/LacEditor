import SwiftUI

struct FindReplaceView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var state: FindReplaceState
    @FocusState private var focusedField: Field?

    private enum Field {
        case query
        case replacement
    }

    init(state: FindReplaceState) {
        _state = ObservedObject(wrappedValue: state)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("查找与替换")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                Picker("模式", selection: $state.mode) {
                    ForEach(FindReplaceMode.allCases) { mode in
                        Text(mode.rawValue).tag(mode)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 150)
            }

            Grid(alignment: .trailing, horizontalSpacing: 10, verticalSpacing: 10) {
                GridRow {
                    Text("查找")
                    TextField("输入要查找的内容", text: $state.query)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .query)
                        .onSubmit { appState.findNext() }
                }
                if state.mode == .replace {
                    GridRow {
                        Text("替换为")
                        TextField("输入替换内容", text: $state.replacement)
                            .textFieldStyle(.roundedBorder)
                            .focused($focusedField, equals: .replacement)
                    }
                }
            }

            HStack(spacing: 8) {
                Toggle("解释转义字符", isOn: $state.interpretsEscapes)
                Image(systemName: "questionmark.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .stableHelp(
                        #"可用转义字符：\n 换行，\r 回车，\t 制表符，\s 空格，\\ 反斜杠"#
                    )
                Spacer()
                Toggle("区分大小写", isOn: $state.isCaseSensitive)
            }
            .toggleStyle(.checkbox)

            HStack {
                if let message = state.message {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("关闭") {
                    appState.isFindReplacePresented = false
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    appState.findPrevious()
                } label: {
                    Label("上一个", systemImage: "chevron.up")
                }
                Button {
                    appState.findNext()
                } label: {
                    Label("下一个", systemImage: "chevron.down")
                }
                .keyboardShortcut(.defaultAction)

                if state.mode == .replace {
                    Button("替换") { appState.replaceCurrentMatch() }
                    Button("全部替换") { appState.replaceAllMatches() }
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: state.mode == .replace ? 260 : 220)
        .onAppear {
            focusedField = .query
        }
    }
}
