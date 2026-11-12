import CoreServices
import Foundation

/// Watches folders and reports file events (auto refresh, #119). The live version is FSEvents (CoreServices, part of
/// macOS: no dependency); tests pass their own.
protocol FileEventWatching: Sendable {
    /// The system's latest event ID: a stream started `since` it misses nothing that happens afterwards (#422).
    var currentEventID: FileEventID { get }

    /// Starts watching `paths`; `handler` gets batches of events on a background queue until the returned stream is
    /// stopped. With `since`, events after that ID are replayed first; without it, the stream starts now.
    func watch(
        _ paths: [String], since: FileEventID?, latency: TimeInterval,
        handler: @escaping @Sendable ([FileEvent]) -> Void
    ) -> any FileEventSubscription
}

extension FileEventWatching {
    func watch(
        _ paths: [String], latency: TimeInterval, handler: @escaping @Sendable ([FileEvent]) -> Void
    ) -> any FileEventSubscription {
        watch(paths, since: nil, latency: latency, handler: handler)
    }
}

/// An FSEvents event ID (`FSEventStreamEventId`).
typealias FileEventID = UInt64

protocol FileEventSubscription: AnyObject, Sendable {
    /// Delivers the events the stream still holds through its handler, then stops it (#422). Nothing is delivered
    /// after it returns.
    func stop()
}

/// FSEvents with file-level events. The stream runs on its own serial queue; event paths are handed on as untrusted
/// strings (`FileChangeClassifier` only compares them with verified folders).
struct LiveFileEventWatcher: FileEventWatching {
    static let live = LiveFileEventWatcher()

    var currentEventID: FileEventID { FSEventsGetCurrentEventId() }

    func watch(
        _ paths: [String], since: FileEventID?, latency: TimeInterval,
        handler: @escaping @Sendable ([FileEvent]) -> Void
    ) -> any FileEventSubscription {
        FSEventsSubscription(paths: paths, since: since, latency: latency, handler: handler)
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

    init(
        paths: [String], since: FileEventID? = nil, latency: TimeInterval,
        handler: @escaping @Sendable ([FileEvent]) -> Void
    ) {
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
                since ?? FSEventStreamEventId(kFSEventStreamEventIdSinceNow), latency, flags)
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
        let current = lock.withLock {
            defer { stream = nil }
            return stream
        }
        guard let current else { return box.stop() }
        // Events FSEvents holds for the latency are delivered now, on the stream's queue, before this returns (#422).
        FSEventStreamFlushSync(current)
        box.stop()
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
    let historyDone = FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone)
    var events: [FileEvent] = []
    events.reserveCapacity(count)
    for index in 0..<count {
        // The marker after a replay (`since`) names no changed file.
        guard flags[index] & historyDone == 0, let path = array[index] as? String else { continue }
        events.append(FileEvent(path: path, needsRescan: flags[index] & rescan != 0))
    }
    box.deliver(events)
}
