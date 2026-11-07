import Foundation
import XCTest

@testable import Overgrove

/// Collects real FSEvents batches (#119).
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [FileEvent] = []
    var all: [FileEvent] { lock.withLock { events } }
    func append(_ new: [FileEvent]) { lock.withLock { events += new } }
    func clear() { lock.withLock { events.removeAll() } }
}

/// Auto refresh with real git and real FSEvents (#119): the `.filesChanged` trigger re-queries only what changed,
/// and Overgrove's own git calls produce no event the watcher acts on (no feedback loop).
final class AutoRefreshIntegrationTests: XCTestCase {
    private var executables: TestExecutables!
    private var markers: URL!

    override func setUpWithError() throws {
        executables = try TestExecutables()
        markers = executables.directory.appendingPathComponent("markers", isDirectory: true)
    }

    override func tearDown() {
        executables?.remove()
    }

    private func calls() -> [String] {
        let log = (try? String(contentsOf: markers.appendingPathComponent("invocations.log"), encoding: .utf8)) ?? ""
        return log.split(separator: "\n").map(String.init)
    }

    private func resetCalls() {
        try? FileManager.default.removeItem(at: markers.appendingPathComponent("invocations.log"))
    }

    /// The fixture through a git stand-in that logs every subcommand.
    private func service(_ context: IntegrationContext) throws -> RepositoryService {
        let gated = try executables.gatedGit(forwardingTo: context.environment.executable, markers: markers)
        FileManager.default.createFile(atPath: markers.appendingPathComponent("release").path, contents: nil)
        let client = GitClient(
            environment: GitEnvironment(executable: gated, version: context.environment.version),
            parentEnvironment: context.fixture.environment)
        return RepositoryService(client: client, sleep: { _ in })
    }

    private func overview(_ refresh: RepositoryService.Refresh?) throws -> RepositoryOverview {
        let refresh = try XCTUnwrap(refresh)
        switch refresh.result {
        case .success(let overview): return overview
        case .failure(let error): throw error
        }
    }

    /// `.filesChanged` (#88 trigger for #119): only the changed worktrees' statuses; refs and the list only on request.
    func testFilesChangedQueriesOnlyWhatChanged() async throws {
        let context = try await IntegrationContext.make(fixture: try await makeFixture())
        let service = try service(context)
        let first = try overview(await service.refresh(context.repository, trigger: .user))
        let ahead = try XCTUnwrap(first.entries.first { $0.worktree.branch == "refs/heads/feat/ahead" }).worktree.path
        resetCalls()

        _ = try overview(
            await service.refresh(
                context.repository, trigger: .filesChanged(worktrees: [ahead], refs: false, worktreeList: false)))
        XCTAssertEqual(calls().filter { $0 == "status" }.count, 1, "only the changed worktree")
        XCTAssertFalse(calls().contains("worktree"), "no list")
        XCTAssertFalse(calls().contains("for-each-ref"), "no refs")

        resetCalls()
        _ = try overview(
            await service.refresh(
                context.repository, trigger: .filesChanged(worktrees: [], refs: true, worktreeList: true)))
        XCTAssertEqual(calls().filter { $0 == "status" }.count, 0)
        XCTAssertTrue(calls().contains("worktree"))
        XCTAssertTrue(calls().contains("for-each-ref"))
    }

    /// No feedback loop: a full load and a `.filesChanged` refresh of every worktree write nothing the watcher acts
    /// on (#211: queries never write the index). Control: a real edit is seen.
    func testOwnQueriesProduceNoRelevantEvents() async throws {
        let context = try await IntegrationContext.make(fixture: try await makeFixture())
        let service = RepositoryService(client: context.client, sleep: { _ in })
        let loaded = try overview(await service.refresh(context.repository, trigger: .user))
        let classifier = try XCTUnwrap(
            FileChangeClassifier(listing: WorktreeListing(overview: loaded), repository: context.repository))
        XCTAssertGreaterThan(classifier.worktrees.count, 1)

        let log = EventLog()
        let stream = LiveFileEventWatcher.live.watch(classifier.watchedPaths, latency: 0.2) { log.append($0) }
        defer { stream.stop() }
        try await Task.sleep(for: .seconds(1))  // let the stream settle
        log.clear()

        for _ in 0..<3 {
            _ = try overview(await service.refresh(context.repository, trigger: .user))
            _ = try overview(
                await service.refresh(
                    context.repository,
                    trigger: .filesChanged(
                        worktrees: Set(classifier.worktrees.map(\.path)), refs: true, worktreeList: true)))
        }
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(
            classifier.classify(log.all), FileChangeSet(), "own git calls: \(log.all.prefix(5).map(\.path))")

        // Control: an edit in a worktree is seen and attributed to it.
        let main = try XCTUnwrap(classifier.worktrees.first { $0.gitDirectory == classifier.commonDirectory })
        try "edited\n".write(
            to: URL(fileURLWithPath: main.folder).appendingPathComponent("auto-refresh-probe.txt"), atomically: false,
            encoding: .utf8)
        let deadline = ContinuousClock.now + .seconds(10)
        while classifier.classify(log.all).worktrees.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(classifier.classify(log.all).worktrees, [main.path])
    }
}
