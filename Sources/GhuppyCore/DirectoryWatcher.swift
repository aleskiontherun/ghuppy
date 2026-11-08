import CoreServices
import Foundation

/// Tells its owner that something under a directory changed: a file or
/// folder created, removed, renamed or written, by any process. Each call
/// passes the directories whose contents changed, not the files in them,
/// which is all a size that has to be walked again or a list of checkouts
/// needs. Events that arrive within `latency` seconds of each other come as
/// one call, made on a background queue.
public final class DirectoryWatcher: @unchecked Sendable {
    /// What the stream's C callback reaches through its `info` pointer.
    private final class Handler {
        let onChange: @Sendable ([String]) -> Void
        init(_ onChange: @escaping @Sendable ([String]) -> Void) { self.onChange = onChange }
    }

    private let handler: Handler
    private let stream: FSEventStreamRef
    private let queue = DispatchQueue(label: "Ghuppy.DirectoryWatcher", qos: .utility)

    /// Nil when the system can't watch `directory`.
    public init?(directory: URL, latency: TimeInterval = 2, onChange: @escaping @Sendable ([String]) -> Void) {
        let handler = Handler(onChange)
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(handler).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { _, info, _, eventPaths, _, _ in
                guard let info else { return }
                // With `UseCFTypes` the paths come as a CFArray of CFStrings.
                let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as? [String] ?? []
                Unmanaged<Handler>.fromOpaque(info).takeUnretainedValue().onChange(paths)
            },
            &context,
            [directory.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes)
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
        // A callback already running on the queue still reads `handler`,
        // which goes when this does; the stream is invalidated, so none
        // starts after this.
        queue.sync {}
        FSEventStreamRelease(stream)
    }
}
