import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// `⎋` and `⌘2` while a screen covers the graph (S-09 to S-12; #693, #709), in the real main window view. The window is
/// offscreen and never ordered in, so it cannot be key. A key press goes the way the app sends it: the window's key
/// monitor (`EscapeFocusMonitor`) first, then the window.
@MainActor
final class CoveringScreenEscapeTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let base = SampleGraphLoader.oid("4")
    private let target = SampleGraphLoader.oid("1")

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func loadedState() async throws -> AppState {
        let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(result: .success(WorktreeListing.mockup)), diffLoader: StubDiffLoader(),
            comparisonLoader: StubComparisonLoader(), graphLoader: SampleGraphLoader(),
            commitLoader: StubCommitLoader(), historyLoader: StubFileHistoryLoader([FileHistoryStoreTests.page(0..<3)]))
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        state.reload()
        await state.loadTask?.value
        let deadline = ContinuousClock.now + .seconds(5)
        while state.graph.status != .loaded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(state.graph.status, .loaded)
        return state
    }

    /// The main window as the app shows it, toolbar included; offscreen and never ordered in.
    private func window(_ state: AppState) -> NSWindow {
        let controller = NSHostingController(rootView: MainWindowView(state: state))
        controller.sceneBridgingOptions = [.toolbars, .title]
        let window = NSWindow(contentViewController: controller)
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 1440, height: 900))
        return window
    }

    private func settle() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    }

    private func pressEscape(in window: NSWindow) throws {
        try press(53, "\u{1b}", in: window)
    }

    /// `NSApplication.sendEvent` runs the local key monitors before the window; `window.sendEvent` alone skips them.
    private func press(_ keyCode: UInt16, _ characters: String, in window: NSWindow) throws {
        let event = try XCTUnwrap(
            NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                keyCode: keyCode))
        let monitor = try XCTUnwrap(window.contentView.flatMap(Self.escapeMonitor), "the window's key monitor")
        if !monitor.consume(event) { window.sendEvent(event) }
        settle()
    }

    private static func escapeMonitor(in view: NSView) -> EscapeFocusMonitor.MonitorView? {
        if let monitor = view as? EscapeFocusMonitor.MonitorView { return monitor }
        return view.subviews.lazy.compactMap(escapeMonitor).first
    }

    private func pressDown(in window: NSWindow) throws {
        try press(125, String(UnicodeScalar(NSDownArrowFunctionKey)!), in: window)
    }

    /// `⌘2` focuses the center: after it, something in the window holds the focus, not the window itself.
    private func focusCenter(_ state: AppState, in window: NSWindow, _ screen: String) {
        state.focus(.center)
        settle()
        XCTAssertFalse(
            window.firstResponder === window, "⌘2 focuses \(screen): \(String(describing: window.firstResponder))")
    }

    /// #693: S-12, opened over the focused graph as a commit row's menu does, takes `⌘2` like S-09, and `⎋` then
    /// reaches the window's handler: S-12 closes and the base commit stays selected. The next `⎋` goes on to ③.
    func testEscapeClosesTheCommitComparisonFocusedWithCommandTwo() async throws {
        let state = try await loadedState()
        let focused = try XCTUnwrap(state.focusedWorktreePath)
        let window = window(state)
        defer { window.close() }
        settle()
        state.selectCommit(base)
        state.focus(.center)
        settle()

        state.showCommitComparison(with: target)
        settle()
        XCTAssertNotNil(state.commitComparison)
        state.focus(.center)
        settle()
        XCTAssertFalse(
            window.firstResponder === window, "⌘2 focuses S-12: \(String(describing: window.firstResponder))")

        try pressEscape(in: window)
        XCTAssertNil(state.commitComparison, "⎋ closes S-12")
        XCTAssertEqual(state.selection, .commit(base), "the main selection stays")

        try pressEscape(in: window)
        XCTAssertEqual(state.selection, .wip(focused), "③ once nothing covers the graph")
    }

    // MARK: S-10 (#709) and the other ways to open a screen over the graph
    //
    // While a screen covers the graph, the key monitor closes it on `⎋` wherever the focus is, unless text is being
    // typed. The ways in, with the test for each:
    // - S-10 from S-03 (the graph keeps the focus): `testEscapeClosesTheDiffOfACommitFileOpenedOverTheFocusedGraph`
    // - S-10 from S-04: the same S-10 view as from S-03, with the graph or the sidebar focused before it
    // - S-10 from an S-09 row: `testEscapeClosesTheDiffOpenedFromFileHistoryAndShowsTheHistoryAgain`
    // - S-10 from S-02 (the file list has the focus): `testTheDetailFileListKeepsTheFocusWhenItOpensTheDiff`
    // - S-09 from S-10's Show History or a file row's menu: `testEscapeStillClosesFileHistory`
    // - S-11 from the sidebar's worktree row menu: `testEscapeClosesTheComparisonOpenedFromTheSidebar`; from the
    //   toolbar or `⌘⇧B`: #701
    // - S-12 from a graph row's menu: `testEscapeClosesTheCommitComparisonFocusedWithCommandTwo` (#693)

    /// #709: S-10 opened from S-03 over the focused graph closes on `⎋`, and the commit stays selected. `⌘2` focuses
    /// S-10 while it covers the graph (interaction.md §3.1).
    func testEscapeClosesTheDiffOfACommitFileOpenedOverTheFocusedGraph() async throws {
        let state = try await loadedState()
        let window = window(state)
        defer { window.close() }
        settle()
        let commit = SampleGraphLoader.commits[1].oid
        state.selectCommit(commit)
        state.focus(.center)
        await state.commitDetail.task?.value
        settle()
        guard case .loaded(let rows, _) = state.commitDetailModel?.files else { return XCTFail("files") }

        state.selectCommitFile(rows[0].stat)
        await state.commitDetail.fileTask?.value
        settle()
        XCTAssertNotNil(state.diffViewer)
        try pressEscape(in: window)
        XCTAssertNil(state.diffViewer, "⎋ closes S-10")
        XCTAssertEqual(state.selection, .commit(commit), "the main selection stays")

        state.selectCommitFile(rows[0].stat)
        await state.commitDetail.fileTask?.value
        settle()
        focusCenter(state, in: window, "S-10")
        try pressEscape(in: window)
        XCTAssertNil(state.diffViewer, "⎋ closes S-10 focused with ⌘2")
    }

    /// #709: S-10 opened from a row of the focused S-09 takes S-09's place. `⎋` closes S-10 and S-09 shows again; the
    /// next `⎋` closes S-09. Before #709 that second `⎋` left S-09 open: the focus SwiftUI held there took no key events,
    /// and the key monitor let `⎋` through because the window was not without focus.
    func testEscapeClosesTheDiffOpenedFromFileHistoryAndShowsTheHistoryAgain() async throws {
        let state = try await loadedState()
        let window = window(state)
        defer { window.close() }
        settle()
        state.showHistory(of: GitPath("a.go"))
        await state.history.task?.value
        settle()
        focusCenter(state, in: window, "S-09")
        let entry = try XCTUnwrap(state.history.entries.first)

        state.openHistoryDiff(entry)
        await state.commitDetail.task?.value
        await state.commitDetail.fileTask?.value
        settle()
        XCTAssertNotNil(state.diffViewer)
        XCTAssertTrue(state.history.isOpen)

        try pressEscape(in: window)
        XCTAssertNil(state.diffViewer, "⎋ closes S-10")
        XCTAssertTrue(state.history.isOpen, "S-09 shows again")
        try pressEscape(in: window)
        XCTAssertFalse(state.history.isOpen, "the next ⎋ closes S-09")
    }

    /// S-10 opened from S-02's file list leaves the focus there: `↓` moves on to the next file, which S-10 shows. `⎋`
    /// closes S-10 and the focus stays in the list, so the next `↓` opens a file again.
    func testTheDetailFileListKeepsTheFocusWhenItOpensTheDiff() async throws {
        let state = try await loadedState()
        let worktree = GitPath("/tmp/dev/api-wt/42-rate-limit")
        let window = window(state)
        defer { window.close() }
        state.selectWorktree(worktree)
        settle()
        state.focus(.detail)
        settle()

        state.selectFile(FileSelection(worktree: worktree, group: .staged, path: GitPath("staged0.swift")))
        settle()
        XCTAssertNotNil(state.diffViewer)
        try pressDown(in: window)
        XCTAssertEqual(state.selectedFile?.path, GitPath("staged1.swift"), "↓ in the file list moves to the next file")
        XCTAssertNotNil(state.diffViewer)

        try pressEscape(in: window)
        XCTAssertNil(state.diffViewer)
        try pressDown(in: window)
        XCTAssertNotNil(state.selectedFile, "the file list still has the focus")
    }

    /// S-11 opened from the sidebar's worktree row menu closes on `⎋`.
    func testEscapeClosesTheComparisonOpenedFromTheSidebar() async throws {
        let state = try await loadedState()
        let window = window(state)
        defer { window.close() }
        settle()
        state.focus(.sidebar)
        settle()

        state.showComparison(of: GitPath("/tmp/dev/api-wt/42-rate-limit"))
        settle()
        XCTAssertNotNil(state.comparison)
        try pressEscape(in: window)
        XCTAssertNil(state.comparison)
    }

    /// S-09 is unchanged: `⌘2` focuses it while it covers the graph, and `⎋` closes it.
    func testEscapeStillClosesFileHistory() async throws {
        let state = try await loadedState()
        let window = window(state)
        defer { window.close() }
        settle()
        state.showHistory(of: GitPath("a.go"))
        await state.history.task?.value
        settle()
        XCTAssertTrue(state.history.isOpen)
        state.focus(.center)
        settle()

        try pressEscape(in: window)
        XCTAssertFalse(state.history.isOpen)
    }
}
