import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// The main window while the launch snapshot is painted (ADR-0018 §5, #109): "Updating…", dimmed rows, and a detail
/// panel that waits for the first load.
@MainActor
final class LaunchSnapshotRenderTests: XCTestCase {
    private var suiteName: String!
    private var store: PanelLayoutStore!

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        store = PanelLayoutStore(defaults: UserDefaults(suiteName: suiteName) ?? .standard)
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private func snapshotState() throws -> AppState {
        let state = AppState(layoutStore: store, registry: .preview)
        let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
        let repository = Repository(
            rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false)
        state.open(RepositoryContext(repository: repository, owner: "acme"))
        let snapshot = try XCTUnwrap(
            LaunchSnapshot(
                listing: .mockup, focused: GitPath("/tmp/dev/api-wt/42-rate-limit"), repository: repository,
                appVersion: "test (1)", gitExecutable: URL(fileURLWithPath: "/usr/bin/git"),
                gitVersion: GitVersion(major: 2, minor: 50, patch: 1), fingerprint: [], now: Date()))
        state.worktreeList = .snapshot(WorktreeListModel(snapshot: snapshot))
        return state
    }

    /// Set `OVERGROVE_SNAPSHOT_DIR` (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep the PNGs.
    func testSnapshotSidebarRendersInLightAndDark() throws {
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let state = try snapshotState()
            XCTAssertTrue(state.worktreeList.isSnapshot)
            let host = NSHostingView(rootView: MainWindowView(state: state))
            host.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            host.frame = NSRect(x: 0, y: 0, width: 1440, height: 848)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0, name)

            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent("launch-snapshot-\(name).png"))
            }
        }
    }
}
