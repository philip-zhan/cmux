import Foundation
import SwiftUI

/// Classification of a single changed path reported by `git status`.
enum SourceControlChangeKind: String, Sendable {
    case modified
    case added
    case deleted
    case renamed
    case copied
    case untracked
    case typeChanged
    case conflicted

    var badgeLetter: String {
        switch self {
        case .modified: return "M"
        case .added: return "A"
        case .deleted: return "D"
        case .renamed: return "R"
        case .copied: return "C"
        case .untracked: return "U"
        case .typeChanged: return "T"
        case .conflicted: return "!"
        }
    }
}

/// Immutable value snapshot of one changed file. Safe to hand to `ForEach`
/// rows without violating the snapshot-boundary policy.
struct SourceControlChange: Identifiable, Equatable, Sendable {
    /// Stable identity: staged flag + path keeps staged and unstaged variants
    /// of the same file distinct.
    let id: String
    let relativePath: String
    let absolutePath: String
    let displayName: String
    /// Directory portion relative to the repo root, shown dimmed in the row.
    let directoryPath: String
    let kind: SourceControlChangeKind
    let isStaged: Bool
    /// Original path for renames/copies, relative to the repo root.
    let originalPath: String?
}

/// Drives the Source Control sidebar tab. Runs `git status` for the active
/// workspace directory, classifies changed files, and exposes them as value
/// snapshots. Git invocations run off the main actor; published mutations land
/// back on the main actor.
@MainActor
final class SourceControlStore: ObservableObject {
    @Published private(set) var stagedChanges: [SourceControlChange] = []
    @Published private(set) var unstagedChanges: [SourceControlChange] = []
    @Published private(set) var untrackedChanges: [SourceControlChange] = []
    @Published private(set) var branchName: String?
    @Published private(set) var isRepository = false
    @Published private(set) var isLoading = false
    /// True once at least one refresh has finished, so the panel can tell
    /// "loading" apart from "loaded, no changes".
    @Published private(set) var hasLoadedOnce = false

    private(set) var directory: String?
    private var repoRoot: String?
    private var workingTreeWatcher: RecursiveFileSystemWatcher?
    private var refreshGeneration = 0
    /// True while a `git status` invocation is in flight. Used to coalesce
    /// overlapping refresh requests so only one status runs at a time.
    private var isRefreshing = false
    /// Set when a refresh is requested while one is already running. The
    /// in-flight refresh runs exactly one more pass when it finishes. This is
    /// what breaks the "`git status` rewrites `.git/index` → file event →
    /// refresh → …" loop: the follow-up pass finds the index already current,
    /// so it writes nothing and no further event fires.
    private var refreshQueued = false

    var hasChanges: Bool {
        !stagedChanges.isEmpty || !unstagedChanges.isEmpty || !untrackedChanges.isEmpty
    }

    var totalChangeCount: Int {
        stagedChanges.count + unstagedChanges.count + untrackedChanges.count
    }

    // MARK: - Directory binding

    func setDirectory(_ directory: String?) {
        let normalized = directory?.isEmpty == true ? nil : directory
        guard normalized != self.directory else { return }
        self.directory = normalized
        repoRoot = nil
        stopWatching()
        if normalized == nil {
            isRepository = false
            hasLoadedOnce = false
            clearChanges()
        } else {
            hasLoadedOnce = false
            refresh()
        }
    }

    // MARK: - Refresh

    func refresh() {
        guard let directory else {
            clearChanges()
            return
        }
        // Coalesce: if a status is already running, request exactly one more
        // pass when it completes instead of launching a concurrent invocation.
        if isRefreshing {
            refreshQueued = true
            return
        }
        isRefreshing = true
        refreshGeneration += 1
        let generation = refreshGeneration
        isLoading = true

        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                SourceControlGit.status(directory: directory)
            }.value
            guard let self else { return }
            self.isRefreshing = false
            if self.refreshGeneration == generation {
                self.apply(result)
            }
            if self.refreshQueued {
                self.refreshQueued = false
                self.refresh()
            }
        }
    }

    private func apply(_ result: SourceControlGit.StatusResult) {
        isLoading = false
        hasLoadedOnce = true
        isRepository = result.isRepository
        branchName = result.branchName

        guard result.isRepository, let root = result.repoRoot else {
            repoRoot = nil
            stopWatching()
            clearChanges()
            return
        }

        let rootChanged = repoRoot != root
        repoRoot = root

        stagedChanges = result.changes.filter { $0.isStaged }
        unstagedChanges = result.changes.filter { !$0.isStaged && $0.kind != .untracked }
        untrackedChanges = result.changes.filter { !$0.isStaged && $0.kind == .untracked }

        if rootChanged || workingTreeWatcher == nil {
            startWatching(repoRoot: root)
        }
    }

    private func clearChanges() {
        stagedChanges = []
        unstagedChanges = []
        untrackedChanges = []
        branchName = nil
    }

    // MARK: - Discard

    /// Discards working-tree changes for a single file. Untracked files are
    /// removed from disk; tracked files are restored from the index/HEAD.
    func discard(_ change: SourceControlChange) {
        guard let root = repoRoot else { return }
        let kind = change.kind
        let relativePath = change.relativePath
        let originalPath = change.originalPath
        let absolutePath = change.absolutePath

        Task { [weak self] in
            await Task.detached(priority: .userInitiated) {
                SourceControlGit.discard(
                    repoRoot: root,
                    kind: kind,
                    relativePath: relativePath,
                    originalPath: originalPath,
                    absolutePath: absolutePath
                )
            }.value
            self?.refresh()
        }
    }

    // MARK: - Watching

    private func startWatching(repoRoot: String) {
        stopWatching()
        // Recursively watch the whole repository — working tree and `.git`
        // alike — so edits in subdirectories and staging writes under `.git`
        // refresh the panel, the way VS Code and Zed do. We deliberately do not
        // narrow the watch to dodge the "`git status` rewrites `.git/index` →
        // file event → refresh → …" loop. Instead `refresh()` coalesces while a
        // status run is in flight, so the index rewrite settles after one extra
        // pass. `.git/*.lock` churn that accompanies every git operation is
        // filtered out below to avoid spurious refreshes.
        let watcher = RecursiveFileSystemWatcher(paths: [repoRoot]) { [weak self] changedPaths in
            guard Self.changesWarrantRefresh(changedPaths, repoRoot: repoRoot) else { return }
            Task { @MainActor in
                self?.refresh()
            }
        }
        workingTreeWatcher = watcher
    }

    /// Decides whether a batch of changed paths should trigger a `git status`.
    ///
    /// Working-tree edits always do. Paths inside `.git` do too, except lock
    /// files (`index.lock`, `HEAD.lock`, `config.lock`, …) and watchman cookies
    /// that git and tooling create and delete around every operation — those
    /// would otherwise cause a redundant refresh on each git command.
    private nonisolated static func changesWarrantRefresh(_ paths: [String], repoRoot: String) -> Bool {
        // An empty batch means FSEvents could not attribute paths; refresh to
        // stay correct rather than miss a change.
        guard !paths.isEmpty else { return true }
        let gitDir = (repoRoot as NSString).appendingPathComponent(".git")
        let gitPrefix = gitDir + "/"
        for path in paths {
            guard path == gitDir || path.hasPrefix(gitPrefix) else {
                return true // working-tree change
            }
            let name = (path as NSString).lastPathComponent
            if name.hasSuffix(".lock") || name.hasPrefix(".watchman-cookie") {
                continue
            }
            return true // meaningful `.git` change (index, HEAD, refs, …)
        }
        return false
    }

    private func stopWatching() {
        workingTreeWatcher?.stop()
        workingTreeWatcher = nil
    }

    deinit {
        workingTreeWatcher?.stop()
    }
}

// MARK: - Git plumbing

/// Stateless `git` invocations for the Source Control panel. All functions are
/// blocking and must be called off the main actor.
enum SourceControlGit {
    struct StatusResult {
        var isRepository: Bool
        var repoRoot: String?
        var branchName: String?
        var changes: [SourceControlChange]
    }

    static func status(directory: String) -> StatusResult {
        guard let repoRoot = runGit(in: directory, ["rev-parse", "--show-toplevel"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !repoRoot.isEmpty else {
            return StatusResult(isRepository: false, repoRoot: nil, branchName: nil, changes: [])
        }

        let branch = runGit(in: repoRoot, ["rev-parse", "--abbrev-ref", "HEAD"])?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedBranch = (branch == "HEAD" || branch?.isEmpty == true) ? nil : branch

        let raw = runGit(in: repoRoot, ["status", "--porcelain=v1", "-z", "--untracked-files=all"]) ?? ""
        let changes = parsePorcelainZ(raw, repoRoot: repoRoot)

        return StatusResult(
            isRepository: true,
            repoRoot: repoRoot,
            branchName: resolvedBranch,
            changes: changes
        )
    }

    /// Parses NUL-separated `git status --porcelain=v1 -z` output. Each record
    /// is `XY <space> path`; rename/copy records are followed by a second
    /// NUL-terminated token holding the original path.
    static func parsePorcelainZ(_ raw: String, repoRoot: String) -> [SourceControlChange] {
        let tokens = raw.split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var changes: [SourceControlChange] = []
        var index = 0
        while index < tokens.count {
            let record = tokens[index]
            index += 1
            guard record.count >= 4 else { continue }
            let chars = Array(record)
            let indexStatus = chars[0]
            let workTreeStatus = chars[1]
            let path = String(chars[3...])

            var originalPath: String? = nil
            if indexStatus == "R" || indexStatus == "C" || workTreeStatus == "R" || workTreeStatus == "C" {
                if index < tokens.count {
                    originalPath = tokens[index]
                    index += 1
                }
            }

            if indexStatus == "?" && workTreeStatus == "?" {
                changes.append(makeChange(
                    repoRoot: repoRoot, path: path, originalPath: nil,
                    kind: .untracked, isStaged: false
                ))
                continue
            }

            if let stagedKind = kind(for: indexStatus) {
                changes.append(makeChange(
                    repoRoot: repoRoot, path: path, originalPath: originalPath,
                    kind: stagedKind, isStaged: true
                ))
            }
            if let worktreeKind = kind(for: workTreeStatus) {
                changes.append(makeChange(
                    repoRoot: repoRoot, path: path, originalPath: originalPath,
                    kind: worktreeKind, isStaged: false
                ))
            }
        }
        return changes
    }

    private static func kind(for status: Character) -> SourceControlChangeKind? {
        switch status {
        case "M": return .modified
        case "A": return .added
        case "D": return .deleted
        case "R": return .renamed
        case "C": return .copied
        case "T": return .typeChanged
        case "U": return .conflicted
        default: return nil
        }
    }

    private static func makeChange(
        repoRoot: String,
        path: String,
        originalPath: String?,
        kind: SourceControlChangeKind,
        isStaged: Bool
    ) -> SourceControlChange {
        let absolute = (repoRoot as NSString).appendingPathComponent(path)
        let displayName = (path as NSString).lastPathComponent
        let directory = (path as NSString).deletingLastPathComponent
        return SourceControlChange(
            id: "\(isStaged ? "staged" : "unstaged"):\(kind.rawValue):\(path)",
            relativePath: path,
            absolutePath: absolute,
            displayName: displayName,
            directoryPath: directory,
            kind: kind,
            isStaged: isStaged,
            originalPath: originalPath
        )
    }

    static func discard(
        repoRoot: String,
        kind: SourceControlChangeKind,
        relativePath: String,
        originalPath: String?,
        absolutePath: String
    ) {
        if kind == .untracked {
            try? FileManager.default.removeItem(atPath: absolutePath)
            return
        }
        // `restore` discards both staged and working-tree changes against HEAD.
        _ = runGit(in: repoRoot, ["restore", "--staged", "--worktree", "--source=HEAD", "--", relativePath])
        if let originalPath, originalPath != relativePath {
            _ = runGit(in: repoRoot, ["restore", "--staged", "--worktree", "--source=HEAD", "--", originalPath])
        }
    }

    @discardableResult
    private static func runGit(in directory: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
