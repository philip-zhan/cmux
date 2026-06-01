import CoreServices
import Darwin
import Foundation

/// Boxes the path-delivering callback so it can cross the FSEvents C boundary
/// as an opaque `info` pointer. Mutations of the boxed closure never happen;
/// the box is created once and read from the watcher's serial queue.
private final class RecursiveFileSystemWatcherCallbackBox: @unchecked Sendable {
    let handleEvent: @Sendable ([String]) -> Void

    init(handleEvent: @escaping @Sendable ([String]) -> Void) {
        self.handleEvent = handleEvent
    }
}

private let recursiveFileSystemWatcherCallback: FSEventStreamCallback = {
    _, info, _, eventPaths, _, _ in
    guard let info else { return }
    let box = Unmanaged<RecursiveFileSystemWatcherCallbackBox>.fromOpaque(info).takeUnretainedValue()
    // `kFSEventStreamCreateFlagUseCFTypes` makes `eventPaths` a CFArray of
    // CFString, so the toll-free NSArray bridge yields the changed paths.
    let paths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
    box.handleEvent(paths)
}

/// Recursively watches one or more directory subtrees and reports the changed
/// paths whenever files anywhere beneath them are created, modified, renamed,
/// or deleted.
///
/// Backed by FSEvents (`FSEventStreamCreate`), the macOS-native API for
/// recursive directory observation. Unlike a single-descriptor `DispatchSource`
/// watch — which only fires for changes to a directory's *immediate* entries —
/// this notices edits arbitrarily deep in the tree. The Source Control panel
/// needs that to catch working-tree edits in subdirectories and staging writes
/// under `.git`.
///
/// FSEvents coalesces bursts of changes over the `latency` window before
/// invoking the callback, so a flurry of writes produces a single batched
/// notification rather than one per file.
final class RecursiveFileSystemWatcher: @unchecked Sendable {
    // FSEvents requires a C callback paired with a dispatch queue; there is no
    // async-native Foundation equivalent. All mutable state is confined to
    // `queue`, which makes the unchecked Sendable conformance safe.
    private let queue = DispatchQueue(label: "com.cmux.recursive-fs-watcher", qos: .utility)
    private let queueSpecificKey = DispatchSpecificKey<UInt8>()
    private var callbackBox: RecursiveFileSystemWatcherCallbackBox?
    private var stream: FSEventStreamRef?

    /// Starts watching `paths` recursively, or fails if `paths` is empty or the
    /// FSEvents stream cannot be created.
    ///
    /// - Parameters:
    ///   - paths: Absolute directory paths to watch, each observed recursively.
    ///   - latency: Seconds FSEvents coalesces changes before reporting them.
    ///     Defaults to `0.25`.
    ///   - onChange: Invoked on a background queue with the batch of changed
    ///     absolute paths. The closure must be safe to call off the main actor.
    init?(
        paths: [String],
        latency: TimeInterval = 0.25,
        onChange: @escaping @Sendable ([String]) -> Void
    ) {
        guard !paths.isEmpty else { return nil }
        queue.setSpecific(key: queueSpecificKey, value: 1)
        let callbackBox = RecursiveFileSystemWatcherCallbackBox(handleEvent: onChange)
        self.callbackBox = callbackBox

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(callbackBox).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes
                | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
        )
        guard let stream = FSEventStreamCreate(
            nil,
            recursiveFileSystemWatcherCallback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            return nil
        }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            stop()
            return nil
        }
    }

    /// Stops the watcher and releases the FSEvents stream. Safe to call more
    /// than once and from any queue.
    func stop() {
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            stopOnQueue()
        } else {
            queue.sync {
                stopOnQueue()
            }
        }
    }

    private func stopOnQueue() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }
}
