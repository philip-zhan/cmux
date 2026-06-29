import Foundation

/// Loads the working-copy diff for a file by reading the file twice: HEAD
/// blob via `git show HEAD:<relpath>` and the working-tree content from
/// disk. Returns `nil` for either side when it can't be sourced (file not
/// in HEAD, file deleted, not inside a repo, git not installed).
enum CodeViewerGitDiffSource {
    struct Diff {
        let original: String
        let modified: String
    }

    /// Loads the diff off the cooperative pool — the file reads and `git` calls
    /// below are blocking and must not occupy a Swift-concurrency cooperative
    /// thread (see ``GitCommandRunner``).
    static func load(filePath: String) async -> Diff? {
        guard !filePath.isEmpty else { return nil }
        return await GitCommandRunner.offCooperativePool {
            loadSync(filePath: filePath)
        }
    }

    private static func loadSync(filePath: String) -> Diff? {
        let fileURL = URL(fileURLWithPath: filePath).standardizedFileURL
        let fileExists = FileManager.default.fileExists(atPath: fileURL.path)

        guard let repoRoot = repoRoot(for: fileURL) else { return nil }
        let relPath = relativePath(of: fileURL, from: repoRoot)
        guard !relPath.isEmpty else { return nil }

        let original = (try? gitShow(repoRoot: repoRoot, ref: "HEAD", path: relPath)) ?? ""
        let modified = fileExists ? ((try? String(contentsOf: fileURL, encoding: .utf8)) ?? "") : ""
        // A deleted file (no working copy) is still diffable as long as HEAD
        // had it; bail only when neither side has content to show.
        guard fileExists || !original.isEmpty else { return nil }
        return Diff(original: original, modified: modified)
    }

    private static func repoRoot(for fileURL: URL) -> URL? {
        let dir = fileURL.deletingLastPathComponent()
        let output = try? runGit(["-C", dir.path, "rev-parse", "--show-toplevel"])
        guard let trimmed = output?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true)
    }

    private static func relativePath(of file: URL, from root: URL) -> String {
        let f = file.standardizedFileURL.path
        let r = root.standardizedFileURL.path
        let rootPrefix = r.hasSuffix("/") ? r : r + "/"
        guard f.hasPrefix(rootPrefix) else { return "" }
        return String(f.dropFirst(rootPrefix.count))
    }

    private static func gitShow(repoRoot: URL, ref: String, path: String) throws -> String {
        try runGit(["-C", repoRoot.path, "show", "\(ref):\(path)"])
    }

    @discardableResult
    private static func runGit(_ arguments: [String]) throws -> String {
        try GitCommandRunner.run(arguments)
    }
}
