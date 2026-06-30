import Foundation
import Testing
import os

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

    /// ``GitCommandRunner/offCooperativePool(_:)`` never runs more closures at
    /// once than its internal ceiling, so a flood of diff/blame loads can't
    /// saturate the libdispatch worker pool and hang the app — the failure in
    /// the 64-thread `com.cmux.git-process.work` stackshot. Without the gate,
    /// all 32 closures overlap and `peak` reaches 32; with it, `peak` stays at
    /// or below the ceiling.
    @Test func offCooperativePoolCapsConcurrentClosures() async {
        // Guards a tiny counter pair mutated from synchronous workQueue closures
        // (non-async callbacks); covered by the GitCommandRunner lock carve-out.
        let state = OSAllocatedUnfairLock(initialState: (current: 0, peak: 0))
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<32 {
                group.addTask {
                    await GitCommandRunner.offCooperativePool {
                        state.withLock { s in
                            s.current += 1
                            s.peak = max(s.peak, s.current)
                        }
                        // Deliberate hold (not a poll/settle): widens the window
                        // so concurrent closures actually coincide, making an
                        // unbounded gate observable as a peak above the ceiling.
                        Thread.sleep(forTimeInterval: 0.01)
                        state.withLock { $0.current -= 1 }
                    }
                }
            }
        }
        let peak = state.withLock { $0.peak }
        // Ceiling is an implementation detail; assert against a value at least as
        // large as it so the test tracks the cap without hardcoding churn, while
        // still failing hard on the unbounded (peak == 32) regression.
        #expect(peak >= 1)
        #expect(peak <= 8)
    }
}
