import AppKit
import SwiftUI

enum FindReplaceWindowIdentity {
    static let identifier = NSUserInterfaceItemIdentifier(
        "LacEditor.FindReplaceWindow"
    )
}

struct FindReplaceView: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var state: FindReplaceState
    @FocusState private var focusedField: Field?
    private let close: () -> Void
    private let modeChanged: (FindReplaceMode) -> Void

    private enum Field {
        case query
        case replacement
    }

    init(
        state: FindReplaceState,
        close: @escaping () -> Void,
        modeChanged: @escaping (FindReplaceMode) -> Void
    ) {
        _state = ObservedObject(wrappedValue: state)
        self.close = close
        self.modeChanged = modeChanged
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
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
                if state.isWorking {
                    ProgressView()
                        .controlSize(.small)
                    Button("取消") {
                        appState.cancelFindReplaceTask()
                    }
                }
                Button("关闭") {
                    close()
                }
                .keyboardShortcut(.cancelAction)
                Button {
                    appState.findPrevious()
                } label: {
                    Label("上一个", systemImage: "chevron.up")
                }
                .disabled(state.isWorking)
                Button {
                    appState.findNext()
                } label: {
                    Label("下一个", systemImage: "chevron.down")
                }
                .keyboardShortcut(.defaultAction)
                .disabled(state.isWorking)

                if state.mode == .replace {
                    Button("替换") { appState.replaceCurrentMatch() }
                        .disabled(state.isWorking)
                    Button("全部替换") { appState.replaceAllMatches() }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.isWorking)
                }
            }
        }
        .padding(20)
        .frame(width: 520, height: state.mode == .replace ? 260 : 220)
        .onAppear {
            focusQueryField()
        }
        .onChange(of: state.focusRequestID) {
            focusQueryField()
        }
        .onChange(of: state.mode) { _, mode in
            modeChanged(mode)
        }
        .onChange(of: state.query) {
            appState.cancelFindReplaceTask()
        }
        .onChange(of: state.replacement) {
            appState.cancelFindReplaceTask()
        }
        .onChange(of: state.isCaseSensitive) {
            appState.cancelFindReplaceTask()
        }
        .onChange(of: state.interpretsEscapes) {
            appState.cancelFindReplaceTask()
        }
    }

    private func focusQueryField() {
        DispatchQueue.main.async {
            focusedField = .query
        }
    }
}

@MainActor
final class FindReplaceWindowController: NSWindowController, NSWindowDelegate {
    private weak var state: FindReplaceState?
    private weak var appState: AppState?
    private var hasPositionedWindow = false

    init(appState: AppState) {
        let findWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 220),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        super.init(window: findWindow)
        state = appState.findReplace
        self.appState = appState

        findWindow.identifier = FindReplaceWindowIdentity.identifier
        findWindow.title = "查找与替换"
        findWindow.isReleasedWhenClosed = false
        findWindow.animationBehavior = .documentWindow
        findWindow.collectionBehavior.insert(.fullScreenAuxiliary)
        findWindow.delegate = self

        findWindow.contentViewController = NSHostingController(
            rootView: FindReplaceView(
                state: appState.findReplace,
                close: { [weak self] in
                    self?.window?.performClose(nil)
                },
                modeChanged: { [weak self] mode in
                    self?.resize(for: mode, animated: true)
                }
            )
            .environmentObject(appState)
        )
    }

    required init?(coder: NSCoder) {
        nil
    }

    func present(mode: FindReplaceMode, relativeTo parentWindow: NSWindow) {
        guard let findWindow = window else { return }

        resize(for: mode, animated: findWindow.isVisible)
        if !hasPositionedWindow {
            position(over: parentWindow)
            hasPositionedWindow = true
        }
        showWindow(nil)
        findWindow.makeKeyAndOrderFront(nil)
        state?.focusRequestID = UUID()
    }

    func dismiss() {
        appState?.cancelFindReplaceTask()
        state?.isWorking = false
        window?.orderOut(nil)
    }

    func windowWillClose(_ notification: Notification) {
        appState?.cancelFindReplaceTask()
    }

    private func resize(for mode: FindReplaceMode, animated: Bool) {
        guard let panel = window else { return }
        let contentSize = NSSize(
            width: 520,
            height: mode == .replace ? 260 : 220
        )
        let contentRect = NSRect(origin: .zero, size: contentSize)
        let targetSize = panel.frameRect(forContentRect: contentRect).size
        var frame = panel.frame
        let top = frame.maxY
        frame.size = targetSize
        frame.origin.y = top - targetSize.height
        panel.setFrame(frame, display: true, animate: animated)
    }

    private func position(over parentWindow: NSWindow) {
        guard let panel = window else { return }
        var origin = NSPoint(
            x: parentWindow.frame.midX - panel.frame.width / 2,
            y: parentWindow.frame.midY - panel.frame.height / 2
        )
        if let visibleFrame = parentWindow.screen?.visibleFrame {
            origin.x = min(
                max(origin.x, visibleFrame.minX),
                visibleFrame.maxX - panel.frame.width
            )
            origin.y = min(
                max(origin.y, visibleFrame.minY),
                visibleFrame.maxY - panel.frame.height
            )
        }
        panel.setFrameOrigin(origin)
    }
}
