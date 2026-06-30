import Foundation

/// Runs short-lived `git` subprocesses for the code-viewer sources, off the
/// Swift concurrency cooperative thread pool and with a hard timeout.
///
/// Blocking `Process.waitUntilExit()` (and the pipe drain it waits on) must
/// never run on a `Task.detached` thread: detached tasks execute on the
/// *bounded* cooperative executor, so a handful of wedged `git` children — e.g.
/// stat-ing a stale network mount for a closed remote working directory —
/// saturate the pool and stall every Swift-concurrency task in the app,
/// including the main-thread quit flush, which then deadlocks waiting on a task
/// that can never be scheduled. This runner keeps that blocking work on a
/// dedicated dispatch queue and SIGKILLs runaway children.
enum GitCommandRunner {
    /// Reasons a git invocation failed to produce usable output.
    enum Failure: Error {
        /// `Process.run()` threw before the child started.
        case launchFailed(Error)
        /// The child exited (or was killed) with a non-zero status.
        case nonZeroExit(Int32)
    }

    /// Default ceiling for a single git invocation. Local git plumbing returns
    /// in well under a second; this only fires for a wedged child.
    static let defaultTimeout: TimeInterval = 20

    // Dedicated concurrent queue for blocking child I/O — deliberately NOT the
    // cooperative pool, so a wedged git call can never starve Swift concurrency.
    private static let workQueue = DispatchQueue(
        label: "com.cmux.git-process.work",
        qos: .userInitiated,
        attributes: .concurrent
    )

    // Serial queue that only services the timeout timers, so a timer handler is
    // never stuck behind a worker thread blocked in `waitUntilExit()`.
    private static let timerQueue = DispatchQueue(label: "com.cmux.git-process.timer")

    /// Maximum number of git load routines that may occupy a `workQueue` thread
    /// at once.
    ///
    /// `SIGKILL` cannot reclaim a child wedged in an uninterruptible kernel wait
    /// (e.g. stat-ing a stale network mount for a closed working directory): the
    /// child survives the kill, holds its stdout/stderr pipe open, and the
    /// draining worker thread blocks indefinitely. Without a ceiling, one such
    /// directory makes every diff/blame load leak a `workQueue` thread until the
    /// process hits libdispatch's 64-thread soft limit and the app hangs (e.g.
    /// the main-thread quit flush stalls behind the saturated pool). This gate
    /// bounds the number of simultaneously-wedged children; further loads queue
    /// off-thread until a slot frees instead of spawning unbounded threads.
    private static let maxConcurrentLoads = 4

    // Bounds how many `offCooperativePool` closures hold a worker thread at once.
    private static let gate = ConcurrencyGate(limit: maxConcurrentLoads)

    /// Runs `work` on a dedicated background thread off the cooperative pool and
    /// returns its result.
    ///
    /// Use this to host an entire synchronous load routine (file stats, disk
    /// reads, and ``run(_:timeout:)`` calls) so none of that blocking I/O lands
    /// on a Swift-concurrency cooperative thread.
    ///
    /// At most ``maxConcurrentLoads`` closures run at once; excess callers
    /// suspend (off-thread) at the gate until a slot frees, so a wedged child
    /// that never returns can hold a worker thread without letting later loads
    /// pile new threads onto the bounded libdispatch pool. A closure that never
    /// returns deliberately holds its slot forever — that is the wedge being
    /// contained, not a leak.
    ///
    /// - Parameter work: The blocking closure to execute off the pool.
    /// - Returns: The value produced by `work`.
    static func offCooperativePool<T: Sendable>(_ work: @Sendable @escaping () -> T) async -> T {
        await gate.acquire()
        let result = await withCheckedContinuation { continuation in
            workQueue.async {
                continuation.resume(returning: work())
            }
        }
        await gate.release()
        return result
    }

    /// Runs `git <arguments>` to completion and returns its standard output.
    ///
    /// This is synchronous and blocks the calling thread; call it only from
    /// inside ``offCooperativePool(_:)`` (never directly from a `Task`).
    ///
    /// - Parameters:
    ///   - arguments: Arguments passed to `git` (the `git` executable itself is
    ///     resolved via `/usr/bin/env`).
    ///   - timeout: Wall-clock ceiling after which the child is SIGKILLed.
    /// - Returns: The child's standard output decoded as UTF-8.
    /// - Throws: ``Failure`` if the child failed to launch or exited non-zero
    ///   (including when it was killed by the timeout).
    @discardableResult
    static func run(_ arguments: [String], timeout: TimeInterval = defaultTimeout) throws -> String {
        try run(
            executableURL: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["git"] + arguments,
            timeout: timeout
        )
    }

    /// Runs an arbitrary executable to completion with the same off-pool,
    /// timeout-killed semantics as ``run(_:timeout:)``.
    ///
    /// Exposed (internal) so the SIGKILL-on-timeout path can be exercised by
    /// tests with a deterministically slow child; production code uses the
    /// `git`-bound ``run(_:timeout:)`` overload.
    ///
    /// - Parameters:
    ///   - executableURL: Absolute path to the executable to launch.
    ///   - arguments: Arguments passed to the executable.
    ///   - timeout: Wall-clock ceiling after which the child is SIGKILLed.
    /// - Returns: The child's standard output decoded as UTF-8.
    /// - Throws: ``Failure`` if the child failed to launch or exited non-zero
    ///   (including when it was killed by the timeout).
    @discardableResult
    static func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval = defaultTimeout
    ) throws -> String {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(error)
        }

        // SIGKILL a wedged child so the drain + wait below can't block this
        // thread forever. DispatchSource one-shot timer: the deadline must fire
        // from outside this thread (which is about to block in
        // `waitUntilExit()`), and there is no async context here to host a
        // cancellable Clock.sleep. Cancelled on the normal path via `defer`.
        let timer = DispatchSource.makeTimerSource(queue: timerQueue)
        timer.schedule(deadline: .now() + timeout)
        timer.setEventHandler {
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        timer.resume()
        defer { timer.cancel() }

        // Drain both pipes concurrently before waiting on the process. macOS
        // pipe buffers are ~64KB; `git show`/`git blame` on a large file
        // overflows that, blocks on the write, and would deadlock against
        // `waitUntilExit()` if we waited first.
        var outData = Data()
        let drainQueue = DispatchQueue(label: "com.cmux.git-process.pipe", attributes: .concurrent)
        let group = DispatchGroup()
        drainQueue.async(group: group) {
            outData = stdout.fileHandleForReading.readDataToEndOfFile()
        }
        drainQueue.async(group: group) {
            _ = stderr.fileHandleForReading.readDataToEndOfFile()
        }
        group.wait()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw Failure.nonZeroExit(process.terminationStatus)
        }
        return String(data: outData, encoding: .utf8) ?? ""
    }
}

/// A bounded async semaphore: an `actor`-isolated counting permit used to cap
/// how many blocking git load routines occupy a worker thread concurrently.
///
/// `acquire()` suspends (never blocks a thread) when no permit is free, so
/// excess callers wait off-thread in FIFO order. Promotes a `DispatchSemaphore`
/// to actor isolation per the codebase's Swift-6 concurrency rules.
private actor ConcurrencyGate {
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameter limit: The maximum number of permits held simultaneously.
    init(limit: Int) {
        available = limit
    }

    /// Takes a permit, suspending until one is free. Pair every successful
    /// `acquire()` with exactly one ``release()``.
    func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    /// Returns a permit, resuming the longest-waiting caller if any.
    func release() {
        if waiters.isEmpty {
            available += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}
