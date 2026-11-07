import Foundation
import XCTest

@testable import Overgrove

/// `AppState` and fetch (#77): a finished fetch refreshes ahead/behind (`.fetchCompleted`), the status bar shows
/// `Refreshing…` while a load runs, and removing a repository forgets its fetch record.
@MainActor
final class AppStateFetchTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func loadedState(
        _ loader: TriggerRecordingLoader, fetcher: GatedFetcher, records: FetchRecordStore
    ) async -> AppState {
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: loader, fetcher: fetcher, fetchRecords: records)
        let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        state.reload()
        await loader.waitForRequests(1)
        XCTAssertTrue(state.isRefreshing, "Refreshing… while the load runs")
        loader.release(0, with: .mockup)
        await state.loadTask?.value
        XCTAssertFalse(state.isRefreshing)
        return state
    }

    func testFinishedFetchRefreshesAheadBehind() async {
        let loader = TriggerRecordingLoader()
        let fetcher = GatedFetcher()
        let state = await loadedState(loader, fetcher: fetcher, records: FetchRecordStore(defaults: defaults))
        XCTAssertEqual(state.fetchStatus, .never)

        state.fetch.fetch()
        XCTAssertTrue(state.fetchStatus.isFetching)
        await fetcher.waitForFetches(1)
        fetcher.release(0, with: .finished(failures: []))
        await state.fetch.task?.value
        await loader.waitForRequests(2)
        XCTAssertEqual(loader.triggers, [.user, .fetchCompleted])
        if case .idle = state.fetchStatus {} else { XCTFail("\(state.fetchStatus)") }
        XCTAssertTrue(state.isRefreshing)
        loader.release(1, with: .mockup)
        await state.loadTask?.value
    }

    func testRemovingARepositoryForgetsItsFetchRecord() async throws {
        let records = FetchRecordStore(defaults: defaults)
        let registry = RepositoryRegistry(defaults: defaults)
        let root = try XCTUnwrap(PathValidator.canonical(FileManager.default.temporaryDirectory))
            .appendingPathComponent("overgrove-fetch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        registry.add(RegisteredRepository(rootPath: root.path, commonDirectoryPath: root.path + "/.git"))
        let entry = try XCTUnwrap(registry.repositories.first)
        records.save(
            FetchRecord(repositoryID: entry.repository.id, finishedAt: Date(), succeeded: true, summary: nil))
        let loader = TriggerRecordingLoader()
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: registry, loader: loader,
            fetcher: GatedFetcher(), fetchRecords: records)

        state.openRegistered(entry.id)
        if case .idle = state.fetchStatus {} else { XCTFail("the record is shown on open: \(state.fetchStatus)") }
        state.removeRepository(entry.id)
        XCTAssertNil(records.entry(for: entry.repository.id))
        XCTAssertEqual(state.fetchStatus, .never)
        await loader.waitForRequests(1)
        loader.release(0, with: nil)
    }
}
