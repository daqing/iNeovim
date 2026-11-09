import AppKit
import WebKit

/// A standalone, read-only Markdown reading window. The Markdown renders to
/// HTML in a `WKWebView`, whose stylesheet keeps the reading column at a
/// comfortable width while code blocks preserve whitespace and scroll
/// horizontally — ASCII and box-drawing diagrams keep their layout.
@MainActor
final class MarkdownPreviewWindowController: NSWindowController, NSWindowDelegate, WKNavigationDelegate {
    private let webView: WKWebView
    private var markdown: String
    private var baseURL: URL?
    private var theme: MarkdownRenderer.Theme
    private let onOpenLink: (URL) -> Void
    private let onClose: () -> Void

    init(
        title: String,
        fileURL: URL?,
        markdown: String,
        baseURL: URL?,
        theme: MarkdownRenderer.Theme,
        onOpenLink: @escaping (URL) -> Void,
        onClose: @escaping () -> Void
    ) {
        self.markdown = markdown
        self.baseURL = baseURL
        self.theme = theme
        self.onOpenLink = onOpenLink
        self.onClose = onClose

        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView = webView

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 820),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        window.representedURL = fileURL
        window.minSize = NSSize(width: 420, height: 320)
        window.tabbingMode = .disallowed
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        super.init(window: window)

        window.delegate = self
        webView.navigationDelegate = self
        webView.autoresizingMask = [.width, .height]
        webView.frame = window.contentView?.bounds ?? .zero
        window.contentView = webView
        applyTheme()
        render()
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    /// Bring the window forward and give the page keyboard focus so the
    /// reader can scroll, select, and follow links immediately.
    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        window?.makeFirstResponder(webView)
    }

    /// Re-render in place when the same file is previewed again after edits.
    func update(
        markdown: String,
        baseURL: URL?,
        theme: MarkdownRenderer.Theme
    ) {
        self.markdown = markdown
        self.baseURL = baseURL
        self.theme = theme
        applyTheme()
        render()
    }

    private func applyTheme() {
        window?.appearance = NSAppearance(named: theme.isDark ? .darkAqua : .aqua)
        window?.backgroundColor = theme.background
        webView.underPageBackgroundColor = theme.background
    }

    private func render() {
        let html = MarkdownRenderer.document(
            body: MarkdownRenderer.body(markdown, baseURL: baseURL),
            theme: theme
        )
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    func windowWillClose(_ notification: Notification) {
        Task { @MainActor [onClose] in
            onClose()
        }
    }

    // MARK: - Links

    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.navigationType == .linkActivated,
              let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        // In-page anchors stay inside the preview.
        if url.scheme == "about" {
            decisionHandler(.allow)
            return
        }
        onOpenLink(url)
        decisionHandler(.cancel)
    }
}
