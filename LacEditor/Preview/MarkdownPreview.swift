import AppKit
import SwiftUI
import WebKit

struct MarkdownPreview: NSViewRepresentable {
    let markdown: String
    let darkMode: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = context.coordinator
        view.setValue(false, forKey: "drawsBackground")
        context.coordinator.webView = view
        context.coordinator.render(markdown: markdown, darkMode: darkMode, immediately: true)
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.render(markdown: markdown, darkMode: darkMode)
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        private var workItem: DispatchWorkItem?
        private var lastPayload = ""
        private var generation = 0

        func render(markdown: String, darkMode: Bool, immediately: Bool = false) {
            let payload = "\(darkMode)|\(markdown)"
            guard payload != lastPayload else { return }
            lastPayload = payload
            workItem?.cancel()
            generation += 1
            let requestedGeneration = generation
            let work = DispatchWorkItem { [weak self] in
                guard let self, requestedGeneration == generation else { return }
                webView?.stopLoading()
                webView?.loadHTMLString(
                    MarkdownRenderer.render(markdown, darkMode: darkMode),
                    baseURL: nil
                )
            }
            workItem = work
            if immediately {
                work.perform()
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
            }
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            if navigationAction.navigationType == .linkActivated {
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
