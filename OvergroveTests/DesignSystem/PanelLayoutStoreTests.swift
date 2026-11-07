import Foundation
import XCTest

@testable import Overgrove

/// `PanelLayoutStore`: panel widths and collapse state are remembered per repository (interaction.md §2.1).
final class PanelLayoutStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testUnknownRepositoryGetsTheDefaultLayout() {
        let store = PanelLayoutStore(defaults: defaults)
        XCTAssertEqual(store.layout(for: "/tmp/a/.git"), .default)
    }

    func testLayoutsAreSavedAndRestoredPerRepository() {
        let store = PanelLayoutStore(defaults: defaults)
        let a = PanelLayout(sidebarWidth: 300, detailWidth: 400, isSidebarCollapsed: true)
        let b = PanelLayout(sidebarWidth: 240, detailWidth: 500, isDetailCollapsed: true)
        store.save(a, for: "/tmp/a/.git")
        store.save(b, for: "/tmp/b/.git")

        // A fresh store over the same defaults, as after relaunching the app.
        let reopened = PanelLayoutStore(defaults: defaults)
        XCTAssertEqual(reopened.layout(for: "/tmp/a/.git"), a)
        XCTAssertEqual(reopened.layout(for: "/tmp/b/.git"), b)
    }

    func testStoredValuesAreClampedToTheCurrentLimits() throws {
        let store = PanelLayoutStore(defaults: defaults)
        // As if written by an older version with different limits.
        store.save(PanelLayout(sidebarWidth: 5, detailWidth: 9_000), for: "/tmp/a/.git")
        let restored = store.layout(for: "/tmp/a/.git")
        XCTAssertEqual(restored.sidebarWidth, 220)
        XCTAssertEqual(restored.detailWidth, 560)
    }

    func testCorruptDataFallsBackToTheDefault() {
        let store = PanelLayoutStore(defaults: defaults)
        defaults.set(Data("not json".utf8), forKey: store.key(for: "/tmp/a/.git"))
        XCTAssertEqual(store.layout(for: "/tmp/a/.git"), .default)
    }

    func testKeysDoNotEmbedTheRepositoryPath() {
        // The repository ID is a file-system path; the defaults key uses a digest so paths do not end up in the
        // preferences file's key list.
        let store = PanelLayoutStore(defaults: defaults)
        let key = store.key(for: "/Users/example/dev/secret-project/.git")
        XCTAssertFalse(key.contains("secret-project"))
        XCTAssertTrue(key.hasPrefix(PanelLayoutStore.keyPrefix))
        XCTAssertEqual(key, store.key(for: "/Users/example/dev/secret-project/.git"), "stable")
        XCTAssertNotEqual(key, store.key(for: "/Users/example/dev/other/.git"))
    }
}
