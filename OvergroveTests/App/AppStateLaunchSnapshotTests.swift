import Foundation
import XCTest

@testable import Overgrove

/// `AppState` and the launch snapshot (ADR-0018 §5, #109, T19): painted while the first load runs, never used.
@MainActor
final class AppStateLaunchSnapshotTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private var root: URL!
    private var gitDirectory: URL!
    private var gitExecutable: URL!
    private var store: LaunchSnapshotStore!

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        root = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString)")
        gitDirectory = root.appendingPathComponent("api/.git", isDirectory: true)
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
        for file in ["HEAD", "config", "index"] {
            try Data("x".utf8).write(to: gitDirectory.appendingPathComponent(file))
        }
        gitExecutable = root.appendingPathComponent("git")
        try Data("#!".utf8).write(to: gitExecutable)
        store = LaunchSnapshotStore(directory: root.appendingPathComponent("LaunchSnapshots"), appVersion: "test (1)")
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: root)
    }

    private var repository: Repository {
        Repository(
            rootURL: gitDirectory.deletingLastPathComponent(), commonGitDirectoryURL: gitDirectory, isBare: false)
    }

    private func saveSnapshot() throws {
        let snapshot = try XCTUnwrap(
            LaunchSnapshot(
                listing: .mockup, focused: nil, repository: repository, appVersion: store.appVersion,
                gitExecutable: gitExecutable, gitVersion: GitVersion(major: 2, minor: 50, patch: 1),
                fingerprint: LaunchSnapshot.fingerprint(gitDirectory), now: Date()))
        store.save(snapshot, for: repository)
    }

    /// The repository is registered: a snapshot is written only for a repository still in Overgrove.
    private var registeredEntry: RegisteredRepository {
        RegisteredRepository(
            rootPath: gitDirectory.deletingLastPathComponent().path, commonDirectoryPath: gitDirectory.path)
    }

    private func registry() -> RepositoryRegistry {
        let registry = RepositoryRegistry(defaults: defaults)
        _ = registry.add(registeredEntry)
        return registry
    }

    private func makeState(_ loader: any RepositoryLoading) -> AppState {
        let executable = gitExecutable!
        return AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: registry(),
            loader: loader, graphLoader: SampleGraphLoader(), commitLoader: StubCommitLoader(),
            launchSnapshots: store, gitIdentity: { (executable, GitVersion(major: 2, minor: 50, patch: 1)) })
    }

    private func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline { await Task.yield() }
    }

    func testSECT19_03_SnapshotIsDrawnButNothingRunsFromIt() async throws {
        try saveSnapshot()
        let loader = GatedRepositoryLoader()
        let state = makeState(loader)
        state.open(RepositoryContext(repository: repository, owner: nil))
        state.reload()
        await until { if case .snapshot = state.worktreeList { true } else { false } }

        guard case .snapshot(let model) = state.worktreeList else { return XCTFail("no snapshot painted") }
        XCTAssertEqual(state.worktreeListModel, model, "the sidebar draws the snapshot rows")
        XCTAssertEqual(model.rows.map(\.title).first, "main")
        XCTAssertTrue(state.worktreeList.isAwaitingLoad, "the detail panel waits")

        // Nothing is selected, focused, or openable: no toolbar chip, no Terminal / Finder / Compare target.
        XCTAssertNil(state.focusedWorktreePath)
        XCTAssertNil(state.selection)
        XCTAssertNil(state.snapshot)
        XCTAssertFalse(state.canCompare())
        let row = try XCTUnwrap(model.rows.first)
        state.selectWorktree(row.id)
        XCTAssertNil(state.selection, "a snapshot row cannot be selected")
        let actions = RecordingRowActions()
        state.rowActions = actions
        state.openTerminal(at: row.id)
        state.revealWorktree(row.id)
        XCTAssertTrue(actions.terminals.isEmpty)
        XCTAssertTrue(actions.revealed.isEmpty)
        XCTAssertNil(state.terminalConfirmation)

        // The first load runs anyway (it inspects first: the loader is what RepositoryService.refresh(.user) does).
        await loader.waitForLoads(1)
        XCTAssertEqual(loader.pendingCount, 1)
        loader.release(0, with: .success(.mockup))
        await until { if case .loaded = state.worktreeList { true } else { false } }
        XCTAssertNotNil(state.focusedWorktreePath, "the load replaces the snapshot")
    }

    func testVerifiedLoadWritesTheSnapshotAndFailureDeletesIt() async throws {
        let state = makeState(StubRepositoryLoader(result: .success(.mockup)))
        state.open(RepositoryContext(repository: repository, owner: nil))
        state.reload()
        await state.loadTask?.value
        await state.launchSnapshotTask?.value
        let saved = try XCTUnwrap(store.load(for: repository), "written after the verified load")
        XCTAssertEqual(saved.rows.count, 6)
        XCTAssertNotNil(saved.focusedPath)

        let failing = makeState(StubRepositoryLoader(result: .failure(.git(.timeout(seconds: 15)))))
        failing.open(RepositoryContext(repository: repository, owner: nil))
        failing.reload()
        await failing.loadTask?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file(for: repository).path), "deleted on failure")
    }

    func testWritesAreSpacedAndTheLatestWins() async throws {
        let state = makeState(StubRepositoryLoader(result: .success(.mockup)))
        state.open(RepositoryContext(repository: repository, owner: nil))
        state.reload()
        await state.loadTask?.value
        await state.launchSnapshotTask?.value
        let first = try XCTUnwrap(store.load(for: repository)).writtenAt

        state.reload()
        await state.loadTask?.value
        // The second write waits for the 10-second spacing; it has not happened yet.
        XCTAssertEqual(try XCTUnwrap(store.load(for: repository)).writtenAt, first)
        XCTAssertNotNil(state.launchSnapshotTask)
        state.launchSnapshotTask?.cancel()
    }

    func testRemovingTheRepositoryDeletesItsSnapshot() async throws {
        try saveSnapshot()
        let registry = RepositoryRegistry(defaults: defaults)
        let entry = RegisteredRepository(
            rootPath: gitDirectory.deletingLastPathComponent().path, commonDirectoryPath: gitDirectory.path)
        _ = registry.add(entry)
        let executable = gitExecutable!
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: registry,
            loader: StubRepositoryLoader(result: .success(.mockup)), graphLoader: SampleGraphLoader(),
            commitLoader: StubCommitLoader(), launchSnapshots: store,
            gitIdentity: { (executable, GitVersion(major: 2, minor: 50, patch: 1)) })
        state.removeRepository(entry.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file(for: repository).path))
    }

    func testSECT19_04_SettingsRemovalDeletesTheSnapshot() async throws {
        try saveSnapshot()
        let registry = registry()
        let actions = RepositoryListActions(
            registry: registry, registrar: .live, fetchRecords: FetchRecordStore(defaults: defaults),
            loader: StubRepositoryLoader(), launchSnapshots: store)
        actions.remove(registeredEntry.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file(for: repository).path))
    }

    func testNothingIsWrittenForARepositoryNoLongerRegistered() async throws {
        let state = makeState(StubRepositoryLoader(result: .success(.mockup)))
        state.open(RepositoryContext(repository: repository, owner: nil))
        state.reload()
        await state.loadTask?.value
        state.registry.remove(registeredEntry.id)
        await state.launchSnapshotTask?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file(for: repository).path))
    }

    func testWithoutAStoreNothingIsPaintedOrWritten() async throws {
        try saveSnapshot()
        let loader = GatedRepositoryLoader()
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: loader, graphLoader: SampleGraphLoader(), commitLoader: StubCommitLoader())
        state.open(RepositoryContext(repository: repository, owner: nil))
        state.reload()
        await loader.waitForLoads(1)
        XCTAssertEqual(state.worktreeList, .loading, "tests and previews have no snapshot store")
        loader.release(0, with: .success(.mockup))
    }
}
