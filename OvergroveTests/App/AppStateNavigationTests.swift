import Foundation
import XCTest

@testable import Overgrove

/// Records what row menus and copy commands hand to the pasteboard and Finder.
final class RecordingRowActions: RowActionPerforming, @unchecked Sendable {
    private let lock = NSLock()
    private var copiedTexts: [String] = []
    private var revealedURLs: [URL] = []
    private var terminalURLs: [URL] = []
    private var openedURLs: [URL] = []

    var copied: [String] { lock.withLock { copiedTexts } }
    var revealed: [URL] { lock.withLock { revealedURLs } }
    var terminals: [URL] { lock.withLock { terminalURLs } }
    var opened: [URL] { lock.withLock { openedURLs } }
    /// Apps that are "installed" (#124); Terminal by default.
    var installed: [String: String] = [ExternalApps.defaultTerminal: "Terminal"]
    private var appOpens: [(URL, String)] = []
    /// Everything opened in an app, with its bundle identifier.
    var openedInApps: [(item: URL, app: String)] { lock.withLock { appOpens.map { ($0.0, $0.1) } } }

    func copy(_ text: String) { lock.withLock { copiedTexts.append(text) } }
    func reveal(_ url: URL) { lock.withLock { revealedURLs.append(url) } }
    func open(_ item: URL, inApplication bundleIdentifier: String) -> Bool {
        guard installed[bundleIdentifier] != nil else { return false }
        lock.withLock {
            appOpens.append((item, bundleIdentifier))
            if bundleIdentifier == ExternalApps.defaultTerminal { terminalURLs.append(item) }
        }
        return true
    }
    func applicationName(_ bundleIdentifier: String) -> String? { installed[bundleIdentifier] }
    /// Where each installed app is; `/Applications/<name>.app` unless set.
    var locations: [String: URL] = [:]
    func applicationURL(_ bundleIdentifier: String) -> URL? {
        guard let name = installed[bundleIdentifier] else { return nil }
        return locations[bundleIdentifier] ?? URL(fileURLWithPath: "/Applications/\(name).app")
    }
    func openInBrowser(_ url: URL) { lock.withLock { openedURLs.append(url) } }
}

/// The sample graph with the mock listing's HEAD (`a91f3c2…`) on top, so `⌘J` has a loaded row to go to.
private struct HeadFirstGraphLoader: GraphLoading {
    static let head = ObjectID("a91f3c2000000000000000000000000000000000")!
    static let headCommit = CommitNode(
        oid: head, parents: [SampleGraphLoader.oid("1")], authorName: "Alice Example", authorEmail: "alice@example.com",
        authorDate: Date(timeIntervalSince1970: 1_800_000_000), subject: "chore: head")

    func page(_ repository: Repository, skip: Int, limit: Int) async -> Result<GraphPageSnapshot, GitError> {
        let commits = [Self.headCommit] + SampleGraphLoader.commits
        let slice = skip < commits.count ? Array(commits[skip...].prefix(limit)) : []
        return .success(
            GraphPageSnapshot(
                commits: slice, isPartial: false,
                refSet: GraphRefSet(refs: SampleGraphLoader.refs, worktrees: [SampleGraphLoader.worktree]),
                refs: SampleGraphLoader.refs, worktrees: [SampleGraphLoader.worktree]))
    }
}

/// Keyboard navigation, copy commands, and row menu actions (interaction.md §3, §5, #73).
@MainActor
final class AppStateNavigationTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let repository = Repository(
        rootURL: URL(fileURLWithPath: "/tmp/dev/api"), commonGitDirectoryURL: URL(fileURLWithPath: "/tmp/dev/api/.git"),
        isBare: false)

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func loadedState(_ actions: RecordingRowActions = RecordingRowActions()) async throws -> AppState {
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(result: .success(WorktreeListing.mockup)), graphLoader: HeadFirstGraphLoader(),
            commitLoader: StubCommitLoader())
        state.rowActions = actions
        state.open(RepositoryContext(repository: repository, owner: nil))
        state.reload()
        await state.loadTask?.value
        let deadline = ContinuousClock.now + .seconds(5)
        while state.graph.status != .loaded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(state.graph.status, .loaded)
        return state
    }

    func testJumpToHeadSelectsAndScrollsToTheFocusedHead() async throws {
        let state = try await loadedState()
        state.selectCommit(SampleGraphLoader.oid("4"))
        XCTAssertTrue(state.canJumpToHead)

        state.jumpToHead()
        XCTAssertEqual(state.selection, .commit(HeadFirstGraphLoader.head))
        XCTAssertEqual(state.graph.selected, HeadFirstGraphLoader.head)
        let first = try XCTUnwrap(state.graph.scrollTarget)
        XCTAssertEqual(first.oid, HeadFirstGraphLoader.head)

        state.jumpToHead()
        XCTAssertNotEqual(state.graph.scrollTarget, first, "pressing ⌘J again scrolls again")
    }

    func testJumpToHeadIsOffWithoutALoadedHead() async throws {
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(result: .success(WorktreeListing.mockup)), graphLoader: SampleGraphLoader())
        XCTAssertFalse(state.canJumpToHead)
        state.jumpToHead()
        XCTAssertNil(state.selection)
        XCTAssertNil(state.graph.scrollTarget)
    }

    func testEscapeClearsTheSearchThenReturnsToTheWorktreeChanges() async throws {
        let state = try await loadedState()
        let focused = try XCTUnwrap(state.focusedWorktreePath)
        state.selectCommit(SampleGraphLoader.oid("3"))
        state.searchText = "limiter"

        state.escape()
        XCTAssertEqual(state.searchText, "", "② the search goes first")
        XCTAssertEqual(state.selection, .commit(SampleGraphLoader.oid("3")))

        state.escape()
        XCTAssertEqual(state.selection, .wip(focused), "③ back to the focused worktree's changes")
        XCTAssertNil(state.graph.selected)

        state.escape()
        XCTAssertEqual(state.selection, .wip(focused), "nothing left to clear")
    }

    func testShowWorktreeInfoTogglesTheSegment() async throws {
        let state = try await loadedState()
        let focused = try XCTUnwrap(state.focusedWorktreePath)
        XCTAssertTrue(state.canToggleWorktreeInfo)

        state.toggleWorktreeInfo()
        XCTAssertEqual(state.selection, .worktreeInfo(focused))
        state.toggleWorktreeInfo()
        XCTAssertEqual(state.selection, .wip(focused))

        state.selectCommit(SampleGraphLoader.oid("3"))
        state.toggleWorktreeInfo()
        XCTAssertEqual(state.selection, .worktreeInfo(focused), "from a commit, ⌘I opens the focused worktree's info")
    }

    func testFocusRequestsAreDistinctEachTime() async throws {
        let state = try await loadedState()
        state.focus(.detail)
        let first = try XCTUnwrap(state.panelFocusRequest)
        XCTAssertEqual(first.panel, .detail)
        state.focus(.detail)
        XCTAssertNotEqual(state.panelFocusRequest, first, "⌘3 twice asks twice")
    }

    func testCopyEscapesControlCharactersButMessagesKeepLineBreaks() async throws {
        let actions = RecordingRowActions()
        let state = try await loadedState(actions)

        state.copy("evil\nrm -rf ~\u{202E}txt")
        state.rowMenuActions.copyMessage("subject\n\nbody\tline\r\u{202E}x")
        XCTAssertEqual(
            actions.copied,
            ["evil\\u{A}rm -rf ~\\u{202E}txt", "subject\n\nbody\tline\\u{D}\\u{202E}x"])
    }

    func testCopyCommandsFollowTheSelection() async throws {
        let state = try await loadedState()
        let focused = try XCTUnwrap(state.focusedWorktreePath)
        XCTAssertEqual(state.fullPathToCopy, focused.display, "⌥⌘C with no file: the worktree")

        state.selectCommit(SampleGraphLoader.oid("3"))
        XCTAssertEqual(state.selectionCopyText, SampleGraphLoader.oid("3").hex, "⌘C on a commit: its full SHA")

        let changed = GitPath("/tmp/dev/api-wt/42-rate-limit")
        state.selectWorktree(changed)
        guard case .changes(let groups)? = state.wipDetailModel?.content, let row = groups.first?.rows.first else {
            return XCTFail("the mock worktree has changes")
        }
        state.selectFile(FileSelection(worktree: changed, group: row.group, path: row.path))
        XCTAssertEqual(state.selectionCopyText, row.path.display, "⌘C on a file: its path in the repository")
        XCTAssertEqual(state.fullPathToCopy, changed.display + "/" + row.path.display)
    }

    func testCopyMessageUsesTheLoadedBody() async throws {
        let state = try await loadedState()
        let commit = SampleGraphLoader.commits[1]
        XCTAssertEqual(state.message(of: commit), commit.subject, "before S-03 loads: the subject")
        state.selectCommit(commit.oid)
        await state.commitDetail.task?.value
        XCTAssertEqual(state.message(of: commit), "subject\n\nbody")
    }

    /// SEC-T14-07: refusals reach the user and nothing is opened.
    func testRevealAndBrowserRefusalsShowAnAlertAndOpenNothing() async throws {
        let actions = RecordingRowActions()
        let state = try await loadedState(actions)

        state.revealFile(GitPath("../../etc/passwd"), in: GitPath("/tmp/dev/api-wt/does-not-exist"))
        XCTAssertNotNil(state.alert)
        state.alert = nil

        state.revealWorktree(GitPath("/tmp/dev/api-wt/old-spike-\(UUID().uuidString)"))
        XCTAssertEqual(state.alert?.message, "The worktree folder no longer exists.")
        state.alert = nil

        state.openTerminal(at: GitPath("/tmp/dev/missing-\(UUID().uuidString)"))
        XCTAssertNotNil(state.alert)
        state.alert = nil

        state.openInBrowser(URL(string: "http://github.com/o/r/issues/1")!)
        XCTAssertEqual(state.alert?.message, RowActionRefusal.notHTTPS.message)
        XCTAssertTrue(actions.revealed.isEmpty && actions.terminals.isEmpty && actions.opened.isEmpty)

        state.openInBrowser(URL(string: "https://github.com/o/r/issues/1")!)
        XCTAssertEqual(actions.opened, [URL(string: "https://github.com/o/r/issues/1")!])
    }

    func testRevealAndTerminalUseTheRealFolder() async throws {
        let actions = RecordingRowActions()
        let state = try await loadedState(actions)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("overgrove-nav-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "x".write(to: folder.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        let path = GitPath(folder.path)

        state.revealWorktree(path)
        state.openTerminal(at: path)
        XCTAssertNotNil(state.terminalConfirmation, "a folder the listing did not inspect is confirmed first")
        XCTAssertTrue(actions.terminals.isEmpty)
        state.confirmOpenTerminal()
        state.revealFile(GitPath("a.txt"), in: path)
        XCTAssertNil(state.alert)
        XCTAssertNil(state.terminalConfirmation)
        XCTAssertEqual(actions.terminals.map(\.standardizedFileURL.path), [folder.standardizedFileURL.path])
        XCTAssertEqual(actions.revealed.map(\.lastPathComponent), [folder.lastPathComponent, "a.txt"])
    }

    func testRowsCarryWhatTheirMenusCopy() {
        let worktrees = WorktreeListModel(listing: .mockup, focused: nil)
        XCTAssertEqual(worktrees.rows.first { $0.isMain }?.branchName, "main")
        XCTAssertNil(
            worktrees.rows.first { $0.id == GitPath("/tmp/dev/api-wt/review") }?.branchName, "detached: no branch")

        let tracking = Branch(
            fullName: "refs/heads/feat/42", kind: .local, target: SampleGraphLoader.oid("1"),
            upstreamStatus: .tracking(upstream: "refs/remotes/origin/feat/42", ahead: 0, behind: 0), isHead: false,
            committerDate: nil, symbolicTarget: nil)
        let branches = BranchListModel(
            refs: RefParser.Listing(branches: [tracking], tags: [], isPartial: false, skippedRecords: 0),
            checkedOut: [], remoteNames: ["origin"])
        guard case .folder(_, _, _, let children)? = branches.local.first, case .branch(let row)? = children.first
        else { return XCTFail("\(branches.local)") }
        XCTAssertEqual(row.tip, SampleGraphLoader.oid("1"))
        XCTAssertEqual(row.upstreamName, "origin/feat/42")
    }

    // MARK: #311 state leftovers

    /// ⎋ on the Worktree segment (S-05) returns to Changes (interaction.md §3.1 ③).
    func testEscapeLeavesTheWorktreeSegment() async throws {
        let state = try await loadedState()
        let path = try XCTUnwrap(state.focusedWorktreePath)
        state.showWorktreeDetail()
        XCTAssertEqual(state.selection, .worktreeInfo(path))
        state.escape()
        XCTAssertEqual(state.selection, .wip(path))
    }

    /// ⌘J (and the toolbar HEAD chip) closes an open file history so the graph shows the HEAD it selected.
    func testJumpToHeadClosesTheFileHistory() async throws {
        let state = try await loadedState()
        state.showHistory(of: GitPath("README.md"))
        XCTAssertTrue(state.history.isOpen)
        state.jumpToHead()
        XCTAssertFalse(state.history.isOpen)
        XCTAssertEqual(state.selection, .commit(HeadFirstGraphLoader.head))
    }

    /// An S-09 entry the graph has not loaded leaves no earlier graph row highlighted.
    func testHistoryEntryOutsideTheGraphClearsTheGraphSelection() async throws {
        let state = try await loadedState()
        state.selectCommit(SampleGraphLoader.oid("4"))
        XCTAssertEqual(state.graph.selected, SampleGraphLoader.oid("4"))
        let unloaded = CommitNode(
            oid: ObjectID(String(repeating: "e", count: 40))!, parents: [], authorName: "a", authorEmail: "a@x",
            authorDate: Date(timeIntervalSince1970: 0), subject: "old")
        state.selectHistoryEntry(FileHistoryEntry(commit: unloaded, path: GitPath("README.md")))
        XCTAssertNil(state.graph.selected)
        XCTAssertEqual(state.selection, .commit(unloaded.oid))
    }

    /// A comparison whose worktree is removed (in Terminal) closes with it.
    func testComparisonClosesWhenItsWorktreeIsRemoved() async throws {
        let compared = GitPath("/tmp/dev/api-wt/42-rate-limit")
        let without = WorktreeListing(
            entries: WorktreeListing.mockup.entries.filter { $0.worktree.path != compared }, isPartial: false)
        let repositoryLoader = SequenceRepositoryLoader([.mockup, without])
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: repositoryLoader, comparisonLoader: StubComparisonLoader(), graphLoader: HeadFirstGraphLoader(),
            commitLoader: StubCommitLoader())
        state.open(RepositoryContext(repository: repository, owner: nil))
        state.reload()
        await state.loadTask?.value
        state.selectWorktree(compared)
        state.showComparison(of: compared)
        XCTAssertEqual(state.comparison?.worktree, compared)
        state.reload()
        await state.loadTask?.value
        XCTAssertNil(state.comparison)
        XCTAssertNotEqual(state.focusedWorktreePath, compared)
    }
}
