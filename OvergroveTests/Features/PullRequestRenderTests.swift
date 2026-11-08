import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// PR pills on worktree and LOCAL rows and S-05's "Pull request" card, offscreen in light and dark (ADR-0023, #115).
/// Set `OVERGROVE_SNAPSHOT_DIR` (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep the PNGs.
@MainActor
final class PullRequestRenderTests: XCTestCase {
    private let repository = GitHubRepository(owner: "team", name: "app")!

    private func pullRequest(
        _ number: Int, branch: String, state: PullRequest.State, isDraft: Bool = false,
        review: PullRequest.ReviewDecision = .none, title: String = "feat: rate limit the fetch button"
    ) -> PullRequest {
        PullRequest(
            number: number, title: title, state: state, isDraft: isDraft,
            head: PullRequest.Head(owner: "team", name: "app", branch: branch), baseRefName: "main",
            reviewDecision: review, updatedAt: nil, url: URL(string: "https://github.com/team/app/pull/\(number)")!)
    }

    func testRendersInLightAndDark() throws {
        var listing = WorktreeListing.mockup
        let branches = ["feat/42-rate-limit", "fix/login", "hotfix", "spike/cache"].map {
            PullRequestLinksTests.branch($0)
        }
        let refs = RefParser.Listing(branches: branches, tags: [], isPartial: false, skippedRecords: 0)
        listing.refs = refs
        let pullRequests = [
            pullRequest(57, branch: "feat/42-rate-limit", state: .open, review: .approved),
            pullRequest(61, branch: "fix/login", state: .open, isDraft: true),
            pullRequest(48, branch: "hotfix", state: .merged),
            pullRequest(33, branch: "spike/cache", state: .closed),
        ]
        let links = PullRequestLinkIndex(
            pullRequests: pullRequests, branches: branches, remotes: ["origin": repository])
        let model = BranchListModel(refs: refs, checkedOut: [], remoteNames: [])
        let rows = VStack(spacing: 0) {
            WorktreeListSection(
                status: .loaded(listing), model: WorktreeListModel(listing: listing, focused: nil), selectedPath: nil,
                onSelect: { _ in })
            BranchListSection(title: "LOCAL", count: model.localCount, nodes: model.local)
            Spacer()
        }
        .environment(\.issueBadges, IssueBadgeContext(known: [42]))
        .environment(\.pullRequestBadges, PullRequestBadgeContext(links: links))
        try render(rows, width: 256, height: 460, name: "pull-request-badges")

        var detail = WorktreeDetailModel(entry: listing.entries[1], inspection: nil, fetchStatus: .never, now: Date())
        detail.pullRequest = PullRequestCardModel(pullRequests[0], repository: repository)
        try render(WorktreeDetailView(model: detail), width: 344, height: 520, name: "pull-request-card")

        // A merged PR shows the fact only; a hostile title is escaped; the URL is not this repository's, so the
        // button is off.
        var merged = detail
        merged.pullRequest = PullRequestCardModel(
            PullRequest(
                number: 48, title: "evil\u{202E}gpj.exe\nsecond line", state: .merged, isDraft: false,
                head: nil, baseRefName: "release/1.0", reviewDecision: .changesRequested, updatedAt: nil,
                url: URL(string: "https://github.com/someone/else/pull/48")!),
            repository: repository)
        try render(WorktreeDetailView(model: merged), width: 344, height: 520, name: "pull-request-card-merged")
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
