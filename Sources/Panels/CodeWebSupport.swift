import AppKit
import WebKit

@MainActor
final class WeakCodeWebScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(_ target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

@MainActor
final class CodeWebView: WKWebView {
    static let defaultFontSize: CGFloat = 13
    static let minimumFontSize: CGFloat = 8
    static let maximumFontSize: CGFloat = 36

    var onPointerDown: (() -> Void)?
    var onFontSizeChanged: ((CGFloat) -> Void)?
    var onSaveChord: (() -> Void)?

    private(set) var currentFontSize: CGFloat = CodeWebView.defaultFontSize
    /// Set once the user manually zooms (keyboard, magnify, or scroll-wheel) so
    /// the chosen size sticks across SwiftUI rebuilds instead of snapping back to
    /// the `fontSize` prop on the next `updateNSView`.
    private var hasUserFontSizeOverride = false
    private var pendingSaveShortcutChordPrefix: ShortcutStroke?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    override func mouseDown(with event: NSEvent) {
        onPointerDown?()
        super.mouseDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown else {
            return super.performKeyEquivalent(with: event)
        }
        if let zoom = browserZoomShortcutAction(
            flags: event.modifierFlags,
            chars: event.charactersIgnoringModifiers ?? "",
            keyCode: event.keyCode,
            literalChars: event.characters
        ) {
            applyKeyboardZoom(zoom)
            return true
        }
        if let shouldSave = saveShortcutMatch(for: event) {
            if shouldSave { onSaveChord?() }
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// Applies a Cmd-`+`/`-`/`0` zoom command to the editor font size. Reuses the
    /// same `browserZoomShortcutAction` detector that drives the terminal and
    /// browser font zoom so the code editor honors the identical universal keys.
    private func applyKeyboardZoom(_ action: BrowserZoomShortcutAction) {
        switch action {
        case .zoomIn:
            adjustFontSize(by: FilePreviewInteraction.zoomStep)
        case .zoomOut:
            adjustFontSize(by: 1 / FilePreviewInteraction.zoomStep)
        case .reset:
            setFontSize(Self.defaultFontSize)
        }
    }

    private func saveShortcutMatch(for event: NSEvent) -> Bool? {
        let shortcut = KeyboardShortcutSettings.shortcut(for: .saveFilePreview)
        guard shortcut.hasChord else {
            pendingSaveShortcutChordPrefix = nil
            return shortcut.matches(event: event) ? true : nil
        }
        if let pendingPrefix = pendingSaveShortcutChordPrefix {
            pendingSaveShortcutChordPrefix = nil
            guard pendingPrefix == shortcut.firstStroke,
                  let secondStroke = shortcut.secondStroke else { return nil }
            return secondStroke.matches(event: event) ? true : nil
        }
        if shortcut.firstStroke.matches(event: event) {
            pendingSaveShortcutChordPrefix = shortcut.firstStroke
            return false
        }
        return nil
    }

    override func magnify(with event: NSEvent) {
        let factor = 1.0 + event.magnification
        guard factor.isFinite, factor > 0 else { return }
        adjustFontSize(by: factor)
    }

    override func scrollWheel(with event: NSEvent) {
        guard FilePreviewInteraction.hasZoomModifier(event) else {
            super.scrollWheel(with: event)
            return
        }
        adjustFontSize(by: FilePreviewInteraction.zoomFactor(forScroll: event))
    }

    override func smartMagnify(with event: NSEvent) {
        if currentFontSize == Self.defaultFontSize {
            setFontSize(18)
        } else {
            setFontSize(Self.defaultFontSize)
        }
    }

    /// Applies the base font size from the SwiftUI `fontSize` prop. Ignored once
    /// the user has manually zoomed this editor so their choice survives the
    /// `updateNSView` calls that fire on every panel state change (e.g. typing).
    func applyBaseFontSize(_ size: CGFloat) {
        guard !hasUserFontSizeOverride else { return }
        apply(fontSize: size)
    }

    /// Sets an explicit, user-chosen font size (clamped) and records that the
    /// user has overridden the base size for the rest of the panel's lifetime.
    func setFontSize(_ size: CGFloat) {
        hasUserFontSizeOverride = true
        apply(fontSize: size)
    }

    private func apply(fontSize size: CGFloat) {
        let clamped = min(max(size, Self.minimumFontSize), Self.maximumFontSize)
        guard clamped.isFinite, clamped != currentFontSize else { return }
        currentFontSize = clamped
        onFontSizeChanged?(clamped)
    }

    private func adjustFontSize(by factor: CGFloat) {
        setFontSize(currentFontSize * factor)
    }
}

/// Color palette the code viewer paints with. Keep this small and CSS-friendly;
/// the production theme work (Stage 5) will expand this with token colors.
struct CodeWebTheme: Equatable {
    let isDark: Bool
    let background: String
    let foreground: String
    let gutterBackground: String
    let gutterForeground: String
    let selectionBackground: String
    let activeLineBackground: String

    static func resolve(backgroundColor: NSColor, foregroundColor: NSColor) -> CodeWebTheme {
        let base = backgroundColor.codeOpaqueSRGB
        let isDark = !base.isLightColor
        let overlayColor: NSColor = isDark ? .white : .black

        let gutterBackground = base.codeThemeOverlay(
            targetContrast: isDark ? 1.04 : 1.03,
            of: overlayColor
        )
        let gutterForeground = foregroundColor.codeThemeOverlay(
            targetContrast: 1.8,
            of: base
        )
        let selection = base.codeThemeOverlay(
            targetContrast: isDark ? 1.4 : 1.25,
            of: NSColor(red: 0.20, green: 0.50, blue: 0.95, alpha: 1)
        )
        let activeLine = base.codeThemeOverlay(
            targetContrast: isDark ? 1.06 : 1.04,
            of: overlayColor
        )

        return CodeWebTheme(
            isDark: isDark,
            background: base.codeCSSColor,
            foreground: foregroundColor.codeCSSColor,
            gutterBackground: gutterBackground.codeCSSColor,
            gutterForeground: gutterForeground.codeCSSColor,
            selectionBackground: selection.withAlphaComponent(0.35).codeCSSColor,
            activeLineBackground: activeLine.codeCSSColor
        )
    }
}

/// Panel-owned renderer session — keeps the WebKit coordinator identity stable
/// across SwiftUI representable rebuilds, mirroring `MarkdownRendererSession`.
@MainActor
final class CodeRendererSession {
    private let ownedCoordinator = CodeWebRenderer.Coordinator()

    func coordinator(panelId: UUID, workspaceId: UUID, filePath: String) -> CodeWebRenderer.Coordinator {
        ownedCoordinator.bind(panelId: panelId, workspaceId: workspaceId, filePath: filePath)
        return ownedCoordinator
    }

    func close() {
        ownedCoordinator.close()
    }

    func currentDocument() async -> String? {
        await ownedCoordinator.currentDocument()
    }
}

extension NSColor {
    fileprivate var codeOpaqueSRGB: NSColor {
        (usingColorSpace(.sRGB) ?? self).withAlphaComponent(1)
    }

    fileprivate var codeCSSColor: String {
        let color = usingColorSpace(.sRGB) ?? self
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        color.getRed(&r, green: &g, blue: &b, alpha: &a)
        let ri = Int((max(0, min(1, r)) * 255).rounded())
        let gi = Int((max(0, min(1, g)) * 255).rounded())
        let bi = Int((max(0, min(1, b)) * 255).rounded())
        if a >= 0.999 {
            return String(format: "rgb(%d, %d, %d)", ri, gi, bi)
        }
        return String(format: "rgba(%d, %d, %d, %.3f)", ri, gi, bi, Double(a))
    }

    fileprivate func codeThemeOverlay(targetContrast: CGFloat, of overlay: NSColor) -> NSColor {
        // Simple blend toward the overlay color. The targetContrast value is
        // interpreted as a multiplier in the same way MarkdownWebTheme does it,
        // approximating WCAG contrast without paying the full computation.
        let factor = max(0.0, min(0.5, (targetContrast - 1.0)))
        guard let base = usingColorSpace(.sRGB),
              let over = overlay.usingColorSpace(.sRGB) else { return self }
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 1
        var or: CGFloat = 0, og: CGFloat = 0, ob: CGFloat = 0, oa: CGFloat = 1
        base.getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        over.getRed(&or, green: &og, blue: &ob, alpha: &oa)
        return NSColor(
            red: br + (or - br) * factor,
            green: bg + (og - bg) * factor,
            blue: bb + (ob - bb) * factor,
            alpha: ba
        )
    }

}
