import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// The sidebar's layout rules (#573), rendered offscreen: pinned section headers, one start line, badges that give
/// way by priority, the 24pt filter field, and the empty state's next step. Set `OVERGROVE_SNAPSHOT_DIR`
/// (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep the PNGs.
@MainActor
final class SidebarLayoutRenderTests: XCTestCase {
    private var suiteName: String!
    private var store: PanelLayoutStore!

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        store = PanelLayoutStore(defaults: UserDefaults(suiteName: suiteName) ?? .standard)
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    /// LOCAL, REMOTE, and TAGS rows, so their icons can be checked against the WORKTREES tiles.
    private var branches: BranchListModel {
        let oid = ObjectID(String(repeating: "ab", count: 20))!
        func branch(_ name: String, remote: Bool = false) -> Branch {
            Branch(
                fullName: name, kind: remote ? .remote(remote: "origin") : .local, target: oid, upstreamStatus: .none,
                isHead: false, committerDate: nil, symbolicTarget: nil)
        }
        let refs = RefParser.Listing(
            branches: [
                branch("refs/heads/main"), branch("refs/heads/feat/x"), branch("refs/heads/old-spike"),
                branch("refs/remotes/origin/main", remote: true),
            ],
            tags: [
                Tag(fullName: "refs/tags/v1.4.0", target: oid, peeledTarget: nil, date: nil, objectType: .commit)
            ], isPartial: false, skippedRecords: 0)
        return BranchListModel(refs: refs, checkedOut: ["refs/heads/main"], remoteNames: ["origin"])
    }

    private func sidebar(_ state: AppState) -> SidebarPanel {
        SidebarPanel(
            hasRepository: true, worktreeStatus: state.worktreeList, worktreeModel: state.worktreeListModel,
            selectedWorktree: state.focusedWorktreePath, branchModel: state.branchListModel ?? branches,
            stashRows: state.stashes.map(StashRow.init), issueModel: state.issueListModel)
    }

    /// Renders `view` in light and dark. `scrollBy` scrolls the sidebar's scroll view before drawing (no mouse: the
    /// clip view is moved directly).
    @discardableResult
    private func render(
        _ view: some View, size: CGSize, name: String, scrollBy offset: CGFloat = 0
    ) throws -> [NSBitmapImageRep] {
        var bitmaps: [NSBitmapImageRep] = []
        for (mode, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            // On `surface.panel`, as `PanelSplitView` draws the sidebar.
            let host = NSHostingView(
                rootView: view.frame(width: size.width, height: size.height).background(Tokens.Color.surfacePanel))
            host.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            if offset > 0 {
                let scrollView = try XCTUnwrap(Self.scrollView(in: host), "the sidebar scrolls")
                scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
                scrollView.reflectScrolledClipView(scrollView.contentView)
                host.layoutSubtreeIfNeeded()
            }
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            bitmaps.append(bitmap)
            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(mode).png"))
            }
        }
        return bitmaps
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap(scrollView(in:)).first
    }

    /// The mockup sidebar at the minimum width (220) and a wider one (256), and scrolled so WORKTREES' rows pass under
    /// its pinned header.
    func testSidebarAtNarrowAndWideWidths() throws {
        let state = AppState.mockup(layoutStore: store)
        try render(sidebar(state), size: CGSize(width: 220, height: 720), name: "sidebar-573-220")
        try render(sidebar(state), size: CGSize(width: 256, height: 720), name: "sidebar-573-256")
        try render(sidebar(state), size: CGSize(width: 220, height: 360), name: "sidebar-573-scrolled", scrollBy: 120)
    }

    /// Pinned: after scrolling 120pt into WORKTREES, the strip under the filter header (the section header's 30pt)
    /// is pixel for pixel what it was before scrolling, while the rows below it moved.
    func testSectionHeaderStaysPinnedWhileScrolling() throws {
        let state = AppState.mockup(layoutStore: store)
        let size = CGSize(width: 220, height: 360)
        let still = try render(sidebar(state), size: size, name: "sidebar-573-still")
        let scrolled = try render(sidebar(state), size: size, name: "sidebar-573-pinned", scrollBy: 120)
        for (before, after) in zip(still, scrolled) {
            let scale = CGFloat(before.pixelsWide) / size.width
            func strip(_ bitmap: NSBitmapImageRep, from top: CGFloat, height: CGFloat) -> [UInt32] {
                var pixels: [UInt32] = []
                for y in Int(top * scale)..<Int((top + height) * scale) {
                    for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                        var value = [Int](repeating: 0, count: 4)
                        bitmap.getPixel(&value, atX: x, y: y)
                        pixels.append(UInt32(value[0] << 24 | value[1] << 16 | value[2] << 8 | value[3]))
                    }
                }
                return pixels
            }
            let header = Tokens.Size.panelHeader
            XCTAssertEqual(
                strip(before, from: header, height: SidebarSectionHeader.height),
                strip(after, from: header, height: SidebarSectionHeader.height), "the section header stays")
            XCTAssertNotEqual(
                strip(before, from: header + 60, height: 60), strip(after, from: header + 60, height: 60),
                "the rows scrolled")
        }
    }

    /// Review of #573: the sidebar list is lazy, so with ISSUES below the visible rows its section may not exist yet
    /// when `⌘4` arrives. The sidebar scrolls to it, and the section opens and handles the request once it appears.
    func testCommandFourReachesIssuesBelowTheVisibleRows() async throws {
        let state = AppState.mockup(layoutStore: store)
        let issues = try XCTUnwrap(state.issueListModel, "the mockup has issues")
        let size = CGSize(width: 220, height: 300)
        func view(_ request: PanelFocusRequest?) -> AnyView {
            AnyView(
                sidebar(state).environment(\.panelFocusRequest, request)
                    .frame(width: size.width, height: size.height).background(Tokens.Color.surfacePanel))
        }
        let host = NSHostingView(rootView: view(nil))
        host.frame = NSRect(origin: .zero, size: size)
        // An offscreen window that is never ordered in: scrolling needs one, and nothing on screen changes.
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        let scrollView = try XCTUnwrap(Self.scrollView(in: host))
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0)
        _ = issues

        host.rootView = view(PanelFocusRequest(panel: .issues))
        let deadline = ContinuousClock.now + .seconds(3)
        while scrollView.contentView.bounds.origin.y == 0, ContinuousClock.now < deadline {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertGreaterThan(scrollView.contentView.bounds.origin.y, 0, "scrolled down to ISSUES")

        // Another panel's request leaves a sidebar at the top where it is.
        host.rootView = view(nil)
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        host.layoutSubtreeIfNeeded()
        host.rootView = view(PanelFocusRequest(panel: .detail))
        for _ in 0..<5 {
            host.layoutSubtreeIfNeeded()
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertEqual(scrollView.contentView.bounds.origin.y, 0)
    }

    /// The section takes a pending request when it appears and reports it handled, so it is used once.
    func testIssuesSectionTakesAPendingRequestWhenItAppears() throws {
        let issues = try XCTUnwrap(AppState.mockup(layoutStore: store).issueListModel)
        var handled = 0
        let section = IssueListSection(
            model: issues, selectedNumber: nil, onSelect: { _ in }, pendingFocus: UUID(),
            onFocusHandled: { handled += 1 })
        try render(LazyVStack { section }, size: CGSize(width: 220, height: 300), name: "sidebar-573-issues-pending")
        XCTAssertGreaterThanOrEqual(handled, 1)
    }

    /// The empty sidebar offers `Add Repository…` (screens.md, next step).
    func testEmptySidebarOffersAddRepository() throws {
        var added = 0
        let view = SidebarPanel(hasRepository: false, onAddRepository: { added += 1 })
        try render(view, size: CGSize(width: 220, height: 400), name: "sidebar-573-empty")
        XCTAssertEqual(added, 0)
    }

    func testFilterFieldAndInsetsMatchTheSpec() {
        XCTAssertEqual(SidebarFilterField.height, 24, "art-direction.md §6")
        XCTAssertEqual(SidebarInset.content, SidebarInset.row + Tokens.Spacing.sm)
        XCTAssertEqual(SidebarInset.content, 14)
    }
}

/// #573: which badges a worktree row keeps as the sidebar narrows (information-architecture.md §4.3).
final class WorktreeBadgeStepTests: XCTestCase {
    func testTheNameFirstThenBadgesByPriority() {
        let steps = WorktreeRow.badgeSteps(badgeCount: 2, hasPullRequest: true, hasIssue: true)
        XCTAssertEqual(
            steps.map { [$0.showsPullRequest, $0.showsIssue, $0.truncatesTitle] },
            [
                [true, true, false], [false, true, false], [false, false, false],
                [false, false, true], [false, false, true], [false, false, true],
            ])
        XCTAssertEqual(steps.map(\.badgeCount), [2, 2, 2, 2, 1, 0])
        // The whole name is tried with fewer extras before it is truncated.
        XCTAssertEqual(steps.firstIndex(where: \.truncatesTitle), 3)
    }

    func testRowsWithoutExtras() {
        XCTAssertEqual(
            WorktreeRow.badgeSteps(badgeCount: 0, hasPullRequest: false, hasIssue: false),
            [
                WorktreeRow.BadgeStep(showsPullRequest: false, showsIssue: false, badgeCount: 0, truncatesTitle: false),
                WorktreeRow.BadgeStep(showsPullRequest: false, showsIssue: false, badgeCount: 0, truncatesTitle: true),
            ])
        XCTAssertEqual(
            WorktreeRow.badgeSteps(badgeCount: 1, hasPullRequest: false, hasIssue: true).map(\.showsIssue),
            [true, false, false, false])
    }

    /// Review of #573: what a narrow row hides stays in its tooltip (information-architecture.md §4.3): the status
    /// badges' facts, `#n`, and the PR.
    func testHiddenBadgesStayInTheTooltip() throws {
        let model = WorktreeListModel(listing: .mockup, focused: nil, home: "/tmp/dev")
        let row = try XCTUnwrap(model.rows.first { $0.issueNumber != nil })
        XCTAssertTrue(row.help.contains("Issue \(row.issueNumber ?? 0)"), row.help)
        XCTAssertTrue(row.help.contains("↑"), "ahead/behind: \(row.help)")
        let pullRequest = PullRequestBadge(
            PullRequest(
                number: 7, title: "Rate limit", state: .open, isDraft: false,
                head: PullRequest.Head(owner: "team", name: "app", branch: "feat/42-rate-limit"), baseRefName: "main",
                reviewDecision: .none, updatedAt: nil, url: URL(string: "https://github.com/team/app/pull/7")!))
        let help = WorktreeRowView.help(row, pullRequest: pullRequest)
        XCTAssertTrue(help.hasPrefix(row.help))
        XCTAssertTrue(help.contains("Pull request #7"), help)
        XCTAssertEqual(WorktreeRowView.help(row, pullRequest: nil), row.help)
    }
}
