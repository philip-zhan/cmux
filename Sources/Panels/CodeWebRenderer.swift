import AppKit
import SwiftUI
import WebKit

/// Production WKWebView-backed code viewer wrapping the bundled CodeMirror 6
/// editor in `Resources/code-viewer/`. Modeled after `MarkdownWebRenderer`:
/// the panel owns a long-lived `CodeRendererSession`, this struct is the
/// SwiftUI representable shell, and the `Coordinator` carries the WebKit
/// state across representable rebuilds.
struct CodeWebRenderer: NSViewRepresentable {
    let content: String
    let languageId: String
    let theme: CodeWebTheme
    let fontSize: Int
    let isReadOnly: Bool
    let diffOriginal: String?
    let diffModified: String?
    /// Per-line git blame for the current-line inline annotation, or `nil` when
    /// unavailable. Sent out-of-band (not via the payload) so it never remounts
    /// the editor — see `Coordinator.applyBlame`.
    let blameLines: [GitBlameLine]?
    let backgroundColor: NSColor
    let panelId: UUID
    let workspaceId: UUID
    let filePath: String
    let session: CodeRendererSession
    let onRequestPanelFocus: () -> Void
    let onSaveRequested: () -> Void
    let onContentChanged: (String) -> Void
    let onFontSizeChanged: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        session.coordinator(panelId: panelId, workspaceId: workspaceId, filePath: filePath)
    }

    func makeNSView(context: Context) -> WKWebView {
        if let webView = context.coordinator.webView {
            if webView.superview != nil { webView.removeFromSuperview() }
            attachCallbacks(webView, coordinator: context.coordinator)
            applyBackground(to: webView)
            applyAppearance(to: webView, isDark: theme.isDark)
            return webView
        }

        let config = WKWebViewConfiguration()
        config.suppressesIncrementalRendering = false
        config.userContentController.add(
            WeakCodeWebScriptMessageHandler(context.coordinator),
            name: "cmuxCode"
        )

        let webView = CodeWebView(frame: .zero, configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false
        if #available(macOS 13.3, *) {
#if DEBUG
            webView.isInspectable = true
#else
            webView.isInspectable = false
#endif
        }
        attachCallbacks(webView, coordinator: context.coordinator)
        applyBackground(to: webView)
        applyAppearance(to: webView, isDark: theme.isDark)

        context.coordinator.webView = webView
        context.coordinator.blameLines = blameLines
        context.coordinator.loadShell(initialPayload: currentPayload())
        return webView
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        context.coordinator.bind(panelId: panelId, workspaceId: workspaceId, filePath: filePath)
        attachCallbacks(nsView, coordinator: context.coordinator)
        applyBackground(to: nsView)
        applyAppearance(to: nsView, isDark: theme.isDark)
        context.coordinator.update(payload: currentPayload())
        context.coordinator.updateBlame(blameLines)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        if let retained = coordinator.webView, retained === nsView { return }
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "cmuxCode")
        (nsView as? CodeWebView)?.onPointerDown = nil
    }

    private func attachCallbacks(_ webView: WKWebView, coordinator: Coordinator) {
        if let typed = webView as? CodeWebView {
            typed.onPointerDown = onRequestPanelFocus
            typed.onFontSizeChanged = { [weak coordinator] size in
                coordinator?.applyFontSize(Int(size.rounded()))
            }
            typed.onSaveChord = onSaveRequested
            if typed.currentFontSize != CGFloat(fontSize) {
                typed.setFontSize(CGFloat(fontSize))
            }
        }
        webView.navigationDelegate = coordinator
        webView.uiDelegate = coordinator
        coordinator.onSaveRequested = onSaveRequested
        coordinator.onContentChanged = onContentChanged
        coordinator.onFontSizeChanged = onFontSizeChanged
    }

    private func applyAppearance(to webView: WKWebView, isDark: Bool) {
        let appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
        if webView.appearance !== appearance {
            webView.appearance = appearance
        }
    }

    private func applyBackground(to webView: WKWebView) {
        webView.underPageBackgroundColor = backgroundColor
        webView.wantsLayer = true
        webView.layer?.backgroundColor = backgroundColor.cgColor
        webView.layer?.isOpaque = backgroundColor.alphaComponent >= 0.999
    }

    private func currentPayload() -> CodeWebRendererPayload {
        CodeWebRendererPayload(
            content: content,
            language: languageId,
            isDark: theme.isDark,
            fontSize: fontSize,
            readOnly: isReadOnly,
            diffOriginal: diffOriginal,
            diffModified: diffModified,
            theme: CodeWebRendererPayload.ThemePalette(
                background: theme.background,
                foreground: theme.foreground,
                gutterBackground: theme.gutterBackground,
                gutterForeground: theme.gutterForeground,
                selectionBackground: theme.selectionBackground,
                activeLineBackground: theme.activeLineBackground
            )
        )
    }

    // MARK: - Coordinator

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var webView: CodeWebView?
        var panelId: UUID = UUID()
        var workspaceId: UUID = UUID()
        var filePath: String = ""

        var onSaveRequested: () -> Void = {}
        var onContentChanged: (String) -> Void = { _ in }
        var onFontSizeChanged: (Int) -> Void = { _ in }

        /// Latest blame to display. Tracked outside the payload (like font size)
        /// so applying it never remounts the editor. Re-sent after every
        /// (re)load via the `didFinish` handler.
        var blameLines: [GitBlameLine]?
        private var isLoaded = false
        private var isShellLoading = false
        private var pendingPayload: CodeWebRendererPayload?
        private var lastPayload: CodeWebRendererPayload?
        private var webContentProcessRecoveryAttempts = 0
        private let maxWebContentProcessRecoveryAttempts = 2

        func bind(panelId: UUID, workspaceId: UUID, filePath: String) {
            self.panelId = panelId
            self.workspaceId = workspaceId
            self.filePath = filePath
        }

        func close() {
            if let webView {
                webView.stopLoading()
                webView.configuration.userContentController.removeScriptMessageHandler(forName: "cmuxCode")
                webView.navigationDelegate = nil
                webView.uiDelegate = nil
                webView.onPointerDown = nil
            }
            webView = nil
            isLoaded = false
            isShellLoading = false
            webContentProcessRecoveryAttempts = 0
        }

        func loadShell(initialPayload: CodeWebRendererPayload) {
            pendingPayload = initialPayload
            isLoaded = false
            isShellLoading = true
            let html = CodeViewerAssets.shared.shellHTML()
            // baseURL with an https scheme keeps the inline `<script type="module">`
            // happy under WebKit's tightened module-origin rules without needing
            // any actual network access.
            let baseURL = URL(string: "https://localhost/cmux-code-viewer/")
            webView?.loadHTMLString(html, baseURL: baseURL)
        }

        func update(payload: CodeWebRendererPayload) {
            pendingPayload = payload
            let payloadChanged = lastPayload != payload
            let shellNeedsReload = !isLoaded && !isShellLoading

            if payloadChanged {
                webContentProcessRecoveryAttempts = 0
                if isLoaded {
                    apply(payload: payload)
                } else if shellNeedsReload {
                    loadShell(initialPayload: payload)
                }
                lastPayload = payload
            } else if shellNeedsReload,
                      webContentProcessRecoveryAttempts < maxWebContentProcessRecoveryAttempts {
                loadShell(initialPayload: payload)
            }
        }

        func currentDocument() async -> String? {
            guard let webView, isLoaded else { return nil }
            do {
                return try await webView.evaluateJavaScript("window.__cmuxCodeGet && window.__cmuxCodeGet()") as? String
            } catch {
                return nil
            }
        }

        /// Stores `next` and pushes it to the editor when it differs from what
        /// was last sent. Cheap no-op when blame is unchanged across rebuilds.
        func updateBlame(_ next: [GitBlameLine]?) {
            guard next != blameLines else { return }
            blameLines = next
            applyBlame()
        }

        /// Sends the current blame to the JS editor via the dedicated bridge
        /// function. Safe to call before the shell loads — `didFinish` re-sends.
        private func applyBlame() {
            guard let webView, isLoaded else { return }
            let json: String
            if let blameLines,
               let data = try? JSONEncoder().encode(blameLines),
               let encoded = String(data: data, encoding: .utf8) {
                json = encoded
            } else {
                json = "null"
            }
            let js = "window.__cmuxCodeSetBlame && window.__cmuxCodeSetBlame(\(json));"
            webView.evaluateJavaScript(js, completionHandler: nil)
        }

        func applyFontSize(_ size: Int) {
            guard let webView, isLoaded else {
                onFontSizeChanged(size)
                return
            }
            let js = "window.__cmuxCodeSetFontSize && window.__cmuxCodeSetFontSize(\(size));"
            webView.evaluateJavaScript(js, completionHandler: nil)
            onFontSizeChanged(size)
        }

        private func apply(payload: CodeWebRendererPayload) {
            guard let webView else { return }
            guard let data = try? JSONEncoder().encode(payload),
                  let json = String(data: data, encoding: .utf8) else { return }
            let js = "window.__cmuxCodeApply && window.__cmuxCodeApply(\(json));"
            webView.evaluateJavaScript(js) { _, error in
#if DEBUG
                if let error {
                    NSLog("CodeWebRenderer: apply failed: \(error)")
                }
#endif
            }
        }

        // MARK: WKScriptMessageHandler

        func userContentController(
            _ userContentController: WKUserContentController,
            didReceive message: WKScriptMessage
        ) {
            guard message.name == "cmuxCode",
                  let body = message.body as? [String: Any],
                  let action = body["action"] as? String else { return }
            switch action {
            case "ready":
                isLoaded = true
                if let pending = pendingPayload {
                    apply(payload: pending)
                }
                applyBlame()
            case "contentChanged":
                let content = (body["content"] as? String) ?? ""
                onContentChanged(content)
            case "requestSave":
                onSaveRequested()
            default:
                break
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            isShellLoading = false
            isLoaded = true
            if let payload = pendingPayload {
                apply(payload: payload)
                lastPayload = payload
            }
            // The payload remounts a fresh editor; re-attach the current blame.
            applyBlame()
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleShellNavigationFailure(for: webView)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            handleShellNavigationFailure(for: webView)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            guard let current = self.webView, current === webView else { return }
#if DEBUG
            NSLog("CodeWebRenderer.webContentProcessDidTerminate")
#endif
            isShellLoading = false
            guard webContentProcessRecoveryAttempts < maxWebContentProcessRecoveryAttempts else {
                isLoaded = false
                return
            }
            webContentProcessRecoveryAttempts += 1
            if let payload = lastPayload ?? pendingPayload {
                loadShell(initialPayload: payload)
            }
        }

        private func handleShellNavigationFailure(for webView: WKWebView) {
            guard let current = self.webView, current === webView, isShellLoading else { return }
            isShellLoading = false
            isLoaded = false
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            // Route any user-initiated navigation away from the embedded
            // editor — clicks should not break the shell. External links go
            // through NSWorkspace; same-doc fragments stay inside.
            if navigationAction.navigationType == .linkActivated,
               let url = navigationAction.request.url {
                NSWorkspace.shared.open(url)
                decisionHandler(.cancel)
                return
            }
            decisionHandler(.allow)
        }
    }
}

/// Wire-format payload sent across the WKWebView bridge.
struct CodeWebRendererPayload: Codable, Equatable {
    struct ThemePalette: Codable, Equatable {
        let background: String
        let foreground: String
        let gutterBackground: String
        let gutterForeground: String
        let selectionBackground: String
        let activeLineBackground: String
    }

    let content: String
    let language: String
    let isDark: Bool
    let fontSize: Int
    let readOnly: Bool
    let diffOriginal: String?
    let diffModified: String?
    let theme: ThemePalette
}
