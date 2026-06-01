import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CommandPaletteFileSearchTests: XCTestCase {
    // MARK: - Scope resolution

    func testFilesPrefixedModeRoutesAtPrefixToFiles() {
        XCTAssertEqual(
            ContentView.commandPaletteListScope(for: "", mode: .filesPrefixed).rawValue,
            "switcher"
        )
        XCTAssertEqual(
            ContentView.commandPaletteListScope(for: "@foo", mode: .filesPrefixed).rawValue,
            "files"
        )
        XCTAssertEqual(
            ContentView.commandPaletteListScope(for: ">rename", mode: .filesPrefixed).rawValue,
            "commands"
        )
    }

    func testSwitcherPrefixedModeFlipsBareAndAt() {
        XCTAssertEqual(
            ContentView.commandPaletteListScope(for: "", mode: .switcherPrefixed).rawValue,
            "files"
        )
        XCTAssertEqual(
            ContentView.commandPaletteListScope(for: "main", mode: .switcherPrefixed).rawValue,
            "files"
        )
        XCTAssertEqual(
            ContentView.commandPaletteListScope(for: "@workspace", mode: .switcherPrefixed).rawValue,
            "switcher"
        )
        XCTAssertEqual(
            ContentView.commandPaletteListScope(for: ">rename", mode: .switcherPrefixed).rawValue,
            "commands"
        )
    }

    func testDefaultModeSearchesFilesWithoutPrefix() {
        XCTAssertEqual(CommandPaletteFileSearchSettings.defaultMode, .switcherPrefixed)
        XCTAssertEqual(
            ContentView.commandPaletteListScope(for: "", mode: CommandPaletteFileSearchSettings.defaultMode).rawValue,
            "files"
        )
        XCTAssertEqual(
            ContentView.commandPaletteListScope(for: "readme", mode: CommandPaletteFileSearchSettings.defaultMode).rawValue,
            "files"
        )
    }

    // MARK: - Settings configuration review

    // Regression: the command palette file search mode settings row referenced a
    // cmux.json path that was missing from supportedSettingsJSONPaths, so opening
    // Settings tripped the validate() precondition and crashed the app.
    func testFileSearchModeSettingsRowConfigurationReviewDoesNotTrap() {
        XCTAssertTrue(
            CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("app.commandPaletteFileSearchMode")
        )
    }

    // MARK: - commandPaletteFileRankerCandidates

    private func makeSnapshot(_ paths: [String]) -> CommandPaletteFileIndexSnapshot {
        let entries = paths.map { path in
            CommandPaletteFileIndexSnapshot.Entry(
                relativePath: path,
                fileName: (path as NSString).lastPathComponent
            )
        }
        return CommandPaletteFileIndexSnapshot(
            rootPath: "/tmp/test",
            entries: entries,
            status: .ready,
            truncated: false,
            generation: 1
        )
    }

    func testRankerCandidatesReturnsAllSnapshotEntriesWhenQueryNonEmpty() {
        let snapshot = makeSnapshot(["a/foo.swift", "b/bar.swift"])
        let candidates = ContentView.commandPaletteFileRankerCandidates(
            snapshot: snapshot,
            queryIsEmpty: false,
            recentsRanks: ["a/foo.swift": 0]
        )
        XCTAssertEqual(candidates.map(\.relativePath), ["a/foo.swift", "b/bar.swift"])
    }

    func testRankerCandidatesReturnsEmptyWhenNoQueryAndNoRecents() {
        let snapshot = makeSnapshot(["a/foo.swift", "b/bar.swift"])
        let candidates = ContentView.commandPaletteFileRankerCandidates(
            snapshot: snapshot,
            queryIsEmpty: true,
            recentsRanks: [:]
        )
        XCTAssertTrue(candidates.isEmpty)
    }

    func testRankerCandidatesReturnsOnlyRecentsInRecencyOrderWhenQueryEmpty() {
        let snapshot = makeSnapshot(["a/foo.swift", "b/bar.swift", "c/baz.swift"])
        let candidates = ContentView.commandPaletteFileRankerCandidates(
            snapshot: snapshot,
            queryIsEmpty: true,
            recentsRanks: ["b/bar.swift": 0, "a/foo.swift": 1]
        )
        XCTAssertEqual(candidates.map(\.relativePath), ["b/bar.swift", "a/foo.swift"])
    }

    func testRankerCandidatesDropsRecentsMissingFromSnapshot() {
        let snapshot = makeSnapshot(["a/foo.swift"])
        let candidates = ContentView.commandPaletteFileRankerCandidates(
            snapshot: snapshot,
            queryIsEmpty: true,
            recentsRanks: ["deleted/old.swift": 0, "a/foo.swift": 1]
        )
        XCTAssertEqual(candidates.map(\.relativePath), ["a/foo.swift"])
    }

    // MARK: - Recents store

    @MainActor
    func testRecentsStoreRecordsAndPersistsAcrossLoad() throws {
        let store = CommandPaletteFileRecentsStore()
        let workspaceID = UUID()
        let root = "/tmp/test-recents-\(UUID().uuidString)"

        store.recordOpen(
            workspaceID: workspaceID,
            rootPath: root,
            absolutePath: "\(root)/a/foo.swift",
            now: Date(timeIntervalSince1970: 1_000)
        )
        store.recordOpen(
            workspaceID: workspaceID,
            rootPath: root,
            absolutePath: "\(root)/b/bar.swift",
            now: Date(timeIntervalSince1970: 2_000)
        )

        let recents = store.recents(workspaceID: workspaceID)
        XCTAssertEqual(recents.map(\.relativePath), ["b/bar.swift", "a/foo.swift"])
        XCTAssertEqual(recents.map(\.openCount), [1, 1])

        // A second instance reads the same file from disk and sees the same ordering.
        let second = CommandPaletteFileRecentsStore()
        let reloaded = second.recents(workspaceID: workspaceID)
        XCTAssertEqual(reloaded.map(\.relativePath), ["b/bar.swift", "a/foo.swift"])
    }

    @MainActor
    func testRecentsStoreBumpsOpenCountAndPromotesOnReopen() {
        let store = CommandPaletteFileRecentsStore()
        let workspaceID = UUID()
        let root = "/tmp/test-recents-\(UUID().uuidString)"

        store.recordOpen(
            workspaceID: workspaceID,
            rootPath: root,
            absolutePath: "\(root)/a/foo.swift",
            now: Date(timeIntervalSince1970: 1_000)
        )
        store.recordOpen(
            workspaceID: workspaceID,
            rootPath: root,
            absolutePath: "\(root)/b/bar.swift",
            now: Date(timeIntervalSince1970: 2_000)
        )
        store.recordOpen(
            workspaceID: workspaceID,
            rootPath: root,
            absolutePath: "\(root)/a/foo.swift",
            now: Date(timeIntervalSince1970: 3_000)
        )

        let recents = store.recents(workspaceID: workspaceID)
        XCTAssertEqual(recents.first?.relativePath, "a/foo.swift")
        XCTAssertEqual(recents.first?.openCount, 2)
    }

    @MainActor
    func testRecentsStoreCapsAtMax() {
        let store = CommandPaletteFileRecentsStore()
        let workspaceID = UUID()
        let root = "/tmp/test-recents-\(UUID().uuidString)"

        for index in 0..<(CommandPaletteFileRecentsStore.maxEntriesPerWorkspace + 10) {
            store.recordOpen(
                workspaceID: workspaceID,
                rootPath: root,
                absolutePath: "\(root)/file-\(index).swift",
                now: Date(timeIntervalSince1970: TimeInterval(index))
            )
        }

        XCTAssertEqual(
            store.recents(workspaceID: workspaceID).count,
            CommandPaletteFileRecentsStore.maxEntriesPerWorkspace
        )
        // Newest entry should remain.
        XCTAssertEqual(
            store.recents(workspaceID: workspaceID).first?.relativePath,
            "file-\(CommandPaletteFileRecentsStore.maxEntriesPerWorkspace + 9).swift"
        )
    }

    @MainActor
    func testRecentsStoreScopedPerWorkspace() {
        let store = CommandPaletteFileRecentsStore()
        let ws1 = UUID()
        let ws2 = UUID()
        let root1 = "/tmp/ws1-\(UUID().uuidString)"
        let root2 = "/tmp/ws2-\(UUID().uuidString)"

        store.recordOpen(
            workspaceID: ws1,
            rootPath: root1,
            absolutePath: "\(root1)/foo.swift",
            now: Date(timeIntervalSince1970: 1_000)
        )
        store.recordOpen(
            workspaceID: ws2,
            rootPath: root2,
            absolutePath: "\(root2)/bar.swift",
            now: Date(timeIntervalSince1970: 2_000)
        )

        XCTAssertEqual(store.recents(workspaceID: ws1).map(\.relativePath), ["foo.swift"])
        XCTAssertEqual(store.recents(workspaceID: ws2).map(\.relativePath), ["bar.swift"])
    }
}
