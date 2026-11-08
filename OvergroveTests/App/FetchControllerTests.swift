import Foundation
import XCTest

@testable import Overgrove

/// Holds every fetch until the test releases it; reports the remotes through `onStart` when asked.
final class GatedFetcher: RepositoryFetching, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [(Repository, @Sendable ([String]) -> Void, CheckedContinuation<FetchRun, Never>)] = []
    private var untrustedFlags: [Bool] = []

    var count: Int { lock.withLock { waiting.count } }
    /// The `untrusted` argument of each fetch, in order (#107).
    var untrusted: [Bool] { lock.withLock { untrustedFlags } }

    func fetch(
        _ repository: Repository, untrusted readUntrusted: @escaping @Sendable () async -> Bool,
        onStart: @escaping @Sendable ([String]) -> Void
    ) async -> FetchRun {
        let untrusted = await readUntrusted()
        return await withCheckedContinuation { continuation in
            lock.withLock {
                untrustedFlags.append(untrusted)
                waiting.append((repository, onStart, continuation))
            }
        }
    }

    func start(_ index: Int, remotes: [String]) {
        let onStart = lock.withLock { waiting[index].1 }
        onStart(remotes)
    }

    func release(_ index: Int, with run: FetchRun, file: StaticString = #filePath, line: UInt = #line) {
        let continuation = lock.withLock { index < waiting.count ? waiting[index].2 : nil }
        guard let continuation else { return XCTFail("no fetch \(index)", file: file, line: line) }
        continuation.resume(returning: run)
    }

    func waitForFetches(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while self.count < count {
            guard ContinuousClock.now < deadline else {
                return XCTFail("expected \(count) fetches, got \(self.count)", file: file, line: line)
            }
            await Task.yield()
        }
    }
}

/// `FetchController` (#77, interaction.md §4.2): Fetch → Fetching → done / failed / cancelled, the record, and the
/// callback that refreshes ahead/behind.
@MainActor
final class FetchControllerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let start = Date(timeIntervalSince1970: 1_767_225_600)

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

    private func controller(_ fetcher: GatedFetcher) -> (FetchController, FetchRecordStore) {
        let store = FetchRecordStore(defaults: defaults)
        let start = start
        let controller = FetchController(fetcher: fetcher, store: store, now: { start })
        controller.open(repository)
        return (controller, store)
    }

    /// A guidance as `RepositoryService.fetch` produces it.
    private func failure(_ remote: String, _ error: GitError) -> FetchFailureGuidance {
        FetchFailureGuidance(
            error: error, remote: RemoteName(remote)!,
            report: RepoSecurityReport(findings: [], blockingReason: nil), hookExecutables: [])!
    }

    func testSuccessfulFetchIsRecordedAndRefreshes() async {
        let fetcher = GatedFetcher()
        let (controller, store) = controller(fetcher)
        var finished = 0
        controller.onFinished = { finished += 1 }
        XCTAssertEqual(controller.status, .never)
        XCTAssertTrue(controller.canFetch)

        controller.fetch()
        XCTAssertEqual(controller.status, .fetching(remotes: [], since: start, lastFetched: nil))
        await fetcher.waitForFetches(1)
        fetcher.start(0, remotes: ["origin", "upstream"])
        let expected = FetchStatus.fetching(remotes: ["origin", "upstream"], since: start, lastFetched: nil)
        let deadline = ContinuousClock.now + .seconds(5)
        while controller.status != expected, ContinuousClock.now < deadline { await Task.yield() }
        XCTAssertEqual(controller.status, .fetching(remotes: ["origin", "upstream"], since: start, lastFetched: nil))

        controller.fetch()
        XCTAssertEqual(fetcher.count, 1, "a second Fetch while fetching starts nothing")

        fetcher.release(0, with: .finished(failures: []))
        await controller.task?.value
        XCTAssertEqual(controller.status, .idle(lastFetched: start))
        XCTAssertEqual(store.entry(for: repository.id)?.last.succeeded, true)
        XCTAssertEqual(finished, 1, "ahead/behind is refreshed after a fetch")
    }

    /// #107: each fetch (manual or automatic) passes the repository's untrusted flag as it is when the fetch starts.
    func testTheUntrustedFlagIsReadWhenEachFetchStarts() async {
        let fetcher = GatedFetcher()
        let (controller, _) = controller(fetcher)
        var untrusted = false
        controller.isUntrusted = { _ in untrusted }

        controller.fetch()
        await fetcher.waitForFetches(1)
        fetcher.release(0, with: .finished(failures: []))
        while controller.status.isFetching { await Task.yield() }

        untrusted = true
        controller.fetchAutomatically()
        await fetcher.waitForFetches(2)
        XCTAssertEqual(fetcher.untrusted, [false, true])
        fetcher.release(1, with: .finished(failures: []))
    }

    /// SEC-T5-24 (#423): a fetch that started untrusted stays untrusted when the flag later reads false, e.g. the
    /// repository was removed from Settings while the configuration was being inspected.
    func testSECT5_24_AFetchThatStartedUntrustedStaysUntrusted() async {
        let fetcher = GatedFetcher()
        let (controller, _) = controller(fetcher)
        var untrusted = true
        controller.isUntrusted = { _ in untrusted }

        controller.fetch()
        untrusted = false  // removed before the fetch first reads the flag
        await fetcher.waitForFetches(1)
        XCTAssertEqual(fetcher.untrusted, [true])
        fetcher.release(0, with: .finished(failures: []))
    }

    func testFailedFetchKeepsTheLastSuccessAndShowsDetails() async {
        let fetcher = GatedFetcher()
        let (controller, store) = controller(fetcher)
        let earlier = start.addingTimeInterval(-7_200)
        store.save(FetchRecord(repositoryID: repository.id, finishedAt: earlier, succeeded: true, summary: nil))
        controller.open(repository)
        XCTAssertEqual(controller.status, .idle(lastFetched: earlier))

        controller.fetch()
        await fetcher.waitForFetches(1)
        let stderr = MaskedText(masking: "fatal: line one\nremote: \u{1B}[31mred\u{1B}[0m\n")
        let failures = [
            failure("origin", .authenticationFailed(detail: stderr)),
            failure("upstream", .timeout(seconds: 120)),
        ]
        fetcher.release(0, with: .finished(failures: failures))
        await controller.task?.value

        XCTAssertEqual(controller.status, .failed(lastFetched: earlier))
        XCTAssertEqual(controller.failures.map(\.summary), failures.map(\.summary))
        XCTAssertEqual(controller.failures.first?.commands, failures.first?.commands)
        // Masked stderr is escaped line by line: control characters become visible, line breaks stay.
        let detail = try? XCTUnwrap(controller.failures.first?.detail)
        XCTAssertEqual(detail?.split(separator: "\n").count, 2)
        XCTAssertFalse(detail?.contains("\u{1B}") ?? true)
        XCTAssertEqual(store.entry(for: repository.id)?.last.summary, failures[0].summary)
        XCTAssertEqual(store.entry(for: repository.id)?.lastSucceededAt, earlier)

        // The next attempt clears the details.
        controller.fetch()
        XCTAssertEqual(controller.failures, [])
        await fetcher.waitForFetches(2)
        fetcher.release(1, with: .finished(failures: []))
        await controller.task?.value
    }

    /// #259: skipped remotes are reported, and the next fetch clears the notice.
    func testRemoteLimitIsShownUntilTheNextFetch() async {
        let fetcher = GatedFetcher()
        let (controller, _) = controller(fetcher)
        controller.fetch()
        await fetcher.waitForFetches(1)
        let limit = FetchRemoteLimit(fetched: 16, total: 40)
        fetcher.release(0, with: .finished(failures: [], remoteLimit: limit))
        await controller.task?.value
        XCTAssertEqual(controller.status, .idle(lastFetched: start), "a limited fetch still succeeded")
        XCTAssertEqual(controller.remoteLimit, limit)
        XCTAssertTrue(controller.hasDetails)
        XCTAssertEqual(limit.short, "16 of 40 remotes")
        XCTAssertTrue(limit.sentence.contains("40 remotes"))

        controller.fetch()
        XCTAssertNil(controller.remoteLimit)
        XCTAssertFalse(controller.hasDetails)
        await fetcher.waitForFetches(2)
        fetcher.release(1, with: .finished(failures: []))
        await controller.task?.value
    }

    func testStopEndsAsCancelledWithoutARecord() async {
        let fetcher = GatedFetcher()
        let (controller, store) = controller(fetcher)
        var finished = 0
        controller.onFinished = { finished += 1 }
        controller.fetch()
        await fetcher.waitForFetches(1)
        controller.stop()
        fetcher.release(0, with: .cancelled)  // what the service returns once git is stopped
        await controller.task?.value
        XCTAssertEqual(controller.status, .cancelled(lastFetched: nil))
        XCTAssertNil(store.entry(for: repository.id), "a stopped fetch is not an attempt to record")
        XCTAssertEqual(finished, 1, "remotes fetched before the stop may have moved refs")
    }

    func testOpeningAnotherRepositoryDropsALateResult() async {
        let fetcher = GatedFetcher()
        let (controller, store) = controller(fetcher)
        var finished = 0
        controller.onFinished = { finished += 1 }
        controller.fetch()
        await fetcher.waitForFetches(1)
        let task = controller.task
        controller.open(nil)
        XCTAssertEqual(controller.status, .never)
        XCTAssertFalse(controller.canFetch)
        fetcher.release(0, with: .finished(failures: []))
        await task?.value
        XCTAssertEqual(controller.status, .never)
        XCTAssertNil(store.entry(for: repository.id))
        XCTAssertEqual(finished, 0)
    }

    func testWithoutAFetcherFetchIsOff() {
        let controller = FetchController(fetcher: nil, store: FetchRecordStore(defaults: defaults))
        controller.open(repository)
        XCTAssertFalse(controller.canFetch)
        controller.fetch()
        XCTAssertNil(controller.task)
    }

    func testAnnouncements() {
        let fetching = FetchStatus.fetching(remotes: [], since: start, lastFetched: nil)
        XCTAssertEqual(FetchAnnouncement.text(from: fetching, to: .idle(lastFetched: start)), "Fetch finished")
        XCTAssertEqual(FetchAnnouncement.text(from: fetching, to: .failed(lastFetched: nil)), "Fetch failed")
        XCTAssertEqual(FetchAnnouncement.text(from: fetching, to: .cancelled(lastFetched: nil)), "Fetch cancelled")
        XCTAssertNil(FetchAnnouncement.text(from: .never, to: .idle(lastFetched: start)), "not on open")
    }
}
