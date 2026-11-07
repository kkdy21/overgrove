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
        _ loader: StubIssueLoader, repository: GitHubRepository? = IssueModelsTests.repository
    ) async -> AppState {
        var listing = WorktreeListing.mockup
        listing.githubRepository = repository
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(result: .success(listing)), issueLoader: loader)
        let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        state.reload()
        await state.loadTask?.value
        await state.issuePanel.task?.value
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
