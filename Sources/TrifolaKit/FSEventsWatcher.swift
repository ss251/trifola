import Foundation
import CoreServices

/// Recursive directory watcher built on FSEvents. Paths that changed are delivered
/// (coalesced by `latency`) on a background queue via the `onPaths` callback.
/// The dashboard uses one of these across ~/.claude — that is what makes
/// every screen live without polling.
public final class FSEventsWatcher: @unchecked Sendable {
    private let paths: [String]
    private let latency: CFTimeInterval
    private let onPaths: @Sendable ([String]) -> Void
    private let queue = DispatchQueue(label: "mc.fsevents", qos: .utility)
    private var stream: FSEventStreamRef?

    public init(paths: [String], latency: CFTimeInterval = 0.6,
                onPaths: @escaping @Sendable ([String]) -> Void) {
        self.paths = paths.filter { FileManager.default.fileExists(atPath: $0) }
        self.latency = latency
        self.onPaths = onPaths
    }

    deinit { stop() }

    public func start() {
        guard stream == nil, !paths.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil, release: nil, copyDescription: nil
        )
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes)
            | UInt32(kFSEventStreamCreateFlagFileEvents)
            | UInt32(kFSEventStreamCreateFlagNoDefer)
        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            fsEventsCallback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(flags)
        ) else { return }
        self.stream = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    public func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    fileprivate func deliver(_ changed: [String]) { onPaths(changed) }
}

private let fsEventsCallback: FSEventStreamCallback = { _, info, numEvents, eventPaths, _, _ in
    guard let info else { return }
    let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(info).takeUnretainedValue()
    // With kFSEventStreamCreateFlagUseCFTypes, eventPaths is a CFArray of CFString.
    let cfArray = Unmanaged<CFArray>.fromOpaque(UnsafeRawPointer(eventPaths)).takeUnretainedValue()
    guard let paths = cfArray as? [String], paths.count == numEvents else { return }
    watcher.deliver(paths)
}
