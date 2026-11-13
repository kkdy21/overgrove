import Foundation
import XCTest

@testable import Overgrove

/// Records what the controller watches and lets the test deliver events.
final class FakeFileWatcher: FileEventWatching, @unchecked Sendable {
    final class Subscription: FileEventSubscription, @unchecked Sendable {
        private let lock = NSLock()
        private var stopped = false
        /// Events the stream still holds: `stop()` flushes them through the handler first, as FSEvents does.
        var undelivered: [FileEvent] = []
        var handler: (@Sendable ([FileEvent]) -> Void)?
        var isStopped: Bool { lock.withLock { stopped } }
        func stop() {
            let flushed: [FileEvent] = lock.withLock {
                guard !stopped else { return [] }
                stopped = true
                defer { undelivered = [] }
                return undelivered
            }
            if !flushed.isEmpty { handler?(flushed) }
        }
    }

    private let lock = NSLock()
    private var watches:
        [(
            paths: [String], since: FileEventID?, subscription: Subscription,
            handler: @Sendable ([FileEvent]) -> Void
        )] = []
    private var eventID: FileEventID = 1

    var watchedPaths: [[String]] { lock.withLock { watches.map(\.paths) } }
    var startIDs: [FileEventID?] { lock.withLock { watches.map(\.since) } }
    var activeCount: Int { lock.withLock { watches.filter { !$0.subscription.isStopped }.count } }
    var latest: Subscription? { lock.withLock { watches.last?.subscription } }

    var currentEventID: FileEventID {
        get { lock.withLock { eventID } }
        set { lock.withLock { eventID = newValue } }
    }

    func watch(
        _ paths: [String], since: FileEventID?, latency: TimeInterval,
        handler: @escaping @Sendable ([FileEvent]) -> Void
    ) -> any FileEventSubscription {
        let subscription = Subscription()
        subscription.handler = handler
        lock.withLock { watches.append((paths, since, subscription, handler)) }
        return subscription
    }

    /// Delivers a batch through the latest stream's handler, as FSEvents would on its own queue.
    func deliver(_ events: [FileEvent]) {
        let handler = lock.withLock { watches.last?.handler }
        handler?(events)
    }
}

/// Stands in for `Task.sleep`: each wait blocks until `tick()`, and records the requested duration. Cancelling the
/// waiting task ends its wait.
final class SleepGate: @unchecked Sendable {
    private let lock = NSLock()
    /// Waits in order, each with its own id so a cancelled task ends only its own wait.
    private var waiting: [(id: UUID, continuation: CheckedContinuation<Void, Error>)] = []
    private var cancelled: Set<UUID> = []
    private var durations: [Duration] = []

    var requested: [Duration] { lock.withLock { durations } }
    var pending: Int { lock.withLock { waiting.count } }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let isCancelled = lock.withLock {
                    if cancelled.remove(id) != nil { return true }
                    durations.append(duration)
                    waiting.append((id, continuation))
                    return false
                }
                if isCancelled { continuation.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            let own: CheckedContinuation<Void, Error>? = lock.withLock {
                guard let index = waiting.firstIndex(where: { $0.id == id }) else {
                    cancelled.insert(id)  // cancelled before it parked
                    return nil
                }
                return waiting.remove(at: index).continuation
            }
            own?.resume(throwing: CancellationError())
        }
    }

    /// Ends the oldest wait, as if its interval had passed.
    func tick() {
        let next = lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst().continuation }
        next?.resume()
    }

    func waitForSleepers(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while pending < count {
            guard ContinuousClock.now < deadline else {
                return XCTFail("expected \(count) waiting sleeps, got \(pending)", file: file, line: line)
            }
            await Task.yield()
        }
    }
}

/// A clock the test moves by hand.
final class ManualInstantClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ContinuousClock.now
    func now() -> ContinuousClock.Instant { lock.withLock { current } }
    func advance(_ duration: Duration) { lock.withLock { current += duration } }
}

/// `AutoRefreshController` (#119, #163): batching, one request at a time, the re-run gap, and visibility.
@MainActor
final class AutoRefreshControllerTests: XCTestCase {
    private let main = GitPath("/dev/api")
    private let lane = GitPath("/dev/api-wt/lane")

    private var classifier: FileChangeClassifier {
        FileChangeClassifier(
            commonDirectory: "/dev/api/.git",
            worktrees: [
                .init(path: main, folder: "/dev/api", gitDirectory: "/dev/api/.git"),
                .init(path: lane, folder: "/dev/api-wt/lane", gitDirectory: "/dev/api/.git/worktrees/lane"),
            ])
    }

    private struct Harness {
        let controller: AutoRefreshController
        let watcher: FakeFileWatcher
        let clock: ManualInstantClock
        let gate: SleepGate
        let requests: Requests
    }

    /// The requests the controller sent, and whether the next one is accepted.
    final class Requests {
        var sent: [FileChangeSet] = []
        var accepts = true
    }

    private func make() -> Harness {
        let watcher = FakeFileWatcher()
        let clock = ManualInstantClock()
        let gate = SleepGate()
        let controller = AutoRefreshController(
            watcher: watcher, sleep: { try await gate.sleep($0) }, clock: { clock.now() })
        let requests = Requests()
        controller.request = { change in
            guard requests.accepts else { return false }
            requests.sent.append(change)
            return true
        }
        return Harness(controller: controller, watcher: watcher, clock: clock, gate: gate, requests: requests)
    }

    private func event(_ path: String) -> [FileEvent] { [FileEvent(path: path)] }

    /// Waits until `condition` holds (the timer task runs on its own schedule), failing after 5 s.
    private func waitUntil(
        _ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line
    ) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("condition not met", file: file, line: line) }
            await Task.yield()
        }
    }

    func testWatchesOnlyWhileVisibleWithARepository() {
        let h = make()
        h.controller.update(classifier)
        XCTAssertFalse(h.controller.isWatching, "not visible yet")
        h.controller.setVisible(true)
        XCTAssertTrue(h.controller.isWatching)
        XCTAssertEqual(h.watcher.watchedPaths.last, classifier.watchedPaths)
        h.controller.setVisible(false)
        XCTAssertFalse(h.controller.isWatching, "hidden or minimized: the stream stops")
        XCTAssertEqual(h.watcher.activeCount, 0)
        h.controller.setVisible(true)
        h.controller.update(nil)
        XCTAssertFalse(h.controller.isWatching, "repository closed")
    }

    /// Events the old stream still held when the watched worktrees changed are not lost (#422): stopping flushes them
    /// through the old stream's handler, and they are applied before the new stream starts.
    func testEventsTheOldStreamHeldSurviveARestart() {
        let h = make()
        h.controller.update(classifier)
        h.controller.setVisible(true)
        h.watcher.latest?.undelivered = event("/dev/api-wt/lane/b.swift")
        let more = FileChangeClassifier(
            commonDirectory: "/dev/api/.git",
            worktrees: classifier.worktrees + [
                .init(
                    path: GitPath("/dev/api-wt/new"), folder: "/dev/api-wt/new",
                    gitDirectory: "/dev/api/.git/worktrees/new")
            ])

        h.controller.update(more)

        XCTAssertEqual(h.watcher.activeCount, 1)
        XCTAssertEqual(h.controller.pending, FileChangeSet(worktrees: [lane]))
    }

    /// The new stream starts where the old one stopped, not "since now" (#422): what changed between the two (a new
    /// worktree's last index write) is replayed to it.
    func testRestartedStreamStartsWhereTheOldOneStopped() {
        let h = make()
        h.controller.update(classifier)
        h.controller.setVisible(true)
        h.watcher.currentEventID = 42
        h.controller.update(
            FileChangeClassifier(commonDirectory: "/dev/api/.git", worktrees: Array(classifier.worktrees.prefix(1))))
        XCTAssertEqual(h.watcher.startIDs, [nil, 42], "the first stream starts now; the restart resumes at 42")

        // Shown again after being hidden: everything is pending anyway, so the stream starts now.
        h.controller.setVisible(false)
        h.controller.setVisible(true)
        XCTAssertEqual(h.watcher.startIDs.last, .some(nil))
    }

    func testEventsAreBatchedIntoOneRequest() async {
        let h = make()
        h.controller.update(classifier)
        h.controller.setVisible(true)
        h.controller.handle(event("/dev/api/a.swift"))
        h.controller.handle(event("/dev/api-wt/lane/b.swift"))
        h.controller.handle(event("/dev/api/.git/objects/ab/cd"))  // ignored
        await h.gate.waitForSleepers(1)
        XCTAssertEqual(h.gate.requested.last, .seconds(1), "1 s debounce after the last event")
        h.clock.advance(.seconds(1))
        h.gate.tick()
        await waitUntil { !h.requests.sent.isEmpty }
        XCTAssertEqual(h.requests.sent, [FileChangeSet(worktrees: [main, lane])])
    }

    /// One request at a time; what arrives meanwhile is sent once afterwards, no earlier than the re-run gap.
    func testOneAtATimeWithTheReRunGap() async {
        let h = make()
        h.controller.update(classifier)
        h.controller.setVisible(true)
        h.controller.handle(event("/dev/api/a"))
        await h.gate.waitForSleepers(1)
        h.clock.advance(.seconds(1))
        h.gate.tick()
        await waitUntil { h.requests.sent.count == 1 }

        // A storm while the first request runs (5 s, like a large repository with a stale index).
        for index in 0..<500 { h.controller.handle(event("/dev/api/node_modules/f\(index)")) }
        XCTAssertEqual(h.gate.pending, 0, "nothing scheduled while one runs")
        h.clock.advance(.seconds(5))
        h.controller.loadFinished(
            .filesChanged(worktrees: [main], refs: false, worktreeList: false), outcome: .succeeded)
        await h.gate.waitForSleepers(1)
        // Gap: max(2 s, 5 s × 10) = 50 s after the first start, which was 5 s ago.
        XCTAssertEqual(h.gate.requested.last, .seconds(45))
        h.clock.advance(.seconds(45))
        h.gate.tick()
        await waitUntil { h.requests.sent.count == 2 }
        XCTAssertEqual(h.requests.sent.count, 2, "500 events became one more request")
        XCTAssertEqual(h.requests.sent.last, FileChangeSet(worktrees: [main]))
    }

    /// Continuous events (an agent writing files) do not postpone the refresh forever: at most 5 s after the first.
    func testContinuousEventsStillRefreshWithinTheMaximumWait() async {
        let h = make()
        h.controller.update(classifier)
        h.controller.setVisible(true)
        for _ in 0..<8 {
            h.controller.handle(event("/dev/api/build/out.o"))
            h.clock.advance(.milliseconds(700))
        }
        // Events every 0.7 s: the last one, at 4.9 s, would push the debounce to 5.9 s; the 5 s maximum wait wins.
        await h.gate.waitForSleepers(1)
        XCTAssertEqual(h.gate.requested.last, .milliseconds(100))
        h.gate.tick()
        await waitUntil { h.requests.sent.count == 1 }
    }

    func testSupersededOrRefusedRequestsAreSentAgain() async {
        let h = make()
        h.controller.update(classifier)
        h.controller.setVisible(true)
        h.requests.accepts = false  // another load is running
        h.controller.handle(event("/dev/api-wt/lane/x"))
        await h.gate.waitForSleepers(1)
        h.clock.advance(.seconds(1))
        h.gate.tick()
        await waitUntil { h.gate.pending == 0 }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(h.requests.sent, [])
        XCTAssertEqual(h.controller.pending, FileChangeSet(worktrees: [lane]), "kept")

        h.requests.accepts = true
        h.controller.loadFinished(.user, outcome: .succeeded)  // the other load ended
        await h.gate.waitForSleepers(1)
        h.gate.tick()
        await waitUntil { !h.requests.sent.isEmpty }
        XCTAssertEqual(h.requests.sent, [FileChangeSet(worktrees: [lane])])

        // A selection replaces it before it finishes: the changes come back.
        h.controller.requestSuperseded()
        XCTAssertEqual(h.controller.pending, FileChangeSet(worktrees: [lane]))
    }

    /// Hidden: nothing is watched. Visible again: everything is pending once, through the debounce and the gap, so
    /// flipping visibility cannot stack refreshes.
    func testHiddenEventsAreIgnoredAndReappearingRefreshesOnce() async {
        let h = make()
        h.controller.update(classifier)
        h.controller.setVisible(true)
        XCTAssertTrue(h.controller.pending.isEmpty, "the first appearance is the initial load")
        h.controller.setVisible(false)
        h.controller.handle(event("/dev/api/a"))
        XCTAssertTrue(h.controller.pending.isEmpty, "nothing is watched while hidden")
        h.controller.setVisible(true)
        h.controller.setVisible(true)
        XCTAssertEqual(h.controller.pending, classifier.everything)
        for _ in 0..<5 {
            h.controller.setVisible(false)
            h.controller.setVisible(true)
        }
        await h.gate.waitForSleepers(1)
        h.clock.advance(.seconds(1))
        h.gate.tick()
        await waitUntil { h.requests.sent.count == 1 }
        XCTAssertEqual(h.requests.sent, [classifier.everything], "six reappearances, one request")
    }

    /// #425: a window reported hidden before it was ever shown (launched on another Space or behind other windows)
    /// catches up when it appears, like one hidden later. A window simply not reported yet does not (the test above).
    func testAWindowThatStartsHiddenCatchesUpWhenShown() {
        let h = make()
        h.controller.setVisible(false)
        h.controller.update(classifier)
        h.controller.handle(event("/dev/api/a"))
        XCTAssertTrue(h.controller.pending.isEmpty, "nothing is watched while hidden")
        h.controller.setVisible(true)
        XCTAssertEqual(h.controller.pending, classifier.everything, "what changed while hidden is queued once")
    }

    /// #425: opening another repository while the window is hidden keeps the catch-up for when it appears.
    func testARepositoryOpenedWhileHiddenCatchesUpWhenShown() {
        let h = make()
        h.controller.update(classifier)
        h.controller.setVisible(true)
        h.controller.setVisible(false)
        h.controller.update(nil)
        h.controller.update(classifier)
        h.controller.setVisible(true)
        XCTAssertEqual(h.controller.pending, classifier.everything)
    }

    /// A window not reported yet is not hidden: switching repositories before it first appears queues nothing extra.
    func testARepositoryOpenedBeforeTheWindowIsReportedQueuesNothing() {
        let h = make()
        h.controller.update(classifier)
        h.controller.update(nil)
        h.controller.update(classifier)
        h.controller.setVisible(true)
        XCTAssertTrue(h.controller.pending.isEmpty, "the first appearance follows the first load")
    }

    /// Opening another repository while the window is shown needs no catch-up: its own first load reads everything.
    func testARepositoryOpenedWhileShownQueuesNothing() {
        let h = make()
        h.controller.update(classifier)
        h.controller.setVisible(true)
        h.controller.update(nil)
        h.controller.update(classifier)
        XCTAssertTrue(h.controller.pending.isEmpty)
    }

    /// Security review of #119: closing the repository while a request runs must not leave it in flight forever (its
    /// load never reports back once the generation moved on).
    func testClosingTheRepositoryClearsTheRequestInFlight() async {
        let h = make()
        h.controller.update(classifier)
        h.controller.setVisible(true)
        h.controller.handle(event("/dev/api/a"))
        await h.gate.waitForSleepers(1)
        h.clock.advance(.seconds(1))
        h.gate.tick()
        await waitUntil { h.requests.sent.count == 1 }

        h.controller.update(nil)  // closed; the running load is dropped without `loadFinished`
        h.controller.update(classifier)
        h.controller.handle(event("/dev/api-wt/lane/b"))
        await h.gate.waitForSleepers(1)
        XCTAssertEqual(h.gate.requested.last, .seconds(1), "no gap carried over from the old repository")
        h.clock.advance(.seconds(1))
        h.gate.tick()
        await waitUntil { h.requests.sent.count == 2 }
        XCTAssertEqual(h.requests.sent.last, FileChangeSet(worktrees: [lane]))
    }

    /// A failed request is dropped, not retried every gap (a repository that keeps failing would be re-queried
    /// forever); a superseded one comes back.
    func testFailedRequestsAreDroppedAndSupersededOnesKept() async {
        let h = make()
        h.controller.update(classifier)
        h.controller.setVisible(true)
        h.controller.handle(event("/dev/api/a"))
        await h.gate.waitForSleepers(1)
        h.clock.advance(.seconds(1))
        h.gate.tick()
        await waitUntil { h.requests.sent.count == 1 }
        h.controller.loadFinished(
            .filesChanged(worktrees: [main], refs: false, worktreeList: false), outcome: .failed)
        XCTAssertTrue(h.controller.pending.isEmpty)
        XCTAssertEqual(h.gate.pending, 0, "nothing scheduled")

        h.controller.handle(event("/dev/api/b"))
        await h.gate.waitForSleepers(1)
        h.clock.advance(.seconds(2))
        h.gate.tick()
        await waitUntil { h.requests.sent.count == 2 }
        h.controller.loadFinished(
            .filesChanged(worktrees: [main], refs: false, worktreeList: false), outcome: .superseded)
        XCTAssertEqual(h.controller.pending, FileChangeSet(worktrees: [main]))
    }

    /// The live path: the stream's handler classifies off the main actor, and a burst of batches reaches the main
    /// actor merged (T15, SEC-T15-17).
    func testStreamBatchesAreClassifiedOffTheMainActorAndMerged() async {
        let h = make()
        h.controller.update(classifier)
        h.controller.setVisible(true)
        let watcher = h.watcher
        await Task.detached {
            for index in 0..<200 { watcher.deliver([FileEvent(path: "/dev/api/node_modules/f\(index)")]) }
            watcher.deliver([FileEvent(path: "/dev/api-wt/lane/x")])
            watcher.deliver([FileEvent(path: "/dev/api/.git/objects/ab/cd")])
        }.value
        await waitUntil { h.controller.pending == FileChangeSet(worktrees: [main, lane]) }
        await h.gate.waitForSleepers(1)
        h.clock.advance(.seconds(1))
        h.gate.tick()
        await waitUntil { h.requests.sent.count == 1 }
        XCTAssertEqual(h.requests.sent, [FileChangeSet(worktrees: [main, lane])])

        // A stopped stream's late batch is ignored.
        h.controller.update(nil)
        watcher.deliver([FileEvent(path: "/dev/api/late")])
        for _ in 0..<20 { await Task.yield() }
        XCTAssertTrue(h.controller.pending.isEmpty)
    }
}
