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
            content: .loaded(repository: .github(IssueModelsTests.repository), issues: issues), isLoading: true)
        let sidebar = VStack(spacing: 0) {
            IssueListSection(model: list, selectedNumber: 42, onSelect: { _ in })
            IssueListSection(
                model: IssueListModel(content: .notLoggedIn, isLoading: false), selectedNumber: nil,
                onSelect: { _ in })
            Spacer()
        }
        try render(sidebar, width: 256, height: 200, name: "issues-sidebar")
        let links = IssueLinkIndex(
            listing: IssueLinkTests.listing([
                IssueLinkTests.branch("refs/heads/feat/42-rate-limit"),
                IssueLinkTests.branch("refs/remotes/origin/feat/42-rate-limit", .remote(remote: "origin")),
            ]))
        let commits = CommitLink.latest(
            linkedTo: 42, in: [IssueLinkTests.commit(0, "feat: rate limit the fetch button (#42)")], repository: nil)
        try render(
            IssueDetailView(
                model: IssueDetailModel(
                    issues[0], repository: IssueModelsTests.repository, links: links.links(42), commits: commits)),
            width: 344, height: 560, name: "issue-detail")
        // Worktree and branch rows with a known (#42) and an unknown (#7) issue badge.
        var listing = WorktreeListing.mockup
        let refs = RefParser.Listing(
            branches: [IssueLinkTests.branch("refs/heads/fix/7-crash")], tags: [], isPartial: false,
            skippedRecords: 0)
        listing.refs = refs
        let branches = BranchListModel(refs: refs, checkedOut: [], remoteNames: [])
        let rows = VStack(spacing: 0) {
            WorktreeListSection(
                status: .loaded(listing), model: WorktreeListModel(listing: listing, focused: nil), selectedPath: nil,
                onSelect: { _ in })
            BranchListSection(title: "LOCAL", count: branches.localCount, nodes: branches.local)
            Spacer()
        }
        .environment(\.issueBadges, IssueBadgeContext(known: [42]))
        try render(rows, width: 256, height: 420, name: "issue-badges")
    }

    /// #83: gh missing, logged out, failed, and no remote at the narrowest sidebar (220pt).
    func testDegradedStatesRender() throws {
        let sections = VStack(spacing: 0) {
            ForEach(
                Array(
                    [
                        IssueListContent.notLoggedIn, .notInstalled,
                        .failed(repository: .github(IssueModelsTests.repository), detail: "HTTP 404"), .noGitHubRemote,
                    ].enumerated()), id: \.offset
            ) { _, content in
                IssueListSection(
                    model: IssueListModel(content: content, isLoading: false), selectedNumber: nil, onSelect: { _ in })
            }
            Spacer()
        }
        try render(sections, width: Tokens.Size.sidebarWidthMin, height: 520, name: "issues-degraded")
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
