import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// ISSUES and S-06 rendered offscreen in light and dark (#81). Set `OVERGROVE_SNAPSHOT_DIR`
/// (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep the PNGs.
@MainActor
final class IssuePanelRenderTests: XCTestCase {
    func testRendersInLightAndDark() throws {
        let issues = [
            IssueModelsTests.issue(
                42, "Rate limit the fetch button", labels: ["type:feature", "area:ui", "priority:p1"],
                assignees: ["octocat"]),
            IssueModelsTests.issue(12, "Worktree list shows prunable entries last", updated: -3_600),
        ]
        let list = IssueListModel(
            content: .loaded(repository: IssueModelsTests.repository, issues: issues), isLoading: true)
        let sidebar = VStack(spacing: 0) {
            IssueListSection(model: list, selectedNumber: 42, onSelect: { _ in })
            IssueListSection(
                model: IssueListModel(content: .notLoggedIn, isLoading: false), selectedNumber: nil,
                onSelect: { _ in })
            Spacer()
        }
        try render(sidebar, width: 256, height: 200, name: "issues-sidebar")
        try render(
            IssueDetailView(model: IssueDetailModel(issues[0], repository: IssueModelsTests.repository)), width: 344,
            height: 420, name: "issue-detail")
    }

    private func render(_ view: some View, width: CGFloat, height: CGFloat, name: String) throws {
        for (suffix, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(
                rootView: view.frame(width: width, height: height).background(Tokens.Color.surfacePanel))
            host.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            host.frame = NSRect(x: 0, y: 0, width: width, height: height)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(suffix).png"))
            }
        }
    }
}
