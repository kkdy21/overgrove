import Foundation
import XCTest

@testable import Overgrove

/// Records every request with its trigger and holds it until the test releases it; serves a configurable cached
/// listing and records `forget`.
final class TriggerRecordingLoader: RepositoryLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [(RepositoryService.Trigger, CheckedContinuation<WorktreeListing?, Never>)] = []
    private var forgottenIDs: [String] = []
    private var cached: WorktreeListing?

    init(cached: WorktreeListing? = nil) {
        self.cached = cached
    }

    var triggers: [RepositoryService.Trigger] { lock.withLock { waiting.map(\.0) } }
    var forgotten: [String] { lock.withLock { forgottenIDs } }

    func load(_ repository: Repository) async throws(RepositoryLoadError) -> WorktreeListing {
        guard let listing = try await load(repository, trigger: .user) else { throw .git(.cancelled) }
        return listing
    }

    func load(
        _ repository: Repository, trigger: RepositoryService.Trigger
    ) async throws(RepositoryLoadError) -> WorktreeListing? {
        await withCheckedContinuation { continuation in
            lock.withLock { waiting.append((trigger, continuation)) }
        }
    }

    func cachedListing(_ repository: Repository) async -> WorktreeListing? { lock.withLock { cached } }

    func forget(_ repository: Repository) async {
        lock.withLock {
            forgottenIDs.append(repository.id)
            cached = nil
        }
    }

    /// Resumes request `index` (in call order); `nil` stands for superseded or debounced away.
    func release(_ index: Int, with listing: WorktreeListing?, file: StaticString = #filePath, line: UInt = #line) {
        let continuation = lock.withLock { index < waiting.count ? waiting[index].1 : nil }
        guard let continuation else { return XCTFail("no request \(index)", file: file, line: line) }
        continuation.resume(returning: listing)
    }

    /// Fails instead of hanging when the request never comes.
    func waitForRequests(_ count: Int, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while triggers.count < count {
            guard ContinuousClock.now < deadline else {
                return XCTFail("expected \(count) requests, got \(triggers)", file: file, line: line)
            }
            await Task.yield()
        }
    }
}

/// `AppState` and the `RepositoryService` cache triggers (#243, overview.md §4–§5): paint from the cache, then
/// refresh; worktree selection refreshes that worktree in the background; window activation is `.automatic`; ⌘R is
/// `.user`; removing a repository forgets its cache.
@MainActor
final class AppStateCacheTriggerTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private let feature = GitPath("/tmp/dev/api-wt/42-rate-limit")
    private let login = GitPath("/tmp/dev/api-wt/login")

    private func makeState(_ loader: TriggerRecordingLoader) -> AppState {
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: loader)
        let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        return state
    }

    /// Opens the repository and completes the first `.user` load with the mockup.
    private func loadedState(_ loader: TriggerRecordingLoader) async -> AppState {
        let state = makeState(loader)
        state.reload()
        await loader.waitForRequests(1)
        loader.release(0, with: .mockup)
        await state.loadTask?.value
        return state
    }

    // MARK: Opening

    func testOpeningPaintsTheCachedListingBeforeTheFullRefresh() async {
        let cached = WorktreeListing(entries: [WorktreeListing.mockup.entries[0]], isPartial: false)
        let loader = TriggerRecordingLoader(cached: cached)
        let state = makeState(loader)
        state.reload()
        await loader.waitForRequests(1)

        XCTAssertEqual(loader.triggers, [.user])
        XCTAssertEqual(state.worktreeList, .loaded(cached), "the cache is shown while the refresh runs")
        loader.release(0, with: .mockup)
        await state.loadTask?.value
        XCTAssertEqual(state.worktreeList, .loaded(.mockup))
    }

    func testOpeningWithoutCacheShowsLoading() async {
        let loader = TriggerRecordingLoader()
        let state = makeState(loader)
        state.reload()
        await loader.waitForRequests(1)
        XCTAssertEqual(state.worktreeList, .loading)
        loader.release(0, with: .mockup)
        await state.loadTask?.value
        XCTAssertEqual(state.worktreeList, .loaded(.mockup))
    }

    /// Security review of #243: the cached paint is not verified. If the load after it fails (the configuration now
    /// blocks queries), the error replaces it.
    func testCachedPaintFollowedByAFailureShowsTheError() async {
        let cached = WorktreeListing(entries: [WorktreeListing.mockup.entries[0]], isPartial: false)
        let loader = BlockedAfterCacheLoader(cached: cached)
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: loader)
        let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        state.reload()
        await state.loadTask?.value
        XCTAssertEqual(state.worktreeList, .failed(message: RepositoryLoadError.blocked(reason: "filter").message))
        XCTAssertNil(state.snapshot)
    }

    /// Security review of #243: another window's request can supersede this window's first load. The cached paint
    /// is not kept as current: the full load is asked for again.
    func testSupersededFirstLoadIsRetried() async {
        let cached = WorktreeListing(entries: [WorktreeListing.mockup.entries[0]], isPartial: false)
        let loader = TriggerRecordingLoader(cached: cached)
        let state = makeState(loader)
        state.reload()
        await loader.waitForRequests(1)
        loader.release(0, with: nil)  // superseded by another window
        await loader.waitForRequests(2)
        XCTAssertEqual(loader.triggers, [.user, .user])
        loader.release(1, with: .mockup)
        await state.loadTask?.value
        XCTAssertEqual(state.worktreeList, .loaded(.mockup))

        // Once verified, a superseded background refresh keeps the listing and is not retried.
        state.windowDidBecomeActive()
        await loader.waitForRequests(3)
        loader.release(2, with: nil)
        await state.loadTask?.value
        XCTAssertEqual(loader.triggers, [.user, .user, .automatic])
        XCTAssertEqual(state.worktreeList, .loaded(.mockup))
    }

    func testRepeatedlySupersededFirstLoadFallsBackToLoadingUntilActivation() async {
        let cached = WorktreeListing(entries: [WorktreeListing.mockup.entries[0]], isPartial: false)
        let loader = TriggerRecordingLoader(cached: cached)
        let state = makeState(loader)
        state.reload()
        let attempts = 1 + AppState.maximumSupersededRetries
        for index in 0..<attempts {
            await loader.waitForRequests(index + 1)
            loader.release(index, with: nil)
        }
        await state.loadTask?.value
        XCTAssertEqual(loader.triggers.count, attempts)
        XCTAssertEqual(state.worktreeList, .loading, "the unverified cached paint is taken down")
        XCTAssertNil(state.snapshot)

        state.windowDidBecomeActive()
        await loader.waitForRequests(attempts + 1)
        XCTAssertEqual(loader.triggers.last, .user, "activation loads everything, not .automatic")
        loader.release(attempts, with: .mockup)
        await state.loadTask?.value
        XCTAssertEqual(state.worktreeList, .loaded(.mockup))
    }

    // MARK: Worktree selection

    /// PB-2: the switch is synchronous from the listing in memory; the status refresh follows in the background.
    func testSelectionShowsAtOnceThenRefreshesThatWorktree() async {
        let loader = TriggerRecordingLoader()
        let state = await loadedState(loader)

        state.selectWorktree(feature)
        XCTAssertEqual(state.focusedWorktreePath, feature)
        XCTAssertEqual(state.wipDetailModel?.title, "feat/42-rate-limit", "shown before any git")
        await loader.waitForRequests(2)
        XCTAssertEqual(loader.triggers.last, .worktreeSelected(feature))

        let refreshed = WorktreeListing(
            entries: WorktreeListing.mockup.entries.map { entry in
                entry.worktree.path == feature
                    ? WorktreeListing.Entry(
                        worktree: entry.worktree,
                        state: .loaded(WorktreeListing.state(branch: "feat/42-rate-limit", staged: 1)))
                    : entry
            },
            isPartial: false)
        loader.release(1, with: refreshed)
        await state.loadTask?.value
        XCTAssertEqual(state.wipDetailModel?.changedFileCount, 1, "the fresh status replaces the cached one")
    }

    func testSelectionDuringAFullRefreshDoesNotReplaceIt() async {
        let loader = TriggerRecordingLoader()
        let state = await loadedState(loader)
        state.reload()  // ⌘R
        await loader.waitForRequests(2)
        state.selectWorktree(feature)
        XCTAssertEqual(state.focusedWorktreePath, feature)
        XCTAssertEqual(loader.triggers, [.user, .user], "the full refresh in flight already brings that status")

        loader.release(1, with: .mockup)
        await state.loadTask?.value
        XCTAssertEqual(state.focusedWorktreePath, feature, "the result keeps the new focus")
    }

    /// Security review of #243: the background refresh after a selection must not drop the S-05 inspection that the
    /// selection started; it is stored and kept until a refresh result replaces the listing.
    func testInspectionStartedBySelectionSurvivesItsRefresh() async {
        let loader = TriggerRecordingLoader()
        let inspector = RecordingInspector()
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: loader, inspector: inspector)
        let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        state.reload()
        await loader.waitForRequests(1)
        loader.release(0, with: .mockup)
        await state.loadTask?.value
        state.showWorktreeDetail()
        await state.inspectionTask?.value

        state.selectWorktree(feature)  // stays on the Worktree segment, inspects feature, refreshes in the background
        await state.inspectionTask?.value
        XCTAssertNotNil(state.worktreeDetailModel?.security, "the inspection is stored despite the refresh")
        await loader.waitForRequests(2)
        loader.release(1, with: nil)  // superseded: nothing replaces the listing, the inspection stays
        await state.loadTask?.value
        XCTAssertNotNil(state.worktreeDetailModel?.security)
    }

    func testANewerSelectionSupersedesTheLastOne() async {
        let loader = TriggerRecordingLoader()
        let state = await loadedState(loader)
        state.selectWorktree(feature)
        await loader.waitForRequests(2)
        let first = state.loadTask
        state.selectWorktree(login)
        await loader.waitForRequests(3)
        XCTAssertEqual(loader.triggers.suffix(2), [.worktreeSelected(feature), .worktreeSelected(login)])

        let stale = WorktreeListing(entries: [WorktreeListing.mockup.entries[0]], isPartial: false)
        loader.release(1, with: stale)
        await first?.value
        XCTAssertEqual(state.worktreeList, .loaded(.mockup), "the superseded answer is dropped")
        XCTAssertEqual(state.focusedWorktreePath, login)
        loader.release(2, with: .mockup)
        await state.loadTask?.value
    }

    // MARK: Window activation and ⌘R

    func testWindowActivationIsAutomaticOnceLoaded() async {
        let loader = TriggerRecordingLoader()
        let state = makeState(loader)
        state.windowDidBecomeActive()
        XCTAssertEqual(loader.triggers, [], "nothing before the repository is loaded")
        state.reload()
        await loader.waitForRequests(1)
        state.windowDidBecomeActive()
        XCTAssertEqual(loader.triggers, [.user], "not while the first load runs")
        loader.release(0, with: .mockup)
        await state.loadTask?.value

        state.windowDidBecomeActive()
        await loader.waitForRequests(2)
        XCTAssertEqual(loader.triggers, [.user, .automatic])
        // Debounced away (or nothing stale): the listing stays.
        loader.release(1, with: nil)
        await state.loadTask?.value
        XCTAssertEqual(state.worktreeList, .loaded(.mockup))
    }

    func testRefreshCommandIsAUserRefreshThatReplacesAnAutomaticOne() async {
        let loader = TriggerRecordingLoader()
        let state = await loadedState(loader)
        state.windowDidBecomeActive()
        await loader.waitForRequests(2)
        let automatic = state.loadTask
        state.reload()
        await loader.waitForRequests(3)
        XCTAssertEqual(loader.triggers, [.user, .automatic, .user])
        XCTAssertEqual(state.worktreeList, .loaded(.mockup), "the shown data stays during the refresh")

        loader.release(1, with: WorktreeListing(entries: [], isPartial: false))
        await automatic?.value
        XCTAssertEqual(state.worktreeList, .loaded(.mockup), "the replaced automatic answer is dropped")
        loader.release(2, with: .mockup)
        await state.loadTask?.value
    }

    func testFailedBackgroundRefreshShowsTheError() async {
        let loader = FailingAfterFirstLoader()
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: loader)
        let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        state.reload()
        await state.loadTask?.value
        state.windowDidBecomeActive()
        await state.loadTask?.value
        XCTAssertEqual(
            state.worktreeList,
            .failed(message: RepositoryLoadError.blocked(reason: "filter").message),
            "a configuration that now blocks queries is not hidden behind the old listing")
    }

    // MARK: Removal

    func testRemovingARepositoryForgetsItsCache() async throws {
        let loader = TriggerRecordingLoader()
        let registry = RepositoryRegistry(defaults: defaults)
        let root = try XCTUnwrap(PathValidator.canonical(FileManager.default.temporaryDirectory))
            .appendingPathComponent("overgrove-forget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        registry.add(RegisteredRepository(rootPath: root.path, commonDirectoryPath: root.path + "/.git"))
        let entry = try XCTUnwrap(registry.repositories.first)
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: registry, loader: loader)
        state.openRegistered(entry.id)
        await loader.waitForRequests(1)

        state.removeRepository(entry.id)
        await state.forgetTask?.value
        XCTAssertNil(state.repository)
        XCTAssertEqual(loader.forgotten, [entry.repository.id])
        loader.release(0, with: .mockup)  // the cancelled load's answer is dropped
        await state.loadTask?.value
        XCTAssertEqual(state.worktreeList, .idle)
    }
}

/// Loads the mockup once, then reports a blocked configuration.
private final class FailingAfterFirstLoader: RepositoryLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func load(_ repository: Repository) async throws(RepositoryLoadError) -> WorktreeListing {
        guard let listing = try await load(repository, trigger: .user) else { throw .git(.cancelled) }
        return listing
    }

    func load(
        _ repository: Repository, trigger: RepositoryService.Trigger
    ) async throws(RepositoryLoadError) -> WorktreeListing? {
        let call = lock.withLock {
            calls += 1
            return calls
        }
        if call == 1 { return .mockup }
        throw .blocked(reason: "filter")
    }
}

/// Serves a cached listing, then reports that the configuration now blocks queries.
private final class BlockedAfterCacheLoader: RepositoryLoading, @unchecked Sendable {
    let cached: WorktreeListing

    init(cached: WorktreeListing) {
        self.cached = cached
    }

    func load(_ repository: Repository) async throws(RepositoryLoadError) -> WorktreeListing {
        throw .blocked(reason: "filter")
    }

    func load(
        _ repository: Repository, trigger: RepositoryService.Trigger
    ) async throws(RepositoryLoadError) -> WorktreeListing? {
        throw .blocked(reason: "filter")
    }

    func cachedListing(_ repository: Repository) async -> WorktreeListing? { cached }
}
