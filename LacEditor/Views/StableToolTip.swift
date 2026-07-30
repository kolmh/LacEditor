import AppKit
import SwiftUI

extension View {
    func stableHelp(_ text: String, shortcut: String? = nil) -> some View {
        accessibilityHint(shortcut.map { "\(text)，快捷键 \($0)" } ?? text)
            .overlay(StableToolTipBridge(text: text, shortcut: shortcut))
    }
}

private struct StableToolTipBridge: NSViewRepresentable {
    let text: String
    let shortcut: String?

    func makeNSView(context: Context) -> ToolTipTrackingView {
        ToolTipTrackingView(text: text, shortcut: shortcut)
    }

    func updateNSView(_ nsView: ToolTipTrackingView, context: Context) {
        nsView.update(text: text, shortcut: shortcut)
    }
}

private final class ToolTipTrackingView: NSView {
    private var text: String
    private var shortcut: String?
    private var showWorkItem: DispatchWorkItem?
    private var toolTipPanel: ToolTipPanel?

    init(text: String, shortcut: String?) {
        self.text = text
        self.shortcut = shortcut
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) {
        nil
    }

    deinit {
        showWorkItem?.cancel()
        closePanel()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseEntered(with event: NSEvent) {
        schedulePanel()
    }

    override func mouseExited(with event: NSEvent) {
        cancelAndClose()
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            cancelAndClose()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func update(text: String, shortcut: String?) {
        guard self.text != text || self.shortcut != shortcut else { return }
        self.text = text
        self.shortcut = shortcut
        cancelAndClose()
    }

    private func schedulePanel() {
        showWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.showPanel()
        }
        showWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: workItem)
    }

    private func showPanel() {
        guard toolTipPanel == nil, let window else { return }
        let mouseLocation = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        guard bounds.contains(mouseLocation) else { return }

        let panel = ToolTipPanel(text: text, shortcut: shortcut)
        let targetRect = window.convertToScreen(convert(bounds, to: nil))
        var origin = NSPoint(
            x: targetRect.midX - panel.frame.width / 2,
            y: targetRect.minY - panel.frame.height - 7
        )

        if let visibleFrame = window.screen?.visibleFrame {
            origin.x = min(max(origin.x, visibleFrame.minX + 6), visibleFrame.maxX - panel.frame.width - 6)
            if origin.y < visibleFrame.minY + 6 {
                origin.y = targetRect.maxY + 7
            }
        }

        panel.setFrameOrigin(origin)
        window.addChildWindow(panel, ordered: .above)
        panel.orderFront(nil)
        toolTipPanel = panel
    }

    private func cancelAndClose() {
        showWorkItem?.cancel()
        showWorkItem = nil
        closePanel()
    }

    private func closePanel() {
        guard let panel = toolTipPanel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        toolTipPanel = nil
    }
}

private final class ToolTipPanel: NSPanel {
    init(text: String, shortcut: String?) {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: true
        )

        let effectView = NSVisualEffectView()
        effectView.material = .popover
        effectView.blendingMode = .behindWindow
        effectView.state = .active
        effectView.wantsLayer = true
        effectView.layer?.cornerRadius = 5
        effectView.layer?.borderWidth = 0.5
        effectView.layer?.borderColor = NSColor.separatorColor.cgColor

        let displayText = shortcut.map { "\(text)    \($0)" } ?? text
        let label = NSTextField(wrappingLabelWithString: displayText)
        label.font = .systemFont(ofSize: 12)
        label.textColor = .labelColor
        label.maximumNumberOfLines = 0
        label.preferredMaxLayoutWidth = 320
        label.translatesAutoresizingMaskIntoConstraints = false

        effectView.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: effectView.leadingAnchor, constant: 9),
            label.trailingAnchor.constraint(equalTo: effectView.trailingAnchor, constant: -9),
            label.topAnchor.constraint(equalTo: effectView.topAnchor, constant: 6),
            label.bottomAnchor.constraint(equalTo: effectView.bottomAnchor, constant: -6)
        ])

        contentView = effectView
        let fittingSize = effectView.fittingSize
        setContentSize(NSSize(
            width: min(max(fittingSize.width, 40), 338),
            height: max(fittingSize.height, 26)
        ))
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        level = .popUpMenu
        collectionBehavior = [.transient, .ignoresCycle]
    }
}
