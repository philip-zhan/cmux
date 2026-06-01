import Combine
import Darwin
import Foundation

/// Snapshot of an `rg --files`-produced file list for a single workspace root.
/// Consumed by the command palette `.files` scope to populate its search corpus.
struct CommandPaletteFileIndexSnapshot: Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case idle
        case indexing
        case ready
        case failed(reason: Reason)
    }

    enum Reason: Sendable, Equatable {
        case rgNotInstalled
        case rgFailed(exitCode: Int32)
        case cancelled
    }

    struct Entry: Sendable, Equatable, Hashable {
        /// Path relative to `rootPath`, using POSIX separators. Never empty.
        let relativePath: String
        /// Final path component of `relativePath`.
        let fileName: String
        /// Pre-lowercased basename for the substring ranker. Computed off-main while
        /// reading `rg` so per-keystroke search avoids the locale-aware fold cost.
        let fileNameLower: String
        /// Pre-lowercased relative path for the substring ranker.
        let relativePathLower: String

        init(
            relativePath: String,
            fileName: String,
            fileNameLower: String? = nil,
            relativePathLower: String? = nil
        ) {
            self.relativePath = relativePath
            self.fileName = fileName
            self.fileNameLower = fileNameLower ?? fileName.lowercased()
            self.relativePathLower = relativePathLower ?? relativePath.lowercased()
        }
    }

    let rootPath: String
    let entries: [Entry]
    let status: Status
    let truncated: Bool
    let generation: UInt64

    static let empty = CommandPaletteFileIndexSnapshot(
        rootPath: "",
        entries: [],
        status: .idle,
        truncated: false,
        generation: 0
    )
}

@MainActor
final class CommandPaletteFileIndexer: ObservableObject {
    static let shared = CommandPaletteFileIndexer()

    /// Hard cap on the number of entries kept per snapshot. The cap is intentionally
    /// modest — the substring ranker is fast at this scale (~1ms/keystroke over 30k
    /// candidates), and beyond it the user almost certainly wants to refine the query
    /// rather than scroll through more rows. The earlier 200k cap noticeably stalled
    /// the corpus build on huge monorepos.
    static let maxEntries = 30_000

    /// Cap for the dedicated `.env*` pass. These config files are routinely
    /// gitignored, so a second `rg --files` run with `--no-ignore` surfaces them.
    /// The glob keeps the match set tiny; the cap is a defensive upper bound.
    static let maxEnvEntries = 256

    private struct Request: Equatable {
        let rootPath: String
    }

    private var generation: UInt64 = 0
    private var processes: [Process] = []
    private var readTask: Task<Void, Never>?
    private var activeRequest: Request?
    @Published private(set) var currentSnapshot: CommandPaletteFileIndexSnapshot = .empty

    /// Begin (or reuse) an index build for `rootPath`. If the root matches the active
    /// request and a build is in flight or complete, this is a no-op.
    ///
    /// Pass `forceRefresh: true` to rebuild even when a `.ready` snapshot already
    /// exists for the same root. The corpus is built once and cached, so files
    /// created after the first build (typically untracked, just-added files) would
    /// otherwise never appear until the workspace root changes. Callers force a
    /// rebuild once per command-palette open to pick those up.
    func requestIndex(forRootPath rootPath: String, forceRefresh: Bool = false) {
        let trimmed = rootPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            cancel(reason: .cancelled)
            currentSnapshot = .empty
            return
        }

        let request = Request(rootPath: trimmed)
        if activeRequest == request, processes.contains(where: { $0.isRunning }) {
            return
        }
        if !forceRefresh, activeRequest == request, currentSnapshot.status == .ready {
            return
        }

        cancel(reason: .cancelled)
        activeRequest = request

        guard let rg = RipgrepExecutableResolver.resolve() else {
            currentSnapshot = CommandPaletteFileIndexSnapshot(
                rootPath: trimmed,
                entries: [],
                status: .failed(reason: .rgNotInstalled),
                truncated: false,
                generation: advanceGeneration()
            )
            return
        }

        let buildGeneration = advanceGeneration()
        currentSnapshot = CommandPaletteFileIndexSnapshot(
            rootPath: trimmed,
            entries: [],
            status: .indexing,
            truncated: false,
            generation: buildGeneration
        )
        spawn(rg: rg, rootPath: trimmed, generation: buildGeneration)
    }

    /// Drop any in-flight work and reset state. Safe to call from any path.
    func reset() {
        cancel(reason: .cancelled)
        activeRequest = nil
        currentSnapshot = .empty
    }

    private func advanceGeneration() -> UInt64 {
        generation &+= 1
        return generation
    }

    private func cancel(reason: CommandPaletteFileIndexSnapshot.Reason) {
        readTask?.cancel()
        readTask = nil
        for process in processes where process.isRunning {
            process.terminate()
        }
        processes = []
        _ = reason
    }

    private func spawn(rg: FileSearchRipgrepExecutable, rootPath: String, generation buildGeneration: UInt64) {
        // Main pass: every file, honoring `.gitignore`. `--null` separates results
        // with NUL so paths with newlines are safe. `--hidden` includes dotfiles;
        // `rg` skips the `.git` directory by default, and `-g '!.git'` makes that
        // explicit. `rg --files` lists files using the same ignore-aware walker as
        // content search, so quick open and global search share one binary.
        let mainProcess = Process()
        mainProcess.executableURL = rg.url
        mainProcess.arguments = rg.prefixArguments + [
            "--files",
            "--hidden",
            "--null",
            "--glob", "!.git",
            rootPath,
        ]
        // `.env` pass: `.env*` config files (`.env`, `.env.local`, `.env.production`,
        // …) are routinely gitignored, but users still want to open them from the
        // palette. `--no-ignore` defeats `.gitignore`; the `-g '.env*'` pattern keeps
        // the match set tiny so it cannot flood the corpus. `node_modules` and `.git`
        // are excluded since stray `.env` files vendored there are noise.
        let envProcess = Process()
        envProcess.executableURL = rg.url
        envProcess.arguments = rg.prefixArguments + [
            "--files",
            "--hidden",
            "--no-ignore",
            "--null",
            "--glob", ".env*",
            "--glob", "!**/node_modules/**",
            "--glob", "!**/.git/**",
            rootPath,
        ]

        let mainStdout = Pipe()
        let mainStderr = Pipe()
        mainProcess.standardOutput = mainStdout
        mainProcess.standardError = mainStderr
        let envStdout = Pipe()
        let envStderr = Pipe()
        envProcess.standardOutput = envStdout
        envProcess.standardError = envStderr

        do {
            try mainProcess.run()
            try envProcess.run()
        } catch {
            cancel(reason: .cancelled)
            currentSnapshot = CommandPaletteFileIndexSnapshot(
                rootPath: rootPath,
                entries: [],
                status: .failed(reason: .rgFailed(exitCode: -1)),
                truncated: false,
                generation: buildGeneration
            )
            return
        }
        self.processes = [mainProcess, envProcess]

        let maxEntries = Self.maxEntries
        let maxEnvEntries = Self.maxEnvEntries

        readTask = Task.detached(priority: .userInitiated) { [weak self] in
            async let mainResultAsync = Self.readEntries(
                outputHandle: mainStdout.fileHandleForReading,
                errorHandle: mainStderr.fileHandleForReading,
                rootPath: rootPath,
                maxEntries: maxEntries
            )
            async let envResultAsync = Self.readEntries(
                outputHandle: envStdout.fileHandleForReading,
                errorHandle: envStderr.fileHandleForReading,
                rootPath: rootPath,
                maxEntries: maxEnvEntries
            )
            let mainResult = await mainResultAsync
            let envResult = await envResultAsync
            mainProcess.waitUntilExit()
            envProcess.waitUntilExit()
            // Only the main pass gates index health; a failed `.env` pass just means
            // no extra entries, not a broken file search. `rg` exits 1 when it lists
            // zero files (e.g. an empty workspace) — that is not an error, so only
            // exit codes >= 2 (genuine `rg` failures) mark the index as failed.
            let exitCode = mainProcess.terminationStatus
            let merged = Self.merge(
                main: mainResult.entries,
                env: envResult.entries,
                limit: maxEntries
            )
            await MainActor.run {
                guard let self else { return }
                guard self.generation == buildGeneration else { return }
                self.processes = []
                self.readTask = nil

                let status: CommandPaletteFileIndexSnapshot.Status
                if Task.isCancelled {
                    status = .failed(reason: .cancelled)
                } else if exitCode >= 2 {
                    status = .failed(reason: .rgFailed(exitCode: exitCode))
                } else {
                    status = .ready
                }

                self.currentSnapshot = CommandPaletteFileIndexSnapshot(
                    rootPath: rootPath,
                    entries: merged.entries,
                    status: status,
                    truncated: mainResult.truncated || merged.truncated,
                    generation: buildGeneration
                )
            }
        }
    }

    /// Merge the main and `.env` passes, deduplicating by relative path. A `.env`
    /// file that is not gitignored appears in both passes; the main-pass entry wins
    /// so ordering stays stable.
    nonisolated private static func merge(
        main: [CommandPaletteFileIndexSnapshot.Entry],
        env: [CommandPaletteFileIndexSnapshot.Entry],
        limit: Int
    ) -> (entries: [CommandPaletteFileIndexSnapshot.Entry], truncated: Bool) {
        var seen = Set<String>(minimumCapacity: main.count + env.count)
        var result: [CommandPaletteFileIndexSnapshot.Entry] = []
        result.reserveCapacity(main.count + env.count)
        for entry in main where seen.insert(entry.relativePath).inserted {
            result.append(entry)
        }
        var truncated = false
        for entry in env {
            if result.count >= limit {
                truncated = true
                break
            }
            if seen.insert(entry.relativePath).inserted {
                result.append(entry)
            }
        }
        return (result, truncated)
    }

    private static func readEntries(
        outputHandle: FileHandle,
        errorHandle: FileHandle,
        rootPath: String,
        maxEntries: Int
    ) async -> (entries: [CommandPaletteFileIndexSnapshot.Entry], truncated: Bool) {
        // Drain stderr to /dev/null so a large stream doesn't block rg's exit.
        let drainTask = Task.detached(priority: .utility) {
            while true {
                let data = errorHandle.availableData
                if data.isEmpty { break }
            }
        }
        defer { drainTask.cancel() }

        var entries: [CommandPaletteFileIndexSnapshot.Entry] = []
        entries.reserveCapacity(min(maxEntries, 4096))
        var buffer = Data()
        var truncated = false
        let rootWithSlash = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"

        while !truncated {
            let chunk = outputHandle.availableData
            if chunk.isEmpty { break }
            buffer.append(chunk)
            while let nulRange = buffer.range(of: Data([0])) {
                let slice = buffer.subdata(in: 0..<nulRange.lowerBound)
                buffer.removeSubrange(0..<nulRange.upperBound)
                guard !slice.isEmpty,
                      let absolute = String(data: slice, encoding: .utf8) else {
                    continue
                }
                let relative: String
                if absolute.hasPrefix(rootWithSlash) {
                    relative = String(absolute.dropFirst(rootWithSlash.count))
                } else if absolute == rootPath {
                    continue
                } else {
                    relative = absolute
                }
                guard !relative.isEmpty else { continue }
                let fileName = (relative as NSString).lastPathComponent
                entries.append(.init(
                    relativePath: relative,
                    fileName: fileName,
                    fileNameLower: fileName.lowercased(),
                    relativePathLower: relative.lowercased()
                ))
                if entries.count >= maxEntries {
                    truncated = true
                    break
                }
            }
            if Task.isCancelled { break }
        }

        return (entries, truncated)
    }
}
