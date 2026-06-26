import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CodePreviewEngineSettingsTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        let suite = "cmux.codePreviewEngine.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    func testDefaultsToAuto() {
        XCTAssertEqual(CodePreviewEngineSettings.current(defaults: defaults), .auto)
    }

    func testReadsExplicitEngineFromDefaults() {
        defaults.set(CodePreviewEngine.codeMirror.rawValue, forKey: CodePreviewEngineSettings.engineKey)
        XCTAssertEqual(CodePreviewEngineSettings.current(defaults: defaults), .codeMirror)
    }

    func testNativeTextEngineNeverPicksCodeMirror() {
        defaults.set(CodePreviewEngine.nativeText.rawValue, forKey: CodePreviewEngineSettings.engineKey)
        XCTAssertFalse(CodePreviewEngineSettings.shouldUseCodeMirror(forPath: "/tmp/foo.swift", defaults: defaults))
        XCTAssertFalse(CodePreviewEngineSettings.shouldUseCodeMirror(forPath: "/tmp/foo.bin", defaults: defaults))
    }

    func testCodeMirrorEngineAlwaysPicksCodeMirror() {
        defaults.set(CodePreviewEngine.codeMirror.rawValue, forKey: CodePreviewEngineSettings.engineKey)
        XCTAssertTrue(CodePreviewEngineSettings.shouldUseCodeMirror(forPath: "/tmp/foo.swift", defaults: defaults))
        XCTAssertTrue(CodePreviewEngineSettings.shouldUseCodeMirror(forPath: "/tmp/unknown.xyzqq", defaults: defaults))
    }

    func testAutoEngineUsesCodeMirrorForEveryTextFileRegardlessOfLanguage() {
        defaults.set(CodePreviewEngine.auto.rawValue, forKey: CodePreviewEngineSettings.engineKey)
        // Recognized languages, plain text, and unknown extensions all route to
        // CodeMirror so search/highlighting work everywhere.
        XCTAssertTrue(CodePreviewEngineSettings.shouldUseCodeMirror(forPath: "/tmp/foo.swift", defaults: defaults))
        XCTAssertTrue(CodePreviewEngineSettings.shouldUseCodeMirror(forPath: "/tmp/foo.py", defaults: defaults))
        XCTAssertTrue(CodePreviewEngineSettings.shouldUseCodeMirror(forPath: "/tmp/.env", defaults: defaults))
        XCTAssertTrue(CodePreviewEngineSettings.shouldUseCodeMirror(forPath: "/tmp/notes.txt", defaults: defaults))
        XCTAssertTrue(CodePreviewEngineSettings.shouldUseCodeMirror(forPath: "/tmp/unknown.xyzqq", defaults: defaults))
    }

    func testAutoEngineFallsBackToNativeForLargeFiles() {
        defaults.set(CodePreviewEngine.auto.rawValue, forKey: CodePreviewEngineSettings.engineKey)
        let underCap = CodePreviewEngineSettings.maximumCodeMirrorBytes
        let overCap = CodePreviewEngineSettings.maximumCodeMirrorBytes + 1
        XCTAssertTrue(
            CodePreviewEngineSettings.shouldUseCodeMirror(forPath: "/tmp/foo.swift", fileSize: underCap, defaults: defaults)
        )
        XCTAssertFalse(
            CodePreviewEngineSettings.shouldUseCodeMirror(forPath: "/tmp/foo.swift", fileSize: overCap, defaults: defaults)
        )
    }

    func testCodeMirrorEngineIgnoresSizeCap() {
        defaults.set(CodePreviewEngine.codeMirror.rawValue, forKey: CodePreviewEngineSettings.engineKey)
        let overCap = CodePreviewEngineSettings.maximumCodeMirrorBytes + 1
        XCTAssertTrue(
            CodePreviewEngineSettings.shouldUseCodeMirror(forPath: "/tmp/foo.log", fileSize: overCap, defaults: defaults)
        )
    }
}
