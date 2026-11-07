import Foundation
import XCTest

@testable import Overgrove

/// `RepositoryRegistry`: registered repositories in UserDefaults, paths only (overview.md §8).
@MainActor
final class RepositoryRegistryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func entry(_ name: String) -> RegisteredRepository {
        RegisteredRepository(
            rootPath: "/tmp/dev/\(name)", commonDirectoryPath: "/tmp/dev/\(name)/.git")
    }

    func testStartsEmpty() {
        let registry = RepositoryRegistry(defaults: defaults)
        XCTAssertEqual(registry.repositories, [])
        XCTAssertNil(registry.lastSelected)
    }

    func testAddKeepsOrderAndDedupesByCommonDirectory() {
        let registry = RepositoryRegistry(defaults: defaults)
        XCTAssertTrue(registry.add(entry("api")))
        XCTAssertTrue(registry.add(entry("web")))
        // The same repository again (e.g. picked through a linked worktree): not added twice.
        XCTAssertFalse(
            registry.add(RegisteredRepository(rootPath: "/tmp/dev/api", commonDirectoryPath: "/tmp/dev/api/.git")))
        XCTAssertEqual(registry.repositories.map(\.name), ["api", "web"])
    }

    func testPersistenceRoundTrip() {
        let registry = RepositoryRegistry(defaults: defaults)
        registry.add(entry("api"))
        registry.add(entry("web"))
        registry.lastSelected = entry("web").id

        let relaunched = RepositoryRegistry(defaults: defaults)
        XCTAssertEqual(relaunched.repositories, [entry("api"), entry("web")])
        XCTAssertEqual(relaunched.lastSelected, entry("web").id)
    }

    func testRemoveForgetsTheEntryAndTheSelection() {
        let registry = RepositoryRegistry(defaults: defaults)
        registry.add(entry("api"))
        registry.add(entry("web"))
        registry.lastSelected = entry("api").id
        registry.remove(entry("api").id)

        XCTAssertEqual(registry.repositories.map(\.name), ["web"])
        XCTAssertNil(registry.lastSelected)
        XCTAssertEqual(RepositoryRegistry(defaults: defaults).repositories.map(\.name), ["web"])
    }

    /// overview.md §8: paths only. No bookmarks, remote URLs, or anything else.
    func testOnlyPathsAreStored() throws {
        let registry = RepositoryRegistry(defaults: defaults)
        registry.add(entry("api"))
        let data = try XCTUnwrap(defaults.data(forKey: RepositoryRegistry.repositoriesKey))
        let stored = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(Set(stored[0].keys), ["rootPath", "commonDirectoryPath"])
        XCTAssertTrue(stored[0].values.allSatisfy { $0 is String })
    }

    func testCorruptOrInvalidStoredEntriesAreSkipped() throws {
        let json = """
            [{"rootPath": "/tmp/dev/api", "commonDirectoryPath": "/tmp/dev/api/.git"},
             {"rootPath": "relative", "commonDirectoryPath": "/tmp/x/.git"},
             {"rootPath": "/tmp/new\\nline", "commonDirectoryPath": "/tmp/new\\nline/.git"},
             {"rootPath": "/tmp/dev/api", "commonDirectoryPath": "/tmp/dev/api/.git"}]
            """
        defaults.set(Data(json.utf8), forKey: RepositoryRegistry.repositoriesKey)
        XCTAssertEqual(RepositoryRegistry(defaults: defaults).repositories.map(\.name), ["api"])

        defaults.set(Data("not json".utf8), forKey: RepositoryRegistry.repositoriesKey)
        XCTAssertEqual(RepositoryRegistry(defaults: defaults).repositories, [])
    }

    func testRepositoryModelUsesTheCommonDirectoryAsIdentity() {
        let repository = entry("api").repository
        XCTAssertEqual(repository.id, entry("api").id)
        XCTAssertEqual(repository.rootURL?.path, "/tmp/dev/api")
        XCTAssertEqual(entry("api").name, "api")
    }
}
