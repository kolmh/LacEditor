import AppKit
import os
import SwiftUI
import WebKit

private let markdownPerformanceLog = OSLog(
    subsystem: "com.laceditor.LacEditor",
    category: "MarkdownPerformance"
)

private final class MarkdownWebView: WKWebView {
    var reloadRenderedContent: (() -> Void)?

    override func reload() -> WKNavigation? {
        reloadRenderedContent?()
        return nil
    }

    override func reloadFromOrigin() -> WKNavigation? {
        reloadRenderedContent?()
        return nil
    }
}

struct MarkdownPreview: NSViewRepresentable {
    let markdown: String
    let darkMode: Bool
    @ObservedObject var document: EditorDocument

    func makeCoordinator() -> Coordinator {
        Coordinator(document: document)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = MarkdownWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = view
        context.coordinator.document = document
        view.reloadRenderedContent = { [weak view, weak coordinator = context.coordinator] in
            guard let view, let coordinator else { return }
            coordinator.reloadLastRenderedHTML(in: view)
        }
        context.coordinator.render(markdown: markdown, darkMode: darkMode, immediately: true)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.document = document
        context.coordinator.render(markdown: markdown, darkMode: darkMode)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        weak var document: EditorDocument?
        private var workItem: DispatchWorkItem?
        private var lastPayload = ""
        private var lastRenderedHTML = ""
        private var generation = 0
        private var pendingScrollRatio: CGFloat = 0
        private let renderQueue: OperationQueue = {
            let queue = OperationQueue()
            queue.name = "com.laceditor.markdown-rendering"
            queue.maxConcurrentOperationCount = 1
            queue.qualityOfService = .userInitiated
            return queue
        }()

        init(document: EditorDocument) {
            self.document = document
        }

        deinit {
            workItem?.cancel()
            renderQueue.cancelAllOperations()
        }

        func render(markdown: String, darkMode: Bool, immediately: Bool = false) {
            let payload = "\(darkMode)|\(markdown)"
            guard payload != lastPayload else { return }
            lastPayload = payload
            workItem?.cancel()
            generation += 1
            let requestedGeneration = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, requestedGeneration == generation else { return }
                beginRender(
                    markdown: markdown,
                    darkMode: darkMode,
                    generation: requestedGeneration
                )
            }
            workItem = work
            if immediately {
                work.perform()
            } else {
                let delay = document?.isLargeFileMode == true ? 0.5 : 0.18
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
            }
        }

        private func beginRender(
            markdown: String,
            darkMode: Bool,
            generation requestedGeneration: Int
        ) {
            guard let document else { return }
            let taskGeneration = document.taskCoordinator.begin(.preview)
            let operation = BlockOperation()
            operation.addExecutionBlock { [weak self, weak document, weak operation] in
                guard let self, let document, let operation, !operation.isCancelled else { return }
                let signpostID = OSSignpostID(log: markdownPerformanceLog)
                os_signpost(
                    .begin,
                    log: markdownPerformanceLog,
                    name: "MarkdownRender",
                    signpostID: signpostID
                )
                let html = MarkdownRenderer.render(markdown, darkMode: darkMode)
                os_signpost(
                    .end,
                    log: markdownPerformanceLog,
                    name: "MarkdownRender",
                    signpostID: signpostID
                )
                guard !operation.isCancelled,
                      document.taskCoordinator.isCurrent(taskGeneration, for: .preview) else { return }
                DispatchQueue.main.async { [weak self, weak document, weak operation] in
                    guard let self, let document, let operation,
                          !operation.isCancelled,
                          requestedGeneration == generation,
                          document.taskCoordinator.isCurrent(taskGeneration, for: .preview),
                          let webView else { return }
                    document.taskCoordinator.finish(.preview, generation: taskGeneration)
                    pendingScrollRatio = scrollRatio(in: webView)
                    lastRenderedHTML = html
                    webView.stopLoading()
                    webView.loadHTMLString(html, baseURL: nil)
                }
            }
            document.taskCoordinator.attach(
                operation,
                kind: .preview,
                generation: taskGeneration
            )
            renderQueue.addOperation(operation)
        }

        private func scrollRatio(in webView: WKWebView) -> CGFloat {
            guard let scrollView = findScrollView(in: webView) else { return 0 }
            let available = max(
                1,
                (scrollView.documentView?.bounds.height ?? scrollView.contentSize.height)
                    - scrollView.contentView.bounds.height
            )
            return min(1, max(0, scrollView.contentView.bounds.minY / available))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            let ratio = pendingScrollRatio
            DispatchQueue.main.async {
                guard let scrollView = self.findScrollView(in: webView) else { return }
                let available = max(
                    0,
                    (scrollView.documentView?.bounds.height ?? scrollView.contentSize.height)
                        - scrollView.contentView.bounds.height
                )
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: available * ratio))
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            reloadLastRenderedHTML(in: webView)
        }

        fileprivate func reloadLastRenderedHTML(in webView: WKWebView) {
            guard !lastRenderedHTML.isEmpty else { return }
            pendingScrollRatio = scrollRatio(in: webView)
            webView.stopLoading()
            webView.loadHTMLString(lastRenderedHTML, baseURL: nil)
        }

        private func findScrollView(in view: NSView) -> NSScrollView? {
            if let scrollView = view as? NSScrollView { return scrollView }
            for subview in view.subviews {
                if let scrollView = findScrollView(in: subview) { return scrollView }
            }
            return nil
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .reload {
                decisionHandler(.cancel)
                DispatchQueue.main.async { [weak self, weak webView] in
                    guard let self, let webView else { return }
                    self.reloadLastRenderedHTML(in: webView)
                }
            } else if navigationAction.navigationType == .linkActivated {
                if let url = navigationAction.request.url,
                   ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    NSWorkspace.shared.open(url)
                }
                decisionHandler(.cancel)
            } else {
                decisionHandler(.allow)
            }
        }
    }
}
