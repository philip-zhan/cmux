import Foundation
import Testing

@testable import cmux

/// Behavioral coverage for ``GitCommandRunner`` — in particular the
/// SIGKILL-on-timeout path, which is what stops a wedged child (e.g. `git`
/// stat-ing a stale network mount) from blocking its worker thread forever and
/// starving Swift concurrency.
@Suite struct GitCommandRunnerTests {
    /// A child that outlives the timeout is killed promptly rather than blocking
    /// for its full natural duration, and the call surfaces a failure.
    @Test func killsChildExceedingTimeout() {
        let start = Date()
        var thrown: (any Error)?
        do {
            _ = try GitCommandRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/sleep"),
                arguments: ["30"],
                timeout: 0.5
            )
        } catch {
            thrown = error
        }
        let elapsed = Date().timeIntervalSince(start)

        // The 30s sleep must have been killed near the 0.5s deadline, nowhere
        // near its natural runtime. A generous ceiling keeps this non-flaky on
        // loaded CI while still failing hard if the timeout regressed.
        #expect(elapsed < 10)
        // Killed-by-signal exits non-zero, so the caller sees a failure.
        guard case .nonZeroExit = thrown as? GitCommandRunner.Failure else {
            Issue.record("expected GitCommandRunner.Failure.nonZeroExit, got \(String(describing: thrown))")
            return
        }
    }

    /// A fast-completing child returns its standard output verbatim.
    @Test func returnsStandardOutputForFastCommand() throws {
        let output = try GitCommandRunner.run(
            executableURL: URL(fileURLWithPath: "/bin/echo"),
            arguments: ["hello"],
            timeout: 5
        )
        #expect(output == "hello\n")
    }

    /// A non-zero exit surfaces as ``GitCommandRunner/Failure/nonZeroExit``.
    @Test func throwsOnNonZeroExit() {
        var thrown: (any Error)?
        do {
            _ = try GitCommandRunner.run(
                executableURL: URL(fileURLWithPath: "/usr/bin/false"),
                arguments: [],
                timeout: 5
            )
        } catch {
            thrown = error
        }
        guard case .nonZeroExit(let status) = thrown as? GitCommandRunner.Failure else {
            Issue.record("expected GitCommandRunner.Failure.nonZeroExit, got \(String(describing: thrown))")
            return
        }
        #expect(status != 0)
    }

    /// A missing executable surfaces as ``GitCommandRunner/Failure/launchFailed``
    /// rather than crashing or hanging.
    @Test func throwsLaunchFailedForMissingExecutable() {
        var thrown: (any Error)?
        do {
            _ = try GitCommandRunner.run(
                executableURL: URL(fileURLWithPath: "/nonexistent/definitely-not-here"),
                arguments: [],
                timeout: 5
            )
        } catch {
            thrown = error
        }
        guard case .launchFailed = thrown as? GitCommandRunner.Failure else {
            Issue.record("expected GitCommandRunner.Failure.launchFailed, got \(String(describing: thrown))")
            return
        }
    }

    /// ``GitCommandRunner/offCooperativePool(_:)`` runs the closure and returns
    /// its result.
    @Test func offCooperativePoolReturnsResult() async {
        let value = await GitCommandRunner.offCooperativePool { 21 * 2 }
        #expect(value == 42)
    }
}
