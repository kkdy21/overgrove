import Foundation

/// Auto refresh while the window is visible (#119, decision in #163): watches the repository's verified worktrees
/// and shared git directory, and re-queries only what changed.
///
/// - Events arrive at most every `latency` (FSEvents coalesces them). Changes are batched for `debounce` after the
///   last event, then sent as one `.filesChanged` request (#88 triggers): only the changed worktrees' statuses, plus
///   the refs or the worktree list if they changed. While events keep coming (an agent writing files), a request
///   still goes out at most `maximumWait` after the first pending change, so the window does not wait for quiet.
/// - One request at a time. Events that arrive while it runs are kept and sent once afterwards.
/// - Re-run gap: the next request starts no earlier than `max(minimumGap, last duration × gapFactor)` after the last
///   one started, so even a 5 s status (a large repository with a stale index) runs at most every 50 s, about 10 % of
///   one core (#163).
/// - Only while the window is visible (`NSWindow.occlusionState`): hidden or minimized, the stream stops and costs
///   nothing; when it becomes visible again, one refresh (`onReappear`).
/// - A request superseded by another load (a selection, ⌘R) is kept and sent again later.
@MainActor
final class AutoRefreshController {
    static let latency: TimeInterval = 1
    static let debounce: Duration = .seconds(1)
    static let maximumWait: Duration = .seconds(5)
    static let minimumGap: Duration = .seconds(2)
    static let gapFactor = 10

    /// Sends a request; `true` when it was started (no other load was running).
    var request: (FileChangeSet) -> Bool = { _ in false }
    /// The window became visible again after being hidden: refresh once.
    var onReappear: () -> Void = {}

    private let watcher: any FileEventWatching
    private let sleep: @Sendable (Duration) async throws -> Void
    private let clock: () -> ContinuousClock.Instant

    private var classifier: FileChangeClassifier?
    private var subscription: (any FileEventSubscription)?
    private(set) var isVisible = false
    private var wasHidden = false
    private(set) var pending = FileChangeSet()
    private var inFlight: FileChangeSet?
    private var lastStart: ContinuousClock.Instant?
    private var lastDuration: Duration = .zero
    private var lastEvent: ContinuousClock.Instant?
    /// When the oldest change still pending arrived (for `maximumWait`).
    private var firstPending: ContinuousClock.Instant?
    private var timer: Task<Void, Never>?
    /// Requests sent; tests and PERF read it.
    private(set) var requestCount = 0

    init(
        watcher: any FileEventWatching = LiveFileEventWatcher.live,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        clock: @escaping () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.watcher = watcher
        self.sleep = sleep
        self.clock = clock
    }

    var isWatching: Bool { subscription != nil }

    /// The verified worktrees changed (a load finished) or the repository closed (`nil`).
    func update(_ classifier: FileChangeClassifier?) {
        guard classifier != self.classifier else { return }
        self.classifier = classifier
        if classifier == nil {
            pending = FileChangeSet()
            firstPending = nil
        }
        restartStream()
    }

    /// `NSWindow.occlusionState` changed (or the window closed: `false`).
    func setVisible(_ visible: Bool) {
        guard visible != isVisible else { return }
        isVisible = visible
        if !visible {
            wasHidden = true
            timer?.cancel()
            timer = nil
        }
        restartStream()
        if visible, wasHidden, classifier != nil {
            wasHidden = false
            // What changed while hidden was not watched: one refresh brings it up to date.
            pending = FileChangeSet()
            firstPending = nil
            onReappear()
        }
    }

    /// Batches from the stream (any thread); classified on the main actor.
    nonisolated func receive(_ events: [FileEvent]) {
        Task { @MainActor in self.handle(events) }
    }

    func handle(_ events: [FileEvent]) {
        guard isVisible, let classifier else { return }
        let change = classifier.classify(events)
        guard !change.isEmpty else { return }
        if pending.isEmpty { firstPending = clock() }
        pending.merge(change)
        lastEvent = clock()
        schedule()
    }

    /// A load ended. `trigger` is what that load was for; `succeeded` is false when it was superseded or failed.
    func loadFinished(_ trigger: RepositoryService.Trigger, succeeded: Bool) {
        if let sent = inFlight, case .filesChanged = trigger {
            inFlight = nil
            if let lastStart { lastDuration = clock() - lastStart }
            if !succeeded { requeue(sent) }
        }
        // Whatever load ended, changes that waited for it can go now.
        schedule()
    }

    /// Our request was replaced by another load before it finished (AppState starts a new one).
    func requestSuperseded() {
        guard let sent = inFlight else { return }
        inFlight = nil
        requeue(sent)
    }

    private func requeue(_ change: FileChangeSet) {
        if pending.isEmpty { firstPending = clock() }
        pending.merge(change)
    }

    private func restartStream() {
        subscription?.stop()
        subscription = nil
        guard isVisible, let classifier, !classifier.watchedPaths.isEmpty else { return }
        let paths = classifier.watchedPaths
        subscription = watcher.watch(paths, latency: Self.latency) { [weak self] events in
            self?.receive(events)
        }
    }

    /// The earliest time the next request may start: after the debounce (or `maximumWait` since the first pending
    /// change, whichever is sooner) and after the re-run gap.
    private var nextAllowedStart: ContinuousClock.Instant {
        var afterEvents = (lastEvent ?? clock()) + Self.debounce
        if let firstPending { afterEvents = min(afterEvents, firstPending + Self.maximumWait) }
        guard let lastStart else { return afterEvents }
        let gap = max(Self.minimumGap, lastDuration * Self.gapFactor)
        return max(afterEvents, lastStart + gap)
    }

    private func schedule() {
        guard isVisible, !pending.isEmpty, inFlight == nil else { return }
        timer?.cancel()
        let wait = max(.zero, nextAllowedStart - clock())
        let sleep = sleep
        timer = Task { [weak self] in
            do { try await sleep(wait) } catch { return }
            guard !Task.isCancelled else { return }
            self?.fire()
        }
    }

    private func fire() {
        timer = nil
        guard isVisible, !pending.isEmpty, inFlight == nil else { return }
        // Events kept coming during the wait: wait for the batch to settle.
        if nextAllowedStart > clock() { return schedule() }
        let change = pending
        guard request(change) else {
            // Another load is running; `loadFinished` schedules again when it ends.
            return
        }
        pending = FileChangeSet()
        firstPending = nil
        inFlight = change
        lastStart = clock()
        requestCount += 1
    }
}
