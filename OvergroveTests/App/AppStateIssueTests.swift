import Foundation
import XCTest

@testable import Overgrove

/// Answers issue loads with queued results and records the repositories asked for.
final class StubIssueLoader: IssueLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [IssueLoadResult]
    private var calls: [String] = []

    init(_ results: [IssueLoadResult]) {
        self.results = results
    }

    var requests: [String] { lock.withLock { calls } }

    func issues(in repository: GitHubRepository) async -> IssueLoadResult {
        lock.withLock {
            calls.append(repository.slug)
            return results.count > 1 ? results.removeFirst() : results[0]
        }
    }
}

/// Answers gh login checks with queued results and counts them.
final class QueuedGHAuthChecker: GHAuthChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var results: [GHAuthStatus?]
    private var count = 0

    init(_ results: [GHAuthStatus?]) {
        self.results = results
    }

    var checks: Int { lock.withLock { count } }

    func authStatus() async -> GHAuthStatus? {
        lock.withLock {
            count += 1
            return results.count > 1 ? results.removeFirst() : results[0]
        }
    }
}

/// Counts full loads and answers each with the next listing (the last one repeats).
final class SequenceRepositoryLoader: RepositoryLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var listings: [WorktreeListing]
    private var count = 0

    init(_ listings: [WorktreeListing]) {
        self.listings = listings
    }

    var loads: Int { lock.withLock { count } }

    func load(_ repository: Repository) async throws(RepositoryLoadError) -> WorktreeListing {
        lock.withLock {
            count += 1
            return listings.count > 1 ? listings.removeFirst() : listings[0]
        }
    }
}

/// `AppState` issue flows (#81).
@MainActor
final class AppStateIssueTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let first = IssueModelsTests.issue(12, "Worktree list", updated: 10)
    private let second = IssueModelsTests.issue(42, "Rate limit", updated: 20)

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func loadedState(
        _ loader: StubIssueLoader, repository: GitHubRepository? = IssueModelsTests.repository,
        ghChecker: QueuedGHAuthChecker = QueuedGHAuthChecker([.loggedIn(login: "octocat")])
    ) async -> AppState {
        var listing = WorktreeListing.mockup
        listing.setGitHubRemote(repository)
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(result: .success(listing)), issueLoader: loader,
            pullRequestLoader: StubPullRequestLoader([.unavailable]), ghChecker: ghChecker)
        let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        state.reload()
        await state.loadTask?.value
        await state.issuePanel.task?.value
        await state.ghCheckTask?.value
        return state
    }

    func testLoadsTheRemotesIssuesAfterTheListing() async {
        let loader = StubIssueLoader([.issues([first, second])])
        let state = await loadedState(loader)
        XCTAssertEqual(loader.requests, ["team/app"])
        XCTAssertEqual(state.issueListModel.rows.map(\.number), ["#42", "#12"])
        XCTAssertFalse(state.issueListModel.isLoading)
    }

    func testWithoutAGitHubRemoteGhIsNotRun() async {
        let loader = StubIssueLoader([.issues([first])])
        let state = await loadedState(loader, repository: nil)
        XCTAssertEqual(loader.requests, [])
        XCTAssertEqual(state.issueListModel.notice?.text, "No GitHub remote")
    }

    func testGhStatesStayInTheIssuePanel() async {
        for (result, text) in [
            (IssueLoadResult.notInstalled, "GitHub CLI not installed"),
            (.notLoggedIn, "Not logged in to GitHub"),
            (.failed("HTTP 404\u{202E}"), "Cannot read issues for team/app"),
        ] {
            let state = await loadedState(StubIssueLoader([result]))
            XCTAssertEqual(state.issueListModel.notice?.text, text)
            XCTAssertNotNil(state.wipDetailModel, "the worktree detail is unaffected")
        }
        let failed = await loadedState(StubIssueLoader([.failed("HTTP 404\u{202E}")]))
        XCTAssertFalse(failed.issueListModel.notice?.detail?.unicodeScalars.contains("\u{202E}") ?? true)
    }

    func testSelectingAnIssueShowsItsDetail() async {
        let state = await loadedState(StubIssueLoader([.issues([first, second])]))
        let focus = state.focusedWorktreePath
        state.selectIssue(42)
        XCTAssertEqual(state.selection, .issue(42))
        XCTAssertEqual(state.focusedWorktreePath, focus, "the focused worktree stays")
        XCTAssertNil(state.wipDetailModel)
        XCTAssertEqual(state.issueDetailModel?.title, "Rate limit")
        state.selectIssue(99)
        XCTAssertEqual(state.selection, .issue(42), "an unknown number is ignored")
    }

    func testReloadAsksAgainAndAClosedIssueFallsBack() async {
        let loader = StubIssueLoader([.issues([first, second]), .issues([first])])
        let state = await loadedState(loader)
        state.selectIssue(42)
        // An automatic refresh does not run gh again.
        state.windowDidBecomeActive()
        await state.loadTask?.value
        await state.issuePanel.task?.value
        XCTAssertEqual(loader.requests.count, 1)

        state.reload()
        await state.loadTask?.value
        await state.issuePanel.task?.value
        XCTAssertEqual(loader.requests.count, 2)
        XCTAssertEqual(state.selection, state.focusedWorktreePath.map(MainSelection.wip))
        XCTAssertEqual(state.issueListModel.rows.map(\.id), [12])
    }

    /// A cached paint never decides the repository gh is asked about, even after a verified listing failed to
    /// refresh (security review of #81). The same holds for pull requests (security review of #115).
    func testACachedPaintDoesNotRunGh() async {
        let loader = StubIssueLoader([.issues([first])])
        let pullRequests = StubPullRequestLoader([.unavailable])
        var verified = WorktreeListing.mockup
        verified.setGitHubRemote(IssueModelsTests.repository)
        var cached = WorktreeListing.mockup
        cached.setGitHubRemote(GitHubRepository(owner: "old", name: "app"))
        let repositoryLoader = CachedFailingLoader(first: verified, cached: cached)
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: repositoryLoader, issueLoader: loader, pullRequestLoader: pullRequests,
            ghChecker: QueuedGHAuthChecker([nil]))
        let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        // Verified, then a failed refresh (the list shows the error), then a reload that paints the cache first.
        for _ in 0..<3 {
            state.reload()
            await state.loadTask?.value
            await state.issuePanel.task?.value
            await state.pullRequestStore.task?.value
        }
        XCTAssertEqual(loader.requests, ["team/app"], "the cached paint's remote is never asked about")
        XCTAssertEqual(pullRequests.requests, ["team/app"])
        // Check Again after the failed refresh asks about the last verified repository only.
        state.checkIssuesAgain()
        await state.issuePanel.task?.value
        await state.pullRequestStore.task?.value
        XCTAssertEqual(loader.requests, ["team/app", "team/app"])
        XCTAssertEqual(pullRequests.requests, ["team/app", "team/app"])
    }

    /// #82: the mockup's `feat/42-rate-limit` worktree links issue 42; badges know the fetched numbers.
    func testLinksFromTheListing() async {
        let state = await loadedState(StubIssueLoader([.issues([first, second])]))
        XCTAssertEqual(state.issueListModel.rows.map(\.id), [42, 12])
        XCTAssertEqual(state.issueListModel.rows.first?.linkKind, .worktree)
        let badges = state.issueBadgeContext
        XCTAssertEqual(badges.known, [12, 42])
        XCTAssertEqual(badges.repository, "team/app")
        XCTAssertEqual(badges.titles[42], "Rate limit")
        badges.select(12)
        XCTAssertEqual(state.selection, .issue(12), "a known badge selects its issue")
        badges.select(42)
        XCTAssertEqual(state.issueDetailModel?.linkedWorktrees.map(\.title), ["feat/42-rate-limit"])
        XCTAssertTrue(state.highlightedCommits.isEmpty, "the mockup has no refs, so no branch tips")
    }

    // MARK: Degraded mode (#83)

    func testStatusBarShowsGhStateAlongsideTheIssues() async {
        let checker = QueuedGHAuthChecker([.loggedIn(login: "octocat")])
        let state = await loadedState(StubIssueLoader([.issues([first])]), ghChecker: checker)
        XCTAssertEqual(state.ghStatus, .loggedIn(login: "octocat"))
        XCTAssertEqual(checker.checks, 1)
        // Without a GitHub remote no gh runs at all.
        let none = QueuedGHAuthChecker([.notInstalled])
        let plain = await loadedState(StubIssueLoader([.issues([])]), repository: nil, ghChecker: none)
        XCTAssertEqual(none.checks, 0)
        XCTAssertNil(plain.ghStatus)
    }

    /// Git features do not depend on gh: the worktree list, the WIP detail, and the branches load as usual.
    func testGitWorksWithoutGh() async {
        for result in [IssueLoadResult.notInstalled, .notLoggedIn] {
            let state = await loadedState(
                StubIssueLoader([result]),
                ghChecker: QueuedGHAuthChecker([result == .notInstalled ? .notInstalled : .notLoggedIn]))
            XCTAssertNotNil(state.worktreeListModel)
            XCTAssertNotNil(state.wipDetailModel)
            XCTAssertEqual(state.issueListModel.guidance?.isOK, false)
            XCTAssertEqual(state.ghStatus, result == .notInstalled ? .notInstalled : .notLoggedIn)
        }
    }

    func testCheckAgainRetriesGhAndTheIssues() async {
        let loader = StubIssueLoader([.notLoggedIn, .issues([first])])
        let checker = QueuedGHAuthChecker([.notLoggedIn, .loggedIn(login: "octocat")])
        let state = await loadedState(loader, ghChecker: checker)
        XCTAssertEqual(state.issueListModel.guidance?.command, "gh auth login")

        state.checkIssuesAgain()
        await state.issuePanel.task?.value
        await state.ghCheckTask?.value
        XCTAssertEqual(loader.requests.count, 2)
        XCTAssertEqual(checker.checks, 2)
        XCTAssertEqual(state.issueListModel.rows.map(\.id), [12])
        XCTAssertNil(state.issueListModel.guidance)
        XCTAssertEqual(state.ghStatus, .loggedIn(login: "octocat"))
    }

    /// SEC-T15-13: pressing Check Again repeatedly while gh runs starts no further gh processes.
    func testCheckAgainDoesNotPileUpGh() async {
        let loader = StubIssueLoader([.notLoggedIn])
        let checker = QueuedGHAuthChecker([.notLoggedIn])
        let state = await loadedState(loader, ghChecker: checker)
        state.checkIssuesAgain()
        state.checkIssuesAgain()
        state.checkIssuesAgain()
        await state.issuePanel.task?.value
        await state.ghCheckTask?.value
        XCTAssertEqual(loader.requests.count, 2, "the first load and one Check Again")
        XCTAssertEqual(checker.checks, 2)
        XCTAssertFalse(state.isCheckingGitHub)
        state.checkIssuesAgain()
        await state.issuePanel.task?.value
        XCTAssertEqual(loader.requests.count, 3, "available again once gh finished")
    }

    /// No GitHub remote: Check Again reloads the repository so newly added remotes are read.
    func testCheckAgainWithoutARemoteReloadsTheRepository() async {
        var withRemote = WorktreeListing.mockup
        withRemote.setGitHubRemote(IssueModelsTests.repository)
        let repositoryLoader = SequenceRepositoryLoader([.mockup, withRemote])
        let issues = StubIssueLoader([.issues([first])])
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: repositoryLoader, issueLoader: issues, pullRequestLoader: StubPullRequestLoader([.unavailable]),
            ghChecker: QueuedGHAuthChecker([.loggedIn(login: "o")]))
        let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        state.reload()
        await state.loadTask?.value
        XCTAssertEqual(state.issueListModel.notice?.text, "No GitHub remote")

        state.checkIssuesAgain()
        await state.loadTask?.value
        await state.issuePanel.task?.value
        XCTAssertEqual(repositoryLoader.loads, 2)
        XCTAssertEqual(issues.requests, ["team/app"])
        XCTAssertEqual(state.issueListModel.rows.map(\.id), [12])
    }

    /// #311: when the next load has no list (logged out, failed), a selected issue falls back to the worktree.
    func testSelectionFallsBackWhenTheListBecomesUnavailable() async {
        for next in [IssueLoadResult.notLoggedIn, .failed("HTTP 500"), .notInstalled] {
            let state = await loadedState(StubIssueLoader([.issues([first]), next]))
            state.selectIssue(12)
            XCTAssertEqual(state.selection, .issue(12))
            state.reload()
            await state.loadTask?.value
            await state.issuePanel.task?.value
            XCTAssertEqual(state.selection, state.focusedWorktreePath.map(MainSelection.wip), "\(next)")
        }
    }

    func testOpeningAnotherRepositoryClearsTheIssues() async {
        let state = await loadedState(StubIssueLoader([.issues([first])]))
        state.selectIssue(12)
        let root = URL(fileURLWithPath: "/tmp/dev/web", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        XCTAssertNil(state.issuePanel.content)
        XCTAssertTrue(state.issueListModel.rows.isEmpty)
        XCTAssertNil(state.issueDetailModel)
    }
}

/// Answers the first load with `first`, fails the rest, and paints `cached` before each.
private final class CachedFailingLoader: RepositoryLoading, @unchecked Sendable {
    private let lock = NSLock()
    private let first: WorktreeListing
    private let cached: WorktreeListing
    private var loads = 0

    init(first: WorktreeListing, cached: WorktreeListing) {
        self.first = first
        self.cached = cached
    }

    func load(_ repository: Repository) async throws(RepositoryLoadError) -> WorktreeListing {
        let count = lock.withLock {
            loads += 1
            return loads
        }
        guard count == 1 else { throw .git(.timeout(seconds: 1)) }
        return first
    }

    func cachedListing(_ repository: Repository) async -> WorktreeListing? { cached }
}

/// `LiveIssueLoader` maps gh failures to panel states (#81).
final class LiveIssueLoaderTests: XCTestCase {
    private var executables: TestExecutables!

    override func setUpWithError() throws {
        executables = try TestExecutables()
    }

    override func tearDown() {
        executables.remove()
    }

    private func loader(_ fake: FakeGH?) -> LiveIssueLoader {
        let neutral = executables.directory.appendingPathComponent("neutral", isDirectory: true)
        return LiveIssueLoader(
            client: GHClient(
                parentEnvironment: [:], neutralDirectory: neutral,
                executableCandidates: fake.map { [$0.executable] } ?? []))
    }

    func testMapsGhResults() async throws {
        let repository = IssueModelsTests.repository
        let json = """
            [{"number":3,"title":"t","state":"OPEN","labels":[],"assignees":[],\
            "updatedAt":"2026-11-01T00:00:00Z","url":"https://github.com/team/app/issues/3"}]
            """
        let listed = await loader(try executables.fakeGH(stdout: json)).issues(in: repository)
        XCTAssertEqual(listed, .issues([IssueModelsTests.issue(3, "t").withDate("2026-11-01T00:00:00Z")]))
        let missing = await loader(nil).issues(in: repository)
        XCTAssertEqual(missing, .notInstalled)
        let loggedOut = await loader(try executables.fakeGH(stdout: "", exitCode: 4)).issues(in: repository)
        XCTAssertEqual(loggedOut, .notLoggedIn)
        let failed = await loader(try executables.fakeGH(stdout: "", stderr: "HTTP 404: Not Found\n", exitCode: 1))
            .issues(in: repository)
        guard case .failed(let message) = failed else { return XCTFail("\(failed)") }
        XCTAssertTrue(message.contains("HTTP 404"), message)
    }
}

extension Issue {
    fileprivate func withDate(_ text: String) -> Issue {
        Issue(
            number: number, title: title, state: state, labels: labels, assignees: assignees,
            updatedAt: ISO8601DateFormatter().date(from: text)!, url: url)
    }
}

extension WorktreeListing {
    /// One `origin` remote whose https URL is `repository` (none for `nil`).
    mutating func setGitHubRemote(_ repository: GitHubRepository?) {
        remotes =
            repository.map {
                [Remote(name: "origin", url: "https://\($0.host.name)/\($0.owner)/\($0.name).git")]
            } ?? []
    }
}
