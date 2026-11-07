import Foundation
import XCTest

@testable import Overgrove

/// Stands in for `Task.sleep`: every wait blocks until the test releases it, and records the requested duration.
final class TickGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Error>] = []
    private var durations: [Duration] = []

    var requested: [Duration] { lock.withLock { durations } }
    var pending: Int { lock.withLock { waiting.count } }

    func sleep(_ duration: Duration) async throws {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.withLock {
                    durations.append(duration)
                    waiting.append(continuation)
                }
            }
        } onCancel: {
            let all = lock.withLock {
                defer { waiting.removeAll() }
                return waiting
            }
            for continuation in all { continuation.resume(throwing: CancellationError()) }
        }
    }

    /// Ends the oldest wait, as if one interval had passed.
    func tick() {
        let next = lock.withLock { waiting.isEmpty ? nil : waiting.removeFirst() }
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

/// Auto fetch (#79): off by default, every interval while the window is active, never on top of a fetch, a
/// bounded catch-up on activation, and quiet results.
@MainActor
final class AutoFetchSchedulerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var clock = Date(timeIntervalSince1970: 1_767_225_600)

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private let repository = Repository(
        rootURL: URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true),
        commonGitDirectoryURL: URL(fileURLWithPath: "/tmp/dev/api/.git", isDirectory: true), isBare: false)

    private func make() -> (AutoFetchScheduler, AppSettings, FetchController, GatedFetcher, TickGate) {
        let settings = AppSettings(defaults: defaults)
        let fetcher = GatedFetcher()
        let fetch = FetchController(fetcher: fetcher, store: FetchRecordStore(defaults: defaults))
        fetch.open(repository)
        let gate = TickGate()
        let scheduler = AutoFetchScheduler(
            settings: settings, fetch: fetch, sleep: { try await gate.sleep($0) }, now: { [unowned self] in clock })
        return (scheduler, settings, fetch, fetcher, gate)
    }

    func testOffByDefault() async {
        let (scheduler, settings, fetch, fetcher, gate) = make()
        XCTAssertFalse(settings.autoFetch)
        scheduler.update()
        scheduler.windowActivityChanged(isActive: true)
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(gate.pending, 0, "no timer while off")
        XCTAssertEqual(fetcher.count, 0)
        XCTAssertFalse(fetch.status.isFetching)
    }

    func testFetchesEveryIntervalWhileActive() async {
        let (scheduler, settings, fetch, fetcher, gate) = make()
        settings.autoFetch = true
        scheduler.windowActivityChanged(isActive: true)  // never fetched: catch-up starts one at once
        await fetcher.waitForFetches(1)
        XCTAssertTrue(fetch.isAutomaticRun)
        fetcher.release(0, with: .finished(failures: []))
        await fetch.task?.value

        scheduler.update()
        await gate.waitForSleepers(1)
        XCTAssertEqual(gate.requested.first, .seconds(600), "10 minutes by default")
        gate.tick()
        await fetcher.waitForFetches(2)
        XCTAssertTrue(fetch.isAutomaticRun, "marked automatic, so it ends quietly")
        fetcher.release(1, with: .finished(failures: []))
        await fetch.task?.value
        scheduler.stop()
    }

    func testInactiveWindowAndRunningFetchAreSkipped() async {
        let (scheduler, settings, fetch, fetcher, gate) = make()
        settings.autoFetch = true
        scheduler.update()
        scheduler.windowActivityChanged(isActive: false)
        await gate.waitForSleepers(1)
        gate.tick()
        await gate.waitForSleepers(1)
        XCTAssertEqual(fetcher.count, 0, "inactive window: skipped")

        fetch.fetch()  // a manual fetch is running
        await fetcher.waitForFetches(1)
        XCTAssertFalse(fetch.isAutomaticRun)
        scheduler.windowActivityChanged(isActive: true)
        gate.tick()
        await gate.waitForSleepers(1)
        XCTAssertEqual(fetcher.count, 1, "never on top of a running fetch")
        fetcher.release(0, with: .finished(failures: []))
        await fetch.task?.value
        scheduler.stop()
    }

    /// Coming back after a long time fetches once; switching windows again within the interval does not, even when
    /// the fetch failed (a failing remote is not retried on every switch).
    func testActivationCatchUpIsBounded() async {
        let (scheduler, settings, fetch, fetcher, _) = make()
        settings.autoFetch = true
        scheduler.windowActivityChanged(isActive: true)
        await fetcher.waitForFetches(1)
        let stderr = MaskedText(masking: "fatal: unable to access")
        let failure = FetchFailureGuidance(
            error: .networkUnavailable(detail: stderr), remote: RemoteName("origin")!,
            report: RepoSecurityReport(findings: [], blockingReason: nil))!
        fetcher.release(0, with: .finished(failures: [failure]))
        await fetch.task?.value
        XCTAssertEqual(fetch.status, .failed(lastFetched: nil), "the result stays in the status bar")

        clock = clock.addingTimeInterval(120)
        scheduler.windowActivityChanged(isActive: false)
        scheduler.windowActivityChanged(isActive: true)
        XCTAssertEqual(fetcher.count, 1, "within one interval of the last attempt")

        clock = clock.addingTimeInterval(600)
        scheduler.windowActivityChanged(isActive: true)
        await fetcher.waitForFetches(2)
        fetcher.release(1, with: .finished(failures: []))
        await fetch.task?.value
    }

    func testIntervalChangeRestartsAndOffStops() async {
        let (scheduler, settings, _, _, gate) = make()
        settings.autoFetch = true
        scheduler.update()
        await gate.waitForSleepers(1)
        settings.autoFetchIntervalMinutes = 30
        scheduler.update()
        await gate.waitForSleepers(1)
        XCTAssertEqual(gate.requested.last, .seconds(1_800))

        settings.autoFetch = false
        scheduler.update()
        for _ in 0..<5 { await Task.yield() }
        XCTAssertEqual(gate.pending, 0, "turning it off stops the timer")
    }

    func testNoRepositoryNoFetch() async {
        let (scheduler, settings, fetch, fetcher, gate) = make()
        settings.autoFetch = true
        fetch.open(nil)
        scheduler.update()
        scheduler.windowActivityChanged(isActive: true)
        await gate.waitForSleepers(1)
        gate.tick()
        await gate.waitForSleepers(1)
        XCTAssertEqual(fetcher.count, 0)
        scheduler.stop()
    }
}
