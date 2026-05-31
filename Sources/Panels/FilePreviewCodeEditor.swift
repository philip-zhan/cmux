import AppKit
import SwiftUI
import WebKit

/// A panel that can host the CodeMirror text engine via `FilePreviewCodeEditor`.
///
/// Refines `FilePreviewTextEditingPanel` with the extra hooks the WKWebView
/// editor needs: the on-disk content snapshot that drives the renderer's
/// `content:` prop, the panel-owned `CodeRendererSession`, panel identity, and
/// the focus-registration shims. Both `FilePreviewPanel` and `MarkdownPanel`
/// conform so the same CodeMirror editor backs the file preview and the
/// dedicated markdown viewer's TextEdit mode.
@MainActor
protocol CodeMirrorEditingPanel: AnyObject, FilePreviewTextEditingPanel {
    var id: UUID { get }
    var workspaceId: UUID { get }
    var filePath: String { get }
    /// On-disk snapshot of the file text. Drives the renderer's `content:`
    /// prop so per-keystroke edits don't churn the WebKit payload.
    var codeEditorBaseContent: String { get }
    var codeRendererSession: CodeRendererSession { get }
    /// Per-line git blame driving the current-line inline annotation, or `nil`
    /// when blame is unavailable or not applicable (e.g. the markdown viewer).
    var blameLines: [GitBlameLine]? { get }
    func noteCodeEditorPointerFocus()
    func attachCodeEditorFocus(view: NSView)
}

extension CodeMirrorEditingPanel {
    /// Default: no blame. Panels that source git blame (e.g. `FilePreviewPanel`)
    /// override this with a stored property.
    var blameLines: [GitBlameLine]? { nil }
}

/// SwiftUI wrapper that drives `CodeWebRenderer` from a `CodeMirrorEditingPanel`.
///
/// When `CodePreviewEngineSettings` routes a text-mode panel to CodeMirror,
/// `FilePreviewPanelView` mounts this view instead of `FilePreviewTextEditor`;
/// `MarkdownPanelView` mounts it for its TextEdit mode. The on-disk snapshot
/// (`panel.codeEditorBaseContent`) drives the renderer's `content:` prop so
/// per-keystroke edits don't churn the WebKit payload; the live in-memory
/// buffer lives in the JS editor and is reported back through
/// `onContentChanged`.
struct FilePreviewCodeEditor<PanelModel>: View
where PanelModel: ObservableObject & CodeMirrorEditingPanel {
    @ObservedObject var panel: PanelModel
    let isVisibleInUI: Bool
    let themeBackgroundColor: NSColor
    let themeForegroundColor: NSColor
    let drawsBackground: Bool

    var body: some View {
        CodeWebRenderer(
            content: panel.codeEditorBaseContent,
            languageId: detectedLanguageId,
            theme: theme,
            fontSize: defaultFontSize,
            isReadOnly: false,
            diffOriginal: nil,
            diffModified: nil,
            blameLines: panel.blameLines,
            backgroundColor: rendererBackgroundColor,
            panelId: panel.id,
            workspaceId: panel.workspaceId,
            filePath: panel.filePath,
            session: panel.codeRendererSession,
            onRequestPanelFocus: handlePointerFocus,
            onSaveRequested: handleSaveRequested,
            onContentChanged: handleContentChanged,
            onFontSizeChanged: { _ in }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: rendererBackgroundColor))
        .opacity(isVisibleInUI ? 1 : 0)
        .allowsHitTesting(isVisibleInUI)
        .accessibilityHidden(!isVisibleInUI)
        .background(
            FilePreviewCodeEditorFocusBridge(panel: panel)
                .allowsHitTesting(false)
        )
    }

    private var detectedLanguageId: String {
        CodeViewerLanguageDetector.languageId(forPath: panel.filePath)
    }

    private var rendererBackgroundColor: NSColor {
        drawsBackground ? themeBackgroundColor : .clear
    }

    private var theme: CodeWebTheme {
        CodeWebTheme.resolve(
            backgroundColor: themeBackgroundColor,
            foregroundColor: themeForegroundColor
        )
    }

    private var defaultFontSize: Int { 13 }

    private func handlePointerFocus() {
        // Pointer-down inside the web view should treat the panel the same way
        // a click on the NSTextView does: announce focus intent so the panel
        // framework can route navigation.
        panel.noteCodeEditorPointerFocus()
    }

    private func handleContentChanged(_ next: String) {
        panel.updateTextContent(next)
    }

    private func handleSaveRequested() {
        // The Swift-side save chord fires immediately when the user presses
        // the configured shortcut, but the JS bridge debounces
        // `contentChanged` by 120ms. Pull the live document from the editor
        // before saving so we never persist a stale snapshot.
        let session = panel.codeRendererSession
        Task { @MainActor in
            if let latest = await session.currentDocument() {
                panel.updateTextContent(latest)
            }
            _ = panel.saveTextContent()
        }
    }
}

/// AppKit shim that registers the WKWebView underneath `FilePreviewCodeEditor`
/// with the panel so `panel.focus()` routes into the embedded editor the same
/// way it does for the NSTextView engine.
private struct FilePreviewCodeEditorFocusBridge: NSViewRepresentable {
    let panel: any CodeMirrorEditingPanel

    func makeNSView(context: Context) -> FilePreviewCodeEditorFocusBridgeView {
        let view = FilePreviewCodeEditorFocusBridgeView()
        view.panel = panel
        return view
    }

    func updateNSView(_ nsView: FilePreviewCodeEditorFocusBridgeView, context: Context) {
        nsView.panel = panel
        nsView.registerIfNeeded()
    }
}

private final class FilePreviewCodeEditorFocusBridgeView: NSView {
    weak var panel: (any CodeMirrorEditingPanel)?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerIfNeeded()
    }

    func registerIfNeeded() {
        guard let panel else { return }
        guard let webView = findCodeWebView() else { return }
        panel.attachCodeEditorFocus(view: webView)
    }

    /// Walks the sibling tree to find the CodeWebView (it's mounted by the
    /// neighboring `CodeWebRenderer` representable, not as a subview of this
    /// bridge view). We start from the immediate superview and recurse.
    private func findCodeWebView() -> CodeWebView? {
        guard let superview = superview else { return nil }
        return Self.search(in: superview)
    }

    private static func search(in view: NSView) -> CodeWebView? {
        if let codeWebView = view as? CodeWebView {
            return codeWebView
        }
        for subview in view.subviews {
            if let found = search(in: subview) {
                return found
            }
        }
        return nil
    }
}
