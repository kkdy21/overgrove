import CoreServices
import Foundation

/// Watches folders and reports file events (auto refresh, #119). The live version is FSEvents (CoreServices, part of
/// macOS: no dependency); tests pass their own.
protocol FileEventWatching: Sendable {
    /// Starts watching `paths`; `handler` gets batches of events on a background queue until the returned stream is
    /// stopped.
    func watch(
        _ paths: [String], latency: TimeInterval, handler: @escaping @Sendable ([FileEvent]) -> Void
    ) -> any FileEventSubscription
}

protocol FileEventSubscription: AnyObject, Sendable {
    func stop()
}

/// FSEvents with file-level events. The stream runs on its own serial queue; event paths are handed on as untrusted
/// strings (`FileChangeClassifier` only compares them with verified folders).
struct LiveFileEventWatcher: FileEventWatching {
    static let live = LiveFileEventWatcher()

    func watch(
        _ paths: [String], latency: TimeInterval, handler: @escaping @Sendable ([FileEvent]) -> Void
    ) -> any FileEventSubscription {
        FSEventsSubscription(paths: paths, latency: latency, handler: handler)
    }
}

/// What the C callback reaches through the stream's `info` pointer. The stream retains it (the context's retain and
/// release callbacks), so a callback already queued when `stop()` runs still finds it alive; once stopped it delivers
/// nothing (security review of #119: no use after free).
private final class FSEventsHandlerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var isStopped = false
    private let handler: @Sendable ([FileEvent]) -> Void

    init(_ handler: @escaping @Sendable ([FileEvent]) -> Void) { self.handler = handler }

    func stop() { lock.withLock { isStopped = true } }

    func deliver(_ events: [FileEvent]) {
        guard !lock.withLock({ isStopped }) else { return }
        handler(events)
    }
}

final class FSEventsSubscription: FileEventSubscription, @unchecked Sendable {
    private let lock = NSLock()
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "overgrove.fsevents")
    private let box: FSEventsHandlerBox

    init(paths: [String], latency: TimeInterval, handler: @escaping @Sendable ([FileEvent]) -> Void) {
        box = FSEventsHandlerBox(handler)
        guard !paths.isEmpty else { return }
        var context = FSEventStreamContext(
            version: 0, info: Unmanaged.passUnretained(box).toOpaque(),
            retain: { info in
                guard let info else { return nil }
                _ = Unmanaged<FSEventsHandlerBox>.fromOpaque(info).retain()
                return info
            },
            release: { info in
                guard let info else { return }
                Unmanaged<FSEventsHandlerBox>.fromOpaque(info).release()
            },
            copyDescription: nil)
        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagWatchRoot)
        guard
            let created = FSEventStreamCreate(
                kCFAllocatorDefault, fsEventsCallback, &context, paths as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
        else { return }
        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            return
        }
        stream = created
    }

    func stop() {
        box.stop()
        let current = lock.withLock {
            defer { stream = nil }
            return stream
        }
        guard let current else { return }
        FSEventStreamStop(current)
        FSEventStreamInvalidate(current)
        FSEventStreamRelease(current)
    }

    deinit { stop() }
}

/// C callback: turns the CFArray of paths and the flags into `FileEvent`s.
private func fsEventsCallback(
    _ stream: ConstFSEventStreamRef, _ info: UnsafeMutableRawPointer?, _ count: Int,
    _ paths: UnsafeMutableRawPointer, _ flags: UnsafePointer<FSEventStreamEventFlags>,
    _ ids: UnsafePointer<FSEventStreamEventId>
) {
    guard let info else { return }
    let box = Unmanaged<FSEventsHandlerBox>.fromOpaque(info).takeUnretainedValue()
    let array = Unmanaged<CFArray>.fromOpaque(paths).takeUnretainedValue() as NSArray
    let rescan = FSEventStreamEventFlags(
        kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagRootChanged)
    var events: [FileEvent] = []
    events.reserveCapacity(count)
    for index in 0..<count {
        guard let path = array[index] as? String else { continue }
        events.append(FileEvent(path: path, needsRescan: flags[index] & rescan != 0))
    }
    box.deliver(events)
}
