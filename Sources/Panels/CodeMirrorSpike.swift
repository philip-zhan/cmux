#if DEBUG
import AppKit
import SwiftUI
import UniformTypeIdentifiers

// Debug-menu harness that exercises the production CodeWebRenderer +
// CodeViewerLanguageDetector. Not wired into the file preview panel yet;
// that lands in Stage 6 when the kill-switch setting goes in.

enum CodeMirrorSpikeSample {
    static let swift = """
import Foundation

struct Greeting {
    let name: String

    func render() -> String {
        return "hello, \\(name)"
    }
}

let g = Greeting(name: "cmux")
print(g.render())
"""

    static let swiftModified = """
import Foundation

struct Greeting {
    let name: String
    let exclaim: Bool

    func render() -> String {
        let suffix = exclaim ? "!" : ""
        return "hello, \\(name)\\(suffix)"
    }
}

let g = Greeting(name: "cmux", exclaim: true)
print(g.render())
"""
}

final class CodeMirrorSpikeDebugWindowController: NSWindowController, NSWindowDelegate {
    static let shared = CodeMirrorSpikeDebugWindowController()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "CodeMirror 6 Spike"
        window.identifier = NSUserInterfaceItemIdentifier("cmux.codemirrorSpike")
        window.center()
        window.contentView = NSHostingView(rootView: CodeMirrorSpikeDebugView())
        super.init(window: window)
        window.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        sender.orderOut(nil)
        return false
    }
}

private struct CodeMirrorSpikeDebugView: View {
    @StateObject private var model = CodeMirrorSpikeModel()
    @State private var session = CodeRendererSession()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button("Open File…") { openFile() }

                Text(model.filePathDisplay)
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Spacer()

                Toggle("Read-only", isOn: $model.isReadOnly)
                Toggle("Diff", isOn: $model.diffEnabled)

                HStack {
                    Text("Font")
                    Slider(value: $model.fontSize, in: 9...22, step: 1).frame(width: 120)
                    Text("\(Int(model.fontSize))pt").monospacedDigit().frame(width: 36, alignment: .trailing)
                }
            }
            .padding(8)

            HStack(spacing: 8) {
                Text("Language:")
                Text(model.languageId).font(.caption.monospaced())
                Spacer()
                if model.isDirty {
                    Text("● modified")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
                Text("Last save signal: \(model.lastSaveSignal)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if !model.diffStatus.isEmpty {
                    Text(model.diffStatus)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)

            Divider()

            CodeWebRenderer(
                content: model.content,
                languageId: model.languageId,
                theme: model.theme,
                fontSize: Int(model.fontSize),
                isReadOnly: model.isReadOnly,
                diffOriginal: model.diffEnabled ? (model.diffOriginal ?? CodeMirrorSpikeSample.swift) : nil,
                diffModified: model.diffEnabled ? (model.diffModified ?? CodeMirrorSpikeSample.swiftModified) : nil,
                blameLines: nil,
                backgroundColor: model.backgroundColor,
                panelId: model.panelId,
                workspaceId: model.workspaceId,
                filePath: model.filePath,
                session: session,
                onRequestPanelFocus: {},
                onSaveRequested: { model.lastSaveSignal = ISO8601DateFormatter().string(from: Date()) },
                onContentChanged: { content in model.isDirty = content != model.onDiskContent },
                onFontSizeChanged: { size in model.fontSize = Double(size) }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color(nsColor: model.backgroundColor))
        }
    }

    private func openFile() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.begin { response in
            guard response == .OK, let url = panel.urls.first else { return }
            Task { @MainActor in
                model.loadFile(at: url)
            }
        }
    }
}

@MainActor
private final class CodeMirrorSpikeModel: ObservableObject {
    @Published var content: String = CodeMirrorSpikeSample.swift
    @Published var languageId: String = "swift"
    @Published var filePath: String = ""
    @Published var isReadOnly: Bool = false
    @Published var diffEnabled: Bool = false { didSet { reloadDiffIfNeeded() } }
    @Published var fontSize: Double = 13
    @Published var isDirty: Bool = false
    @Published var lastSaveSignal: String = "—"
    @Published var diffOriginal: String? = nil
    @Published var diffModified: String? = nil
    @Published var diffStatus: String = ""

    let panelId = UUID()
    let workspaceId = UUID()

    var onDiskContent: String = CodeMirrorSpikeSample.swift

    var filePathDisplay: String {
        filePath.isEmpty ? "(sample buffer)" : filePath
    }

    var backgroundColor: NSColor {
        GhosttyBackgroundTheme.currentColor()
    }

    var foregroundColor: NSColor {
        GhosttyApp.shared.defaultForegroundColor
    }

    var theme: CodeWebTheme {
        CodeWebTheme.resolve(backgroundColor: backgroundColor, foregroundColor: foregroundColor)
    }

    func loadFile(at url: URL) {
        let path = url.path
        let sample = try? FileHandle(forReadingFrom: url).read(upToCount: 256)
        let detected = CodeViewerLanguageDetector.languageId(forPath: path, sampleBytes: sample)
        let body = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        filePath = path
        languageId = detected
        content = body
        onDiskContent = body
        isDirty = false
        diffEnabled = false
        diffOriginal = nil
        diffModified = nil
        diffStatus = ""
    }

    private func reloadDiffIfNeeded() {
        guard diffEnabled, !filePath.isEmpty else {
            diffOriginal = nil
            diffModified = nil
            diffStatus = diffEnabled ? "Open a file first to view its diff against HEAD" : ""
            return
        }
        diffStatus = "Loading diff against HEAD…"
        let path = filePath
        Task { @MainActor in
            if let diff = await CodeViewerGitDiffSource.load(filePath: path) {
                diffOriginal = diff.original
                diffModified = diff.modified
                diffStatus = diff.original == diff.modified ? "No changes vs HEAD" : "Diff vs HEAD"
            } else {
                diffOriginal = nil
                diffModified = nil
                diffStatus = "Not tracked by git (or git unavailable)"
                diffEnabled = false
            }
        }
    }
}
#endif
