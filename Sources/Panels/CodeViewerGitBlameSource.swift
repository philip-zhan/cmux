import Foundation

/// Loads per-line git blame for a file via `git blame --line-porcelain` and
/// parses it into `[GitBlameLine]` indexed by file order (element `i` describes
/// source line `i + 1`).
///
/// Returns `nil` when blame can't be sourced (file not tracked, not inside a
/// repo, git not installed, or an empty path). Mirrors the repo-root and
/// relative-path discovery used by `CodeViewerGitDiffSource`.
enum CodeViewerGitBlameSource {
    /// Loads blame off the cooperative pool — the file reads and `git` calls
    /// below are blocking and must not occupy a Swift-concurrency cooperative
    /// thread (see ``GitCommandRunner``).
    static func load(filePath: String) async -> [GitBlameLine]? {
        guard !filePath.isEmpty else { return nil }
        return await GitCommandRunner.offCooperativePool {
            loadSync(filePath: filePath)
        }
    }

    private static func loadSync(filePath: String) -> [GitBlameLine]? {
        let fileURL = URL(fileURLWithPath: filePath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        guard let repoRoot = repoRoot(for: fileURL) else { return nil }
        let relPath = relativePath(of: fileURL, from: repoRoot)
        guard !relPath.isEmpty else { return nil }
        guard let porcelain = try? runGit(
            ["-C", repoRoot.path, "blame", "--line-porcelain", "--", relPath]
        ) else { return nil }
        let lines = parse(porcelain: porcelain)
        return lines.isEmpty ? nil : lines
    }

    /// Parses `git blame --line-porcelain` output into one `GitBlameLine` per
    /// source line, in file order.
    ///
    /// `--line-porcelain` repeats the full header block for every line, so each
    /// block is self-contained: a `<sha> <orig> <final> [<count>]` header line,
    /// then `key value` metadata lines, then a single tab-prefixed content line
    /// that terminates the block. We only consume the metadata we display.
    static func parse(porcelain: String) -> [GitBlameLine] {
        var result: [GitBlameLine] = []
        var sha = ""
        var author = ""
        var authorTime = 0
        var summary = ""
        var inBlock = false

        for rawLine in porcelain.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(rawLine)
            if line.hasPrefix("\t") {
                // Content line terminates the current block; emit and reset.
                let uncommitted = isZeroSha(sha)
                let displayAuthor = uncommitted ? "You" : author
                result.append(
                    GitBlameLine(
                        shortHash: uncommitted ? "" : String(sha.prefix(8)),
                        author: displayAuthor,
                        timestamp: authorTime,
                        summary: uncommitted ? "" : summary,
                        isUncommitted: uncommitted
                    )
                )
                sha = ""
                author = ""
                authorTime = 0
                summary = ""
                inBlock = false
                continue
            }

            if !inBlock {
                // First line of a block is the SHA header. The SHA is the first
                // whitespace-delimited token.
                sha = String(line.prefix { $0 != " " })
                inBlock = true
                continue
            }

            if let value = headerValue(line, key: "author") {
                author = value
            } else if let value = headerValue(line, key: "author-time") {
                authorTime = Int(value) ?? 0
            } else if let value = headerValue(line, key: "summary") {
                summary = value
            }
        }
        return result
    }

    /// Returns the value of a `key value` porcelain header line, or `nil` if the
    /// line is a different key. Guards against prefix collisions (`author` vs
    /// `author-time`, `author-mail`, `author-tz`) by requiring an exact key match.
    private static func headerValue(_ line: String, key: String) -> String? {
        guard line.hasPrefix(key) else { return nil }
        let rest = line.dropFirst(key.count)
        guard rest.first == " " else { return nil }
        return String(rest.dropFirst())
    }

    private static func isZeroSha(_ sha: String) -> Bool {
        !sha.isEmpty && sha.allSatisfy { $0 == "0" }
    }

    // MARK: - Git plumbing

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

    @discardableResult
    private static func runGit(_ arguments: [String]) throws -> String {
        try GitCommandRunner.run(arguments)
    }
}
