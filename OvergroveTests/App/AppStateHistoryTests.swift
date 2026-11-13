import Foundation
import XCTest

@testable import Overgrove

/// `AppState` S-09 flows (#70).
@MainActor
final class AppStateHistoryTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func loadedState(_ loader: StubFileHistoryLoader) async -> AppState {
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(result: .success(.mockup)), commitLoader: StubCommitLoader(),
            historyLoader: loader)
        let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        state.reload()
        await state.loadTask?.value
        return state
    }

    func testShowHistoryUsesTheWorktreeAndItsHead() async {
        let loader = StubFileHistoryLoader([FileHistoryStoreTests.page(0..<2)])
        let state = await loadedState(loader)
        state.selectWorktree(GitPath("/tmp/dev/api-wt/42-rate-limit"))
        // A WIP file's history is asked in its own worktree; others in the focused one.
        state.showHistory(of: GitPath("src/a.swift"), in: GitPath("/tmp/dev/api-wt/login"))
        await state.history.task?.value
        XCTAssertEqual(loader.requests.first?.key.worktree, GitPath("/tmp/dev/api-wt/login"))
        XCTAssertEqual(loader.requests.first?.key.path, GitPath("src/a.swift"))
        XCTAssertNotNil(loader.requests.first?.key.head)
        state.showHistory(of: GitPath("src/b.swift"))
        await state.history.task?.value
        XCTAssertEqual(loader.requests.last?.key.worktree, GitPath("/tmp/dev/api-wt/42-rate-limit"))
        XCTAssertTrue(state.history.isOpen)

        // A path that is not valid UTF-8 opens nothing.
        state.closeHistory()
        state.showHistory(of: GitPath(raw: Data([0x61, 0xFF])))
        XCTAssertFalse(state.history.isOpen)
    }

    func testRowsShowS03AndReturnOpensS10() async {
        let entries = [
            FileHistoryStoreTests.entry(0), FileHistoryStoreTests.entry(1, path: "Status.swift", from: "Parser.swift"),
        ]
        let state = await loadedState(
            StubFileHistoryLoader([.page(LogParser.FileHistoryPage(entries: entries, isPartial: false))]))
        state.showHistory(of: GitPath("Status.swift"))
        await state.history.task?.value

        state.selectHistoryEntry(entries[0])
        XCTAssertEqual(state.selection, .commit(entries[0].id), "S-03 even for a commit the graph has not loaded")
        XCTAssertEqual(state.commitDetail.commit?.oid, entries[0].id)
        XCTAssertEqual(state.history.selected, entries[0].id)
        XCTAssertNil(state.diffViewer)

        state.openHistoryDiff(entries[1])
        await state.commitDetail.fileTask?.value
        XCTAssertEqual(state.commitDetail.selectedFile?.path, GitPath("Status.swift"))
        XCTAssertEqual(state.commitDetail.selectedFile?.originalPath, GitPath("Parser.swift"))
        XCTAssertNotNil(state.diffViewer)
        XCTAssertEqual(state.shownFileHistoryTarget?.path, GitPath("Status.swift"))

        // ⎋ in S-10 goes back to the history; ⎋ there goes back to the graph.
        state.clearSelectedFile()
        XCTAssertNil(state.diffViewer)
        XCTAssertTrue(state.history.isOpen)
        state.closeHistory()
        XCTAssertFalse(state.history.isOpen)
    }

    /// #659: S-10 opened from a history row shows the commit's real change kind, not `M` for every row.
    func testS10FromHistoryShowsTheChangeKind() async {
        let created = FileHistoryStoreTests.entry(0, path: "conflict.txt")
        let renamed = FileHistoryStoreTests.entry(1, path: "Status.swift", from: "Parser.swift")
        let edited = FileHistoryStoreTests.entry(2, path: "conflict.txt")
        let commits = StubCommitLoader()
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(result: .success(.mockup)), commitLoader: commits,
            historyLoader: StubFileHistoryLoader([
                .page(LogParser.FileHistoryPage(entries: [edited, renamed, created], isPartial: false))
            ]))
        let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        state.reload()
        await state.loadTask?.value
        state.showHistory(of: GitPath("conflict.txt"))
        await state.history.task?.value

        commits.patchText =
            "diff --git a/conflict.txt b/conflict.txt\nnew file mode 100644\n--- /dev/null\n+++ b/conflict.txt\n"
            + "@@ -0,0 +1 @@\n+x\n"
        state.openHistoryDiff(created)
        await state.commitDetail.fileTask?.value
        XCTAssertEqual(state.diffViewer?.source, "\(created.commit.oid.short) · A")

        commits.patchText =
            "diff --git a/Parser.swift b/Status.swift\nsimilarity index 100%\n"
            + "rename from Parser.swift\nrename to Status.swift\n"
        state.openHistoryDiff(renamed)
        await state.commitDetail.fileTask?.value
        XCTAssertEqual(state.diffViewer?.source, "\(renamed.commit.oid.short) · R")

        commits.patchText =
            "diff --git a/conflict.txt b/conflict.txt\n--- a/conflict.txt\n+++ b/conflict.txt\n@@ -1 +1 @@\n-x\n+y\n"
        state.openHistoryDiff(edited)
        await state.commitDetail.fileTask?.value
        XCTAssertEqual(state.diffViewer?.source, "\(edited.commit.oid.short) · M")
    }

    /// The file row menu's Show History (#73's `FileRowMenu`) opens S-09 in the row's worktree.
    func testRowMenuShowHistory() async {
        let loader = StubFileHistoryLoader([FileHistoryStoreTests.page(0..<1)])
        let state = await loadedState(loader)
        state.rowMenuActions.showHistory(GitPath("/tmp/dev/api-wt/login"), GitPath("src/a.swift"))
        await state.history.task?.value
        XCTAssertTrue(state.history.isOpen)
        XCTAssertEqual(loader.requests.first?.key.worktree, GitPath("/tmp/dev/api-wt/login"))
    }

    func testWorktreeSelectionAndAnotherRepositoryClose() async {
        let state = await loadedState(StubFileHistoryLoader([FileHistoryStoreTests.page(0..<1)]))
        state.showHistory(of: GitPath("Status.swift"))
        await state.history.task?.value
        state.selectWorktree(GitPath("/tmp/dev/api"))
        XCTAssertFalse(state.history.isOpen, "the center goes back to the graph")

        state.showHistory(of: GitPath("Status.swift"))
        let root = URL(fileURLWithPath: "/tmp/dev/web", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        XCTAssertFalse(state.history.isOpen)
    }
}
