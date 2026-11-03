import CoreServices
import Foundation

/// Tells its owner that something under a directory changed: a file or
/// folder created, removed, renamed or written, by any process. It reports
/// that and nothing finer, which is all a size that has to be walked again
/// needs. Events that arrive within `latency` seconds of each other come as
/// one call, made on a background queue.
public final class DirectoryWatcher: @unchecked Sendable {
    /// What the stream's C callback reaches through its `info` pointer.
    private final class Handler {
        let onChange: @Sendable () -> Void
        init(_ onChange: @escaping @Sendable () -> Void) { self.onChange = onChange }
    }

    private let handler: Handler
    private let stream: FSEventStreamRef
    private let queue = DispatchQueue(label: "RepoSweep.DirectoryWatcher", qos: .utility)

    /// Nil when the system can't watch `directory`.
    public init?(directory: URL, latency: TimeInterval = 2, onChange: @escaping @Sendable () -> Void) {
        let handler = Handler(onChange)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, _, _, _ in
                guard let info else { return }
                Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue().onChange()
            },
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNone)
        ) else { return nil }
        self.handler = handler
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        guard FSEventStreamStart(stream) else {
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            return nil
        }
    }

    deinit {
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }
}
