import AppKit
import SwiftUI

/// Side-by-side diff view for a `FilePreviewPanel` opened with
/// `diffAgainstHead`. Drives the same `CodeWebRenderer` as the editable code
/// editor, feeding it the HEAD and working-tree blobs so the bundled CodeMirror
/// `MergeView` renders the diff. The HEAD pane stays read-only; the
/// working-tree pane is editable and saves through the panel's shared
/// text-editing machinery.
struct FilePreviewDiffEditor<PanelModel>: View
where PanelModel: ObservableObject & CodeMirrorEditingPanel {
    @ObservedObject var panel: PanelModel
    let diffOriginal: String
    let diffModified: String
    let isVisibleInUI: Bool
    let themeBackgroundColor: NSColor
    let themeForegroundColor: NSColor
    let drawsBackground: Bool

    var body: some View {
        CodeWebRenderer(
            content: diffModified,
            languageId: CodeViewerLanguageDetector.languageId(forPath: panel.filePath),
            theme: theme,
            fontSize: 13,
            isReadOnly: false,
            diffOriginal: diffOriginal,
            diffModified: diffModified,
            blameLines: nil,
            backgroundColor: rendererBackgroundColor,
            panelId: panel.id,
            workspaceId: panel.workspaceId,
            filePath: panel.filePath,
            session: panel.codeRendererSession,
            onRequestPanelFocus: { panel.noteCodeEditorPointerFocus() },
            onSaveRequested: handleSaveRequested,
            onContentChanged: { panel.updateTextContent($0) },
            onFontSizeChanged: { _ in }
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: rendererBackgroundColor))
        .opacity(isVisibleInUI ? 1 : 0)
        .allowsHitTesting(isVisibleInUI)
        .accessibilityHidden(!isVisibleInUI)
    }

    private func handleSaveRequested() {
        // The save chord fires immediately, but the JS bridge debounces
        // `contentChanged` by 120ms. Pull the live working-tree document from
        // the merge editor before saving so we never persist a stale snapshot.
        let session = panel.codeRendererSession
        Task { @MainActor in
            if let latest = await session.currentDocument() {
                panel.updateTextContent(latest)
            }
            _ = panel.saveTextContent()
        }
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
}
