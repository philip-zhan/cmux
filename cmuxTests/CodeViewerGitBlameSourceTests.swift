import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Behavior-level coverage for the inline-blame source. Builds a throwaway git
/// repo under a temp directory and drives the real `git blame --line-porcelain`
/// path so the porcelain parser is exercised end-to-end, not against a frozen
/// string fixture.
@Suite struct CodeViewerGitBlameSourceTests {
    private let tempDir: URL

    init() throws {
        tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmux-codeviewer-blame-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    @Test func returnsNilOutsideGitRepo() async throws {
        let path = tempDir.appendingPathComponent("untracked.txt")
        try "hello\n".write(to: path, atomically: true, encoding: .utf8)
        let blame = await CodeViewerGitBlameSource.load(filePath: path.path)
        #expect(blame == nil)
        try cleanup()
    }

    @Test func blamesCommittedLinesWithAuthorAndSummary() async throws {
        try initRepo()
        let path = tempDir.appendingPathComponent("greeting.txt")
        try "alpha\nbeta\n".write(to: path, atomically: true, encoding: .utf8)
        try runGit(["add", "greeting.txt"])
        try runGit(["commit", "-m", "Add greeting lines"])

        let blame = try #require(await CodeViewerGitBlameSource.load(filePath: path.path))
        #expect(blame.count == 2)
        for line in blame {
            #expect(line.isUncommitted == false)
            #expect(line.author == "Test")
            #expect(line.summary == "Add greeting lines")
            #expect(line.shortHash.count == 8)
            #expect(line.timestamp > 0)
        }
        try cleanup()
    }

    @Test func marksUncommittedLinesAsYou() async throws {
        try initRepo()
        let path = tempDir.appendingPathComponent("notes.txt")
        try "committed line\n".write(to: path, atomically: true, encoding: .utf8)
        try runGit(["add", "notes.txt"])
        try runGit(["commit", "-m", "Initial"])

        // Append a line that is not staged or committed.
        try "committed line\nfresh uncommitted line\n".write(to: path, atomically: true, encoding: .utf8)

        let blame = try #require(await CodeViewerGitBlameSource.load(filePath: path.path))
        #expect(blame.count == 2)
        #expect(blame[0].isUncommitted == false)
        #expect(blame[0].author == "Test")
        #expect(blame[1].isUncommitted == true)
        #expect(blame[1].author == "You")
        #expect(blame[1].shortHash.isEmpty)
        #expect(blame[1].summary.isEmpty)
        try cleanup()
    }

    @Test func distinguishesPerLineCommits() async throws {
        try initRepo()
        let path = tempDir.appendingPathComponent("history.txt")
        try "first\n".write(to: path, atomically: true, encoding: .utf8)
        try runGit(["add", "history.txt"])
        try runGit(["commit", "-m", "First commit"])

        try "first\nsecond\n".write(to: path, atomically: true, encoding: .utf8)
        try runGit(["add", "history.txt"])
        try runGit(["commit", "-m", "Second commit"])

        let blame = try #require(await CodeViewerGitBlameSource.load(filePath: path.path))
        #expect(blame.count == 2)
        #expect(blame[0].summary == "First commit")
        #expect(blame[1].summary == "Second commit")
        #expect(blame[0].shortHash != blame[1].shortHash)
        try cleanup()
    }

    // MARK: helpers

    private func cleanup() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func initRepo() throws {
        try runGit(["init", "-q", "-b", "main"])
        try runGit(["config", "user.email", "test@example.com"])
        try runGit(["config", "user.name", "Test"])
        try runGit(["config", "commit.gpgsign", "false"])
    }

    @discardableResult
    private func runGit(_ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + args
        process.currentDirectoryURL = tempDir
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "<no stderr>"
            throw NSError(
                domain: "CodeViewerGitBlameSourceTests",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "git \(args.joined(separator: " ")) failed: \(message)"]
            )
        }
        return String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    }
}
