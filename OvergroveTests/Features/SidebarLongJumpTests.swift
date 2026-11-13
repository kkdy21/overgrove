import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// Long jumps in a long sidebar (#647): 80 worktrees, 200 remote branches, and 21 issues, in a titled window like the
/// main window. The scroll view's own offset is checked as well as the row frame registry the sidebar reads: with all
/// 80 worktree rows in one child of the lazy stack, it guessed the other rows that tall, scrolled past the end on
/// `⌘↓`, built no row, and found nothing to scroll back to on `⌘↑`. A filter that hid the worktrees (#636's test)
/// kept the guesses right.
@MainActor
final class SidebarLongJumpTests: XCTestCase {
    private var suiteName: String!
    private var store: PanelLayoutStore!

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        store = PanelLayoutStore(defaults: UserDefaults(suiteName: suiteName) ?? .standard)
    }

    override func tearDown() async throws {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
    }

    private static func scrollView(in view: NSView) -> NSScrollView? {
        if let scroll = view as? NSScrollView { return scroll }
        return view.subviews.lazy.compactMap(scrollView(in:)).first
    }

    func testCommandArrowsReachBothEndsOfALongSidebar() async throws {
        let state = AppState(layoutStore: store, registry: .preview)
        let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: "acme"))
        var entries = [
            WorktreeListing.entry(
                "/tmp/dev/api", branch: "main", isMain: true, state: .loaded(WorktreeListing.state(branch: "main")))
        ]
        for index in 1..<80 {
            let branch = String(format: "feat/%03d-work", index)
            entries.append(
                WorktreeListing.entry(
                    "/tmp/dev/api-wt/\(index)", branch: branch,
                    state: .loaded(WorktreeListing.state(branch: branch, unstaged: index % 3))))
        }
        state.showForPreview(WorktreeListing(entries: entries, isPartial: false))
        let worktreeModel = try XCTUnwrap(state.worktreeListModel)
        XCTAssertEqual(worktreeModel.rows.count, 80)
        func tip(_ index: Int) -> ObjectID { ObjectID(String(format: "%040x", index + 1))! }
        let remote = (0..<200).map { index in
            Branch(
                fullName: String(format: "refs/remotes/origin/b%03d", index), kind: .remote(remote: "origin"),
                target: tip(index), upstreamStatus: .none, isHead: false, committerDate: nil, symbolicTarget: nil)
        }
        let local = Branch(
            fullName: "refs/heads/main", kind: .local, target: tip(500), upstreamStatus: .none, isHead: true,
            committerDate: nil, symbolicTarget: nil)
        let branchModel = BranchListModel(
            refs: RefParser.Listing(branches: [local] + remote, tags: [], isPartial: false, skippedRecords: 0),
            checkedOut: [], remoteNames: ["origin"])
        let issues = (1...21).map {
            IssueModelsTests.issue($0, String(format: "Issue %03d", $0), updated: TimeInterval(1_000 - $0))
        }
        let issueModel = IssueListModel(
            content: .loaded(repository: .github(IssueModelsTests.repository), issues: issues), isLoading: false)
        final class Box {
            var worktree: GitPath?
            var commit: ObjectID?
            var issue: Int?
        }
        let box = Box()
        let frames = SidebarRowFrames()
        box.worktree = worktreeModel.rows[0].id
        let size = CGSize(width: 256, height: 640)
        func view(_ request: PanelFocusRequest?) -> AnyView {
            AnyView(
                SidebarPanel(
                    hasRepository: true, worktreeStatus: state.worktreeList, worktreeModel: worktreeModel,
                    selectedWorktree: box.worktree,
                    onSelectWorktree: {
                        box.worktree = $0
                        box.commit = nil
                        box.issue = nil
                    },
                    branchModel: branchModel, selectedCommit: box.commit,
                    issueModel: issueModel, selectedIssue: box.issue,
                    onSelectIssue: {
                        box.issue = $0
                        box.worktree = nil
                        box.commit = nil
                    }
                )
                .environment(\.panelFocusRequest, request)
                .environment(\.sidebarRowFrames, frames)
                .environment(
                    \.rowMenu,
                    RowMenuActions(showCommit: {
                        box.commit = $0
                        box.worktree = nil
                        box.issue = nil
                    })
                )
                .frame(width: size.width, height: size.height))
        }
        let host = NSHostingView(rootView: view(nil))
        let window = NSWindow(
            contentRect: NSRect(x: -10_000, y: -10_000, width: size.width, height: size.height),
            styleMask: [.titled, .fullSizeContentView, .resizable], backing: .buffered, defer: false)
        window.contentView = host
        defer { window.contentView = nil }
        host.layoutSubtreeIfNeeded()
        host.rootView = view(PanelFocusRequest(panel: .sidebar))
        func settle(_ count: Int = 12) async throws {
            for _ in 0..<count {
                host.layoutSubtreeIfNeeded()
                try await Task.sleep(for: .milliseconds(16))
            }
        }
        try await settle()
        let scrollView = try XCTUnwrap(Self.scrollView(in: host))
        func press(down: Bool) async throws {
            let key = down ? NSDownArrowFunctionKey : NSUpArrowFunctionKey
            let character = String(Character(Unicode.Scalar(key)!))
            let event = try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [.function, .numericPad, .command], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: character,
                    charactersIgnoringModifiers: character, isARepeat: false, keyCode: down ? 125 : 126))
            window.sendEvent(event)
            host.rootView = view(nil)
            try await settle()
        }
        func offsets() -> (offset: CGFloat, maxOffset: CGFloat, document: CGFloat) {
            let clip = scrollView.contentView
            let document = scrollView.documentView?.frame.height ?? 0
            return (clip.bounds.origin.y, max(0, document - clip.bounds.height), document)
        }
        let visibleHeight = scrollView.contentView.bounds.height
        /// Rows are drawn (not an empty sidebar) and `id`'s row is below the pinned header and above the bottom.
        func assertShown(_ id: String, _ label: String, file: StaticString = #filePath, line: UInt = #line) throws {
            let shown = frames.frames.values.filter { $0.maxY > 0 && $0.minY < visibleHeight }
            XCTAssertGreaterThan(shown.count, 5, "\(label): rows are drawn", file: file, line: line)
            let frame = try XCTUnwrap(frames.frames[id], "\(label): the row is built", file: file, line: line)
            XCTAssertGreaterThanOrEqual(
                frame.minY, SidebarSectionHeader.height - 0.5, "\(label): below the header \(frame)", file: file,
                line: line)
            XCTAssertLessThanOrEqual(
                frame.maxY, visibleHeight + 0.5, "\(label): above the bottom \(frame)", file: file, line: line)
        }
        for round in 1...2 {
            try await press(down: true)
            XCTAssertEqual(box.issue, 21, "⌘↓ \(round)")
            var now = offsets()
            XCTAssertEqual(now.offset, now.maxOffset, accuracy: 1, "⌘↓ \(round): scrolled to the end \(now)")
            try assertShown(SidebarItem.issue(21).scrollID, "⌘↓ \(round)")
            try await press(down: false)
            XCTAssertEqual(box.worktree, worktreeModel.rows[0].id, "⌘↑ \(round)")
            now = offsets()
            XCTAssertEqual(now.offset, 0, accuracy: 1, "⌘↑ \(round): scrolled to the top \(now)")
            try assertShown(worktreeModel.rows[0].sidebarScrollID, "⌘↑ \(round)")
        }
    }
}
