import Foundation

/// Which engine the file preview panel should use for code-like files.
///
/// Stage 6 of the code viewer rollout ships the flag and a Settings UI for
/// it; the actual `FilePreviewPanel` integration (routing into either the
/// existing `NSTextView` path or the new `CodeWebRenderer`) lands in a
/// follow-up PR so this branch stays a focused spike.
enum CodePreviewEngine: String, CaseIterable, Identifiable {
    /// Today's behavior — `NSTextView`-backed `FilePreviewTextEditor`.
    case nativeText = "nativeText"
    /// Bundled CodeMirror 6 in a `WKWebView` (`CodeWebRenderer`).
    case codeMirror = "codeMirror"
    /// Default-on for languages the detector recognizes, fall back to
    /// `nativeText` otherwise (or for very large files).
    case auto = "auto"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nativeText:
            return String(
                localized: "codePreview.engine.nativeText",
                defaultValue: "Native text editor"
            )
        case .codeMirror:
            return String(
                localized: "codePreview.engine.codeMirror",
                defaultValue: "CodeMirror (beta)"
            )
        case .auto:
            return String(
                localized: "codePreview.engine.auto",
                defaultValue: "Automatic"
            )
        }
    }
}

enum CodePreviewEngineSettings {
    static let engineKey = "codePreviewEngine"
    // Default to `.auto`: CodeMirror handles every text file the panel can
    // load (so search, syntax highlighting, etc. work everywhere), and only
    // very large files fall back to the lighter NSTextView engine.
    // Set `codePreviewEngine = nativeText` in defaults to revert globally.
    static let defaultEngine: CodePreviewEngine = .auto

    /// Largest file (in bytes) the `.auto` engine routes to CodeMirror.
    ///
    /// CodeMirror runs in a `WKWebView`, so very large files (minified
    /// bundles, big logs) are cheaper to render in the native `NSTextView`.
    /// Files above this size fall back to `FilePreviewTextEditor`. The text
    /// loader caps reads at `FilePreviewTextLoader.maximumLoadedTextBytes`
    /// (10 MB), so anything between this threshold and that cap still opens —
    /// just in the native engine.
    static let maximumCodeMirrorBytes: UInt64 = 2 * 1024 * 1024

    static func current(defaults: UserDefaults = .standard) -> CodePreviewEngine {
        guard let raw = defaults.string(forKey: engineKey),
              let engine = CodePreviewEngine(rawValue: raw) else {
            return defaultEngine
        }
        return engine
    }

    /// Returns `true` when the file preview panel should mount the CodeMirror
    /// (`WKWebView`) engine for the given file path instead of the native
    /// `NSTextView` editor.
    ///
    /// - Parameters:
    ///   - path: The on-disk path of the file being previewed.
    ///   - fileSize: The file's size in bytes, when already known by the
    ///     caller. When `nil`, the size is read from disk. The `.auto` engine
    ///     uses it to keep very large files on the native editor; if the size
    ///     cannot be determined the file is assumed small and routed to
    ///     CodeMirror.
    ///   - defaults: The defaults store holding the engine preference.
    static func shouldUseCodeMirror(
        forPath path: String,
        fileSize: UInt64? = nil,
        defaults: UserDefaults = .standard
    ) -> Bool {
        switch current(defaults: defaults) {
        case .nativeText:
            return false
        case .codeMirror:
            return true
        case .auto:
            let resolvedSize = fileSize ?? fileSizeInBytes(atPath: path)
            if let resolvedSize, resolvedSize > maximumCodeMirrorBytes {
                return false
            }
            return true
        }
    }

    /// Reads a file's size in bytes, returning `nil` when it cannot be
    /// determined (e.g. the file does not exist).
    private static func fileSizeInBytes(atPath path: String) -> UInt64? {
        let url = URL(fileURLWithPath: path)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size >= 0 else {
            return nil
        }
        return UInt64(size)
    }
}
