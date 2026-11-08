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

    /// `.filesChanged` never replaces a running load (another window's ⌘R, say): it is refused, and the load finishes.
    func testFilesChangedNeverReplacesARunningLoad() async throws {
        let context = try await IntegrationContext.make(fixture: try await makeFixture())
        let service = try service(context)
        let first = try overview(await service.refresh(context.repository, trigger: .user))
        let statusesPerLoad = calls().filter { $0 == "status" }.count
        let release = markers.appendingPathComponent("release")
        try FileManager.default.removeItem(at: release)
        resetCalls()
        // The first load left a `started-<pid>` marker per status. Only a marker made after this point shows that the
        // user load below is running; a stale one let the file-change refresh go first and block at the gate until
        // git's 15 s status timeout under CI load (#335).
        for name in try FileManager.default.contentsOfDirectory(atPath: markers.path) where name.hasPrefix("started-") {
            try FileManager.default.removeItem(at: markers.appendingPathComponent(name))
        }

        let repository = context.repository
        let user = Task { await service.refresh(repository, trigger: .user) }
        let deadline = ContinuousClock.now + .seconds(10)
        while !(try FileManager.default.contentsOfDirectory(atPath: markers.path).contains { $0.hasPrefix("started-") })
        {
            guard ContinuousClock.now < deadline else { return XCTFail("the load never reached status") }
            try await Task.sleep(for: .milliseconds(20))
        }
        let worktrees = Set(first.entries.map(\.worktree.path))
        let refused = await service.refresh(
            repository, trigger: .filesChanged(worktrees: worktrees, refs: true, worktreeList: true))
        XCTAssertNil(refused, "refused while another load runs")

        FileManager.default.createFile(atPath: release.path, contents: nil)
        _ = try overview(await user.value)
        XCTAssertEqual(
            calls().filter { $0 == "status" }.count, statusesPerLoad,
            "only the user load queried: the file-change refresh started no git status")
    }

    /// #416: a change only to a worktree's HEAD (a switch in a linked worktree, then a commit on a detached HEAD)
    /// re-reads the worktree list, so the sidebar record (branch, head, detached) follows. Real git, real FSEvents.
    func testHeadOnlyChangesReloadTheWorktreeList() async throws {
        let repository = try await GitTestRepository.make()
        defer { repository.remove() }
        try repository.write("f.txt", "1\n")
        try await repository.git(["add", "f.txt"])
        try await repository.git(["commit", "-q", "-m", "first"])
        try await repository.git(["branch", "other"])
        let linked = repository.root.deletingLastPathComponent()
            .appendingPathComponent("head-416-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: linked) }
        try await repository.git(["worktree", "add", "-q", "-b", "lane", "--", linked.path])
        let model = Repository(
            rootURL: repository.root, commonGitDirectoryURL: repository.root.appendingPathComponent(".git"),
            isBare: false)
        let service = RepositoryService(client: GitClient(environment: repository.environment), sleep: { _ in })
        let loaded = try overview(await service.refresh(model, trigger: .user))
        let classifier = try XCTUnwrap(
            FileChangeClassifier(listing: WorktreeListing(overview: loaded), repository: model))
        let lanePath = try XCTUnwrap(loaded.entries.first { $0.worktree.branch == "refs/heads/lane" }).worktree.path

        let log = EventLog()
        let stream = LiveFileEventWatcher.live.watch(classifier.watchedPaths, latency: 0.2) { log.append($0) }
        defer { stream.stop() }
        try await Task.sleep(for: .seconds(1))  // let the stream settle

        /// Runs `change` in the linked worktree, waits for its events, and refreshes with what they classify as.
        func lane(after change: [String]) async throws -> Worktree {
            log.clear()
            // The common safety arguments and a fixed identity; fails on a non-zero exit (review of #437).
            try await repository.git(["-C", linked.path] + change)
            let deadline = ContinuousClock.now + .seconds(10)
            while !classifier.classify(log.all).worktreeList, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            let change = classifier.classify(log.all)
            XCTAssertTrue(change.worktreeList, "\(change) from \(log.all.prefix(6).map(\.path))")
            let refreshed = try overview(
                await service.refresh(
                    model,
                    trigger: .filesChanged(
                        worktrees: change.worktrees, refs: change.refs, worktreeList: change.worktreeList)))
            return try XCTUnwrap(refreshed.entries.first { $0.worktree.path == lanePath }).worktree
        }

        let switched = try await lane(after: ["switch", "-q", "other"])
        XCTAssertEqual(switched.branch, "refs/heads/other", "the sidebar shows the new branch")

        let detached = try await lane(after: ["switch", "-q", "--detach"])
        XCTAssertTrue(detached.isDetached)
        let committed = try await lane(after: ["commit", "-q", "--allow-empty", "-m", "detached"])
        XCTAssertTrue(committed.isDetached)
        XCTAssertNotEqual(committed.head, detached.head, "the new detached commit is the head the graph keys on")
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
