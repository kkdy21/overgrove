import XCTest

@testable import Overgrove

/// Answers gh login checks with queued reports and counts them (ADR-0025 §1).
final class QueuedGHAuthReporter: GHAuthChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var reports: [GHAuthReport?]
    private var count = 0

    init(_ reports: [GHAuthReport?]) {
        self.reports = reports
    }

    var checks: Int { lock.withLock { count } }

    func authStatus() async -> GHAuthStatus? {
        await authReport()?.status
    }

    func authReport() async -> GHAuthReport? {
        lock.withLock {
            count += 1
            return reports.count > 1 ? reports.removeFirst() : reports[0]
        }
    }
}

/// Which hosts' GitHub remotes the app hands to gh (ADR-0025 §1, SEC-T9-117-01).
@MainActor
final class AppStateGitHubHostTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let issue = IssueModelsTests.issue(12, "Worktree list", url: "https://ghe.example/team/app/issues/12")

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func report(_ hosts: [String]) -> GHAuthReport {
        GHAuthReport(status: .loggedIn(login: "octocat"), hosts: Set(hosts.compactMap(RemoteHost.init)))
    }

    private func loadedState(
        remotes: [String], issues: StubIssueLoader,
        pullRequests: StubPullRequestLoader = StubPullRequestLoader([.unavailable]),
        checker: QueuedGHAuthReporter
    ) async -> AppState {
        var listing = WorktreeListing.mockup
        listing.remotes = remotes.enumerated().map { WorktreeListing.Remote(name: "r\($0.offset)", url: $0.element) }
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(result: .success(listing)), issueLoader: issues,
            pullRequestLoader: pullRequests, ghChecker: checker)
        let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        state.reload()
        await state.loadTask?.value
        await state.ghCheckTask?.value
        await state.issuePanel.task?.value
        await state.pullRequestStore.task?.value
        return state
    }

    /// SEC-T9-117-01: a remote on a host gh is logged in to is read with `--repo HOST/OWNER/NAME`, after the login list.
    func testSECT9_117_01_ALoggedInHostsRemoteIsRead() async {
        let issues = StubIssueLoader([.issues([issue])])
        let pullRequests = StubPullRequestLoader([.unavailable])
        let checker = QueuedGHAuthReporter([report(["github.com", "ghe.example"])])
        let state = await loadedState(
            remotes: ["git@ghe.example:team/app.git"], issues: issues, pullRequests: pullRequests, checker: checker)
        XCTAssertEqual(checker.checks, 1)
        XCTAssertEqual(issues.requests, ["ghe.example/team/app"])
        XCTAssertEqual(pullRequests.requests, ["ghe.example/team/app"])
        XCTAssertEqual(state.issueListModel.rows.map(\.number), ["#12"])
        XCTAssertNotNil(state.issueListModel.rows.first?.browserURL)
    }

    /// SEC-T9-117-01: a remote on a host gh has no login for is never handed to gh.
    func testSECT9_117_01_AHostWithoutALoginIsNotRead() async {
        let issues = StubIssueLoader([.issues([issue])])
        let pullRequests = StubPullRequestLoader([.unavailable])
        let checker = QueuedGHAuthReporter([report(["github.com", "other.example"])])
        let state = await loadedState(
            remotes: ["https://ghe.example/team/app"], issues: issues, pullRequests: pullRequests, checker: checker)
        XCTAssertEqual(checker.checks, 1, "the login list is read once to decide")
        XCTAssertEqual(issues.requests, [])
        XCTAssertEqual(pullRequests.requests, [])
        XCTAssertEqual(state.issueListModel.notice?.text, "No GitHub remote")
    }

    /// A failed check trusts nothing new.
    func testAFailedCheckTrustsOnlyGitHubDotCom() async {
        let issues = StubIssueLoader([.issues([issue])])
        let checker = QueuedGHAuthReporter([nil])
        let state = await loadedState(remotes: ["https://ghe.example/team/app"], issues: issues, checker: checker)
        XCTAssertEqual(issues.requests, [])
        XCTAssertEqual(state.trustedGitHubHosts, GitHubRemote.publicOnly)
    }

    /// No remote in a hosted form: gh is not run at all (ADR-0004 §4).
    func testRemotesThatCannotBeGitHubRunNoGh() async {
        let checker = QueuedGHAuthReporter([report(["ghe.example"])])
        let issues = StubIssueLoader([.issues([issue])])
        _ = await loadedState(
            remotes: ["~/dev/app", "https://localhost/team/app", "https://10.0.0.1/team/app"], issues: issues,
            checker: checker)
        XCTAssertEqual(checker.checks, 0)
        XCTAssertEqual(issues.requests, [])
    }

    /// github.com stays first by remote preference: a trusted host added later does not move the repository.
    func testGitHubDotComRemoteRunsOneCheck() async {
        let issues = StubIssueLoader([.issues([IssueModelsTests.issue(12)])])
        let checker = QueuedGHAuthReporter([report(["github.com", "ghe.example"])])
        let state = await loadedState(
            remotes: ["https://github.com/team/app", "https://ghe.example/team/other"], issues: issues,
            checker: checker)
        XCTAssertEqual(checker.checks, 1)
        XCTAssertEqual(issues.requests, ["team/app"])
        XCTAssertTrue(state.trustedGitHubHosts.contains(RemoteHost("ghe.example")!))
    }

    /// SEC-T9-117-01: a host that drops out of gh's login list at the next check is no longer read.
    func testSECT9_117_01_AHostThatLogsOutIsDropped() async {
        let issues = StubIssueLoader([.issues([issue])])
        let pullRequests = StubPullRequestLoader([.unavailable])
        let checker = QueuedGHAuthReporter([report(["ghe.example"]), report(["github.com"])])
        let state = await loadedState(
            remotes: ["git@ghe.example:team/app.git"], issues: issues, pullRequests: pullRequests, checker: checker)
        XCTAssertEqual(issues.requests, ["ghe.example/team/app"])
        state.checkIssuesAgain()
        await state.ghCheckTask?.value
        await state.issuePanel.task?.value
        XCTAssertEqual(state.issueListModel.notice?.text, "No GitHub remote")
        XCTAssertNil(state.pullRequestStore.repository)
    }

    /// SEC-T9-117-01: a login list that arrives after another repository opened never picks from the old remotes.
    func testSECT9_117_01_ALateLoginListIgnoresTheOldRepository() async throws {
        let issues = StubIssueLoader([.issues([issue])])
        let checker = QueuedGHAuthReporter([nil])
        let state = await loadedState(remotes: ["https://ghe.example/team/app"], issues: issues, checker: checker)
        let other = URL(fileURLWithPath: "/tmp/dev/other", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: other, commonGitDirectoryURL: other.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        state.trustGitHubHosts([try XCTUnwrap(RemoteHost("ghe.example"))])
        await state.issuePanel.task?.value
        XCTAssertEqual(issues.requests, [])
    }

    /// ADR-0025 §4: the issue panel and the status bar name the account gh uses on the repository's host.
    func testTheRepositoryHostsAccountIsShown() async throws {
        let ghe = try XCTUnwrap(RemoteHost("ghe.example"))
        let account = GHAccount(host: ghe, login: "me", otherCount: 1)
        let checker = QueuedGHAuthReporter([
            GHAuthReport(status: .notLoggedIn, hosts: [ghe], accounts: [ghe: account])
        ])
        let state = await loadedState(
            remotes: ["git@ghe.example:team/app.git"], issues: StubIssueLoader([.issues([issue])]), checker: checker)
        XCTAssertEqual(state.issueListModel.account, account)
        XCTAssertEqual(state.ghAccount, account)
        XCTAssertEqual(state.issueListModel.account?.switchCommand, "gh auth switch --hostname ghe.example")
    }

    /// A failed check shows no account from the check before; the trusted hosts stay.
    func testAFailedCheckClearsTheAccount() async throws {
        let ghe = try XCTUnwrap(RemoteHost("ghe.example"))
        let account = GHAccount(host: ghe, login: "me", otherCount: 0)
        let checker = QueuedGHAuthReporter([
            GHAuthReport(status: .notLoggedIn, hosts: [ghe], accounts: [ghe: account]), nil,
        ])
        let state = await loadedState(
            remotes: ["git@ghe.example:team/app.git"], issues: StubIssueLoader([.issues([issue])]), checker: checker)
        XCTAssertEqual(state.issueListModel.account, account)
        state.checkIssuesAgain()
        await state.ghCheckTask?.value
        await state.issuePanel.task?.value
        XCTAssertNil(state.issueListModel.account)
        XCTAssertNil(state.ghAccount)
        XCTAssertTrue(state.trustedGitHubHosts.contains(ghe))
    }
}
