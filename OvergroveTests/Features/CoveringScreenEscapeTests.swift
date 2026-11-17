import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// `⎋` reaching the window's handler while S-11 or S-12 covers the graph (#693, #701), in the real main window view.
/// The window is offscreen and never ordered in, so it is not key: these tests send `⎋` straight to the window, past the
/// app's key monitor (`EscapeFocusMonitorTests` covers that one).
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
            loader: StubRepositoryLoader(result: .success(WorktreeListing.mockup)),
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
        window.sendEvent(
            try XCTUnwrap(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, characters: "\u{1b}",
                    charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
        settle()
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

    /// #701: S-11, opened over the focused graph as the toolbar's Compare and `⌘⇧B` do, takes `⌘2`, and `⎋` then
    /// reaches the window's handler: S-11 closes and the selection stays. The next `⎋` goes on to ③.
    func testEscapeClosesTheComparisonOpenedOverTheFocusedGraph() async throws {
        let state = try await loadedState()
        let focused = try XCTUnwrap(state.focusedWorktreePath)
        let window = window(state)
        defer { window.close() }
        settle()
        state.selectCommit(base)
        state.focus(.center)
        settle()

        state.showComparison()
        settle()
        XCTAssertNotNil(state.comparison)
        state.focus(.center)
        settle()
        XCTAssertFalse(
            window.firstResponder === window, "⌘2 focuses S-11: \(String(describing: window.firstResponder))")

        try pressEscape(in: window)
        XCTAssertNil(state.comparison, "⎋ closes S-11")
        XCTAssertEqual(state.selection, .commit(base), "the main selection stays")

        try pressEscape(in: window)
        XCTAssertEqual(state.selection, .wip(focused), "③ once nothing covers the graph")
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
