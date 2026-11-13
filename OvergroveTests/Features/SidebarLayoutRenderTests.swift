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

    /// #592: the sidebar is one focus unit. After `⌘1`, `↓` moves from the focused worktree to the next row, and from
    /// the last worktree on into LOCAL, as a click on that row would.
    func testArrowKeysMoveAcrossSections() async throws {
        let state = AppState.mockup(layoutStore: store)
        let rows = try XCTUnwrap(state.worktreeListModel?.rows.map(\.id))
        XCTAssertGreaterThan(rows.count, 1)
        final class Box {
            var worktrees: [GitPath] = []
            var commits: [ObjectID] = []
        }
        let box = Box()
        let size = CGSize(width: 220, height: 400)
        func view(_ focused: GitPath, _ request: PanelFocusRequest?) -> AnyView {
            AnyView(
                SidebarPanel(
                    hasRepository: true, worktreeStatus: state.worktreeList, worktreeModel: state.worktreeListModel,
                    selectedWorktree: focused, onSelectWorktree: { box.worktrees.append($0) }, branchModel: branches
                )
                .environment(\.panelFocusRequest, request)
                .environment(\.rowMenu, RowMenuActions(showCommit: { box.commits.append($0) }))
                .frame(width: size.width, height: size.height))
        }
        let host = NSHostingView(rootView: view(rows[0], nil))
        host.frame = NSRect(origin: .zero, size: size)
        // Offscreen and never ordered in: nothing on screen changes, no mouse, no app focus.
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        host.rootView = view(rows[0], PanelFocusRequest(panel: .sidebar))
        func settle() async throws {
            for _ in 0..<5 {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        func press(_ key: Int, keyCode: UInt16) async throws {
            let character = String(Character(Unicode.Scalar(key)!))
            let event = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: character, charactersIgnoringModifiers: character, isARepeat: false,
                    keyCode: keyCode))
            window.sendEvent(event)
            try await settle()
        }
        try await settle()
        try await press(NSDownArrowFunctionKey, keyCode: 125)
        XCTAssertEqual(box.worktrees, [rows[1]], "↓ from the focused worktree")

        // From the last worktree, `↓` crosses into LOCAL and selects the first branch's tip.
        box.worktrees = []
        host.rootView = view(rows[rows.count - 1], PanelFocusRequest(panel: .sidebar))
        try await settle()
        try await press(NSDownArrowFunctionKey, keyCode: 125)
        XCTAssertEqual(box.worktrees, [], "no worktree after the last")
        XCTAssertEqual(box.commits.count, 1, "the first LOCAL branch's tip")
    }

    /// Review of #598: `⌘↓` to a row far down a long, lazily built list (400 REMOTE branches, opened by the filter)
    /// still scrolls it into view, not only selects it.
    func testCommandDownScrollsToARowTheLazyListHasNotBuilt() async throws {
        let state = AppState.mockup(layoutStore: store)
        let oid = ObjectID(String(repeating: "ab", count: 20))!
        let names = (0..<400).map { String(format: "refs/remotes/origin/b%03d", $0) }
        let refs = RefParser.Listing(
            branches: names.map {
                Branch(
                    fullName: $0, kind: .remote(remote: "origin"), target: oid, upstreamStatus: .none, isHead: false,
                    committerDate: nil, symbolicTarget: nil)
            }, tags: [], isPartial: false, skippedRecords: 0)
        let model = BranchListModel(refs: refs, checkedOut: [], remoteNames: ["origin"])
        final class Box { var commits: [ObjectID] = [] }
        let box = Box()
        let size = CGSize(width: 220, height: 400)
        func view(_ request: PanelFocusRequest?) -> AnyView {
            AnyView(
                SidebarPanel(
                    hasRepository: true, worktreeStatus: state.worktreeList, worktreeModel: state.worktreeListModel,
                    selectedWorktree: state.worktreeListModel?.rows.first?.id, branchModel: model,
                    filter: .constant("b")
                )
                .environment(\.panelFocusRequest, request)
                .environment(\.rowMenu, RowMenuActions(showCommit: { box.commits.append($0) }))
                .frame(width: size.width, height: size.height))
        }
        let host = NSHostingView(rootView: view(nil))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        host.rootView = view(PanelFocusRequest(panel: .sidebar))
        func settle(_ count: Int = 5) async throws {
            for _ in 0..<count {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
        }
        try await settle()
        let scrollView = try XCTUnwrap(Self.scrollView(in: host))
        let character = String(Character(Unicode.Scalar(NSDownArrowFunctionKey)!))
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [.command, .function, .numericPad], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: character,
                charactersIgnoringModifiers: character, isARepeat: false, keyCode: 125))
        window.sendEvent(event)
        try await settle(20)
        XCTAssertEqual(box.commits.count, 1, "⌘↓ selected the last row's tip")
        let afterKey = scrollView.contentView.bounds.minY
        XCTAssertGreaterThan(afterKey, 1_000, "scrolled far down the list")
        // The lazy stack's document height is an estimate until rows are measured, so find the real bottom by
        // scrolling there until it stops moving. Below the last branch row are TAGS (header and "No matching tags")
        // and STASHES (header and "No stashes"), about 116pt; the row is in view when the key left the sidebar within
        // that of the bottom.
        var bottom = -1.0
        for _ in 0..<20 where bottom != scrollView.contentView.bounds.minY {
            bottom = scrollView.contentView.bounds.minY
            let height = scrollView.documentView?.frame.height ?? 0
            scrollView.contentView.scroll(to: NSPoint(x: 0, y: max(0, height - scrollView.contentView.bounds.height)))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            try await settle(2)
        }
        let below = 2 * SidebarSectionHeader.height + 2 * Tokens.Size.rowSidebar
        XCTAssertGreaterThanOrEqual(afterKey, bottom - below - 4, "the last row is in view (bottom \(bottom))")
    }

    /// #636: in a long sidebar, `⌘↓` and `⌘↑` (three times each) and `↑` steps past the top of the view always leave
    /// the selected row fully in view and below the pinned section header, with real key events.
    func testJumpsAndStepsKeepTheRowInViewBelowTheHeader() async throws {
        let state = AppState.mockup(layoutStore: store)
        func tip(_ index: Int) -> ObjectID { ObjectID(String(format: "%040x", index + 1))! }
        let names = (0..<400).map { String(format: "refs/remotes/origin/b%03d", $0) }
        let refs = RefParser.Listing(
            branches: names.enumerated().map { index, name in
                Branch(
                    fullName: name, kind: .remote(remote: "origin"), target: tip(index), upstreamStatus: .none,
                    isHead: false, committerDate: nil, symbolicTarget: nil)
            }, tags: [], isPartial: false, skippedRecords: 0)
        let model = BranchListModel(refs: refs, checkedOut: [], remoteNames: ["origin"])
        final class Box {
            var selected: GitPath?
            var commit: ObjectID?
            var worktree: GitPath?
        }
        let box = Box()
        let frames = SidebarRowFrames()
        let worktrees = try XCTUnwrap(state.worktreeListModel?.rows.map(\.id))
        let size = CGSize(width: 220, height: 400)
        func view(_ request: PanelFocusRequest?) -> AnyView {
            AnyView(
                SidebarPanel(
                    hasRepository: true, worktreeStatus: state.worktreeList, worktreeModel: state.worktreeListModel,
                    selectedWorktree: box.worktree ?? worktrees[0], onSelectWorktree: { box.worktree = $0 },
                    branchModel: model, selectedCommit: box.commit, filter: .constant("b")
                )
                .environment(\.panelFocusRequest, request)
                .environment(\.sidebarRowFrames, frames)
                .environment(\.rowMenu, RowMenuActions(showCommit: { box.commit = $0 }))
                .frame(width: size.width, height: size.height))
        }
        let host = NSHostingView(rootView: view(nil))
        host.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
            styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        host.rootView = view(PanelFocusRequest(panel: .sidebar))
        func settle(_ count: Int = 8) async throws {
            for _ in 0..<count {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(30))
            }
        }
        try await settle()
        let scrollView = try XCTUnwrap(Self.scrollView(in: host))
        // The visible height of the list, below the 40pt filter header.
        let visibleHeight = scrollView.contentView.bounds.height
        func press(down: Bool, command: Bool) async throws {
            let key = down ? NSDownArrowFunctionKey : NSUpArrowFunctionKey
            let character = String(Character(Unicode.Scalar(key)!))
            var flags: NSEvent.ModifierFlags = [.function, .numericPad]
            if command { flags.insert(.command) }
            let event = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: character,
                    charactersIgnoringModifiers: character, isARepeat: false, keyCode: down ? 125 : 126))
            window.sendEvent(event)
            // The selection lives in the box; hand it back as the app would.
            host.rootView = view(nil)
            try await settle()
        }
        func selectedID() -> String? {
            if let commit = box.commit, let index = (0..<400).first(where: { tip($0) == commit }) {
                return SidebarItem.branch(id: names[index], tip: commit).scrollID
            }
            return box.worktree.map { SidebarItem.worktree($0).scrollID }
        }
        func assertInView(_ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let id = try XCTUnwrap(selectedID(), label, file: file, line: line)
            let frame = try XCTUnwrap(frames.frames[id], "\(label): the row is built", file: file, line: line)
            XCTAssertGreaterThanOrEqual(
                frame.minY, SidebarSectionHeader.height - 0.5, "\(label): below the header \(frame)", file: file,
                line: line)
            XCTAssertLessThanOrEqual(
                frame.maxY, visibleHeight + 0.5, "\(label): above the bottom \(frame)", file: file,
                line: line)
        }
        for round in 1...3 {
            box.worktree = nil
            try await press(down: true, command: true)
            XCTAssertEqual(box.commit, tip(399), "⌘↓ \(round)")
            try assertInView("⌘↓ \(round)")
            box.commit = nil
            try await press(down: false, command: true)
            // The filter (`b`) leaves no worktree, so the first row is the first branch.
            XCTAssertEqual(box.commit, tip(0), "⌘↑ \(round)")
            try assertInView("⌘↑ \(round)")
        }
        // From the last row, `↑` twenty times: past the top of the view, the row above must not hide under the header.
        try await press(down: true, command: true)
        for step in 1...20 {
            try await press(down: false, command: false)
            try assertInView("↑ \(step)")
        }
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
