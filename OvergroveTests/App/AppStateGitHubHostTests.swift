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
        checker: QueuedGHAuthReporter, gitlab: StubGitLabHostChecker = StubGitLabHostChecker(),
        gitea: StubGiteaInstanceChecker = StubGiteaInstanceChecker()
    ) async -> AppState {
        var listing = WorktreeListing.mockup
        listing.remotes = remotes.enumerated().map { WorktreeListing.Remote(name: "r\($0.offset)", url: $0.element) }
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(result: .success(listing)), issueLoader: issues,
            pullRequestLoader: pullRequests, ghChecker: checker, gitlabChecker: gitlab, giteaChecker: gitea)
        let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        state.reload()
        await state.loadTask?.value
        await state.ghCheckTask?.value
        await state.gitlabCheckTask?.value
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
        // No CLI is logged in to the host (ADR-0026 §7): the notice names it, nothing is read from it.
        XCTAssertEqual(state.issueListModel.notice?.text, "Not logged in to ghe.example")
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
        await state.gitlabCheckTask?.value
        await state.issuePanel.task?.value
        XCTAssertEqual(state.issueListModel.notice?.text, "Not logged in to ghe.example")
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

    // MARK: Reading gh's login list again (#485)

    private func settle(_ state: AppState) async {
        await state.loadTask?.value
        await state.ghCheckTask?.value
        await state.gitlabCheckTask?.value
        await state.issuePanel.task?.value
        await state.pullRequestStore.task?.value
    }

    /// #485: after `gh auth login --hostname HOST`, Check Again on the "Not logged in to HOST" panel reads gh's login
    /// list again and the host's issues load. Auto refresh in between does not run gh.
    func testCheckAgainReadsTheLoginListAfterALogin() async {
        let issues = StubIssueLoader([.issues([issue])])
        let checker = QueuedGHAuthReporter([report(["github.com"]), report(["github.com", "ghe.example"])])
        let state = await loadedState(remotes: ["git@ghe.example:team/app.git"], issues: issues, checker: checker)
        XCTAssertEqual(state.issueListModel.notice?.text, "Not logged in to ghe.example")
        XCTAssertEqual(checker.checks, 1)
        state.refresh(.filesChanged(worktrees: [], refs: false, worktreeList: true))
        await settle(state)
        state.refresh(.automatic)
        await settle(state)
        XCTAssertEqual(checker.checks, 1, "auto refresh does not run gh again")
        state.checkIssuesAgain()
        await settle(state)
        XCTAssertEqual(checker.checks, 2)
        XCTAssertEqual(issues.requests, ["ghe.example/team/app"])
        XCTAssertEqual(state.issueListModel.rows.map(\.number), ["#12"])
    }

    /// #485: gh installed after the first read (which reported it missing): ⌘R reads the login list again.
    func testCommandRReadsTheLoginListAfterGhIsInstalled() async {
        let issues = StubIssueLoader([.issues([issue])])
        let checker = QueuedGHAuthReporter([
            GHAuthReport(status: .notInstalled, hosts: []), report(["ghe.example"]),
        ])
        let state = await loadedState(remotes: ["https://ghe.example/team/app"], issues: issues, checker: checker)
        XCTAssertEqual(state.issueListModel.notice?.text, "Not logged in to ghe.example")
        state.refresh(.automatic)
        await settle(state)
        XCTAssertEqual(checker.checks, 1, "auto refresh does not run gh again")
        state.reload()
        await settle(state)
        XCTAssertEqual(checker.checks, 2)
        XCTAssertEqual(issues.requests, ["ghe.example/team/app"])
        XCTAssertEqual(state.issueListModel.rows.map(\.number), ["#12"])
    }

    /// #485: ⌘R with the host still logged out reads the list once and keeps the notice; no remote that gh could
    /// learn about runs no gh even on ⌘R.
    func testCommandRWithoutALoginKeepsTheNotice() async {
        let issues = StubIssueLoader([.issues([issue])])
        let checker = QueuedGHAuthReporter([report(["github.com"])])
        let state = await loadedState(remotes: ["https://ghe.example/team/app"], issues: issues, checker: checker)
        state.reload()
        await settle(state)
        XCTAssertEqual(checker.checks, 2)
        XCTAssertEqual(issues.requests, [])
        XCTAssertEqual(state.issueListModel.notice?.text, "Not logged in to ghe.example")

        let local = QueuedGHAuthReporter([report(["github.com"])])
        let other = await loadedState(remotes: ["~/dev/app"], issues: issues, checker: local)
        other.reload()
        await settle(other)
        XCTAssertEqual(local.checks, 0)
    }

    // MARK: Enterprise Managed Users (#486)

    /// #486: an Enterprise Managed User's personal repository on github.com is read, and the account is shown.
    func testAnEnterpriseManagedUsersRepositoryIsRead() async throws {
        let github = try XCTUnwrap(RemoteHost("github.com"))
        let account = GHAccount(host: github, login: "mina_acme", otherCount: 0)
        let issues = StubIssueLoader([.issues([IssueModelsTests.issue(12)])])
        let checker = QueuedGHAuthReporter([
            GHAuthReport(status: .loggedIn(login: "mina_acme"), hosts: [github], accounts: [github: account])
        ])
        let state = await loadedState(remotes: ["git@github.com:mina_acme/app.git"], issues: issues, checker: checker)
        XCTAssertEqual(issues.requests, ["mina_acme/app"])
        XCTAssertEqual(state.ghStatus, .loggedIn(login: "mina_acme"))
        XCTAssertEqual(state.ghAccount, account)
    }

    /// #486: github.com's state that could not be read (an odd login) does not drop the other hosts: a GitHub
    /// Enterprise host gh is logged in to is still trusted and read, with its account.
    func testAnUnreadGitHubDotComStateKeepsTheOtherHosts() async throws {
        let github = try XCTUnwrap(RemoteHost("github.com"))
        let ghe = try XCTUnwrap(RemoteHost("ghe.example"))
        let account = GHAccount(host: ghe, login: "me", otherCount: 0)
        let issues = StubIssueLoader([.issues([issue])])
        let checker = QueuedGHAuthReporter([GHAuthReport(status: nil, hosts: [github, ghe], accounts: [ghe: account])])
        let state = await loadedState(remotes: ["git@ghe.example:team/app.git"], issues: issues, checker: checker)
        XCTAssertNil(state.ghStatus)
        XCTAssertEqual(issues.requests, ["ghe.example/team/app"])
        XCTAssertEqual(state.issueListModel.account, account)
        XCTAssertTrue(state.trustedGitHubHosts.contains(ghe))
    }

    // MARK: GitLab (#154, ADR-0026)

    private let gitlabIssue = IssueModelsTests.issue(
        7, "Pipeline", url: "https://gitlab.example.com/group/app/-/work_items/7")

    /// SEC-T11-154-4: a GitLab remote is read only after glab reports its host logged in; otherwise nothing is read
    /// and the notice names the host with one login command per CLI.
    func testSECT11_154_4_GitLabIssuesOnlyForAHostGlabIsLoggedIn() async {
        let issues = StubIssueLoader([.issues([gitlabIssue])])
        let none = StubGitLabHostChecker()
        let loggedOut = await loadedState(
            remotes: ["git@gitlab.example.com:group/app.git"], issues: issues,
            checker: QueuedGHAuthReporter([report(["github.com"])]), gitlab: none)
        XCTAssertEqual(none.hosts, ["gitlab.example.com"])
        XCTAssertEqual(issues.requests, [])
        XCTAssertEqual(loggedOut.issueListModel.notice?.text, "Not logged in to gitlab.example.com")
        XCTAssertEqual(
            loggedOut.issueListModel.setupCommands,
            [
                "gh auth login --hostname gitlab.example.com", "glab auth login --hostname gitlab.example.com",
                "gt auth login --host https://gitlab.example.com",
            ])
        XCTAssertTrue(loggedOut.issueListModel.canCheckAgain)

        let glab = StubGitLabHostChecker(loggedIn: ["gitlab.example.com"])
        let state = await loadedState(
            remotes: ["git@gitlab.example.com:group/app.git"], issues: issues,
            checker: QueuedGHAuthReporter([report(["github.com"])]), gitlab: glab)
        XCTAssertEqual(issues.requests, ["gitlab.example.com/group/app"])
        XCTAssertEqual(state.issueListModel.rows.map(\.number), ["#7"])
        XCTAssertNotNil(state.issueListModel.rows.first?.browserURL, "this project's work item page")
        XCTAssertNil(state.pullRequestStore.repository, "pull requests stay GitHub only")
        XCTAssertNil(state.issueListModel.account, "GitLab issues are not read as a gh account")
        state.selectIssue(7)
        XCTAssertEqual(state.issueDetailModel?.repository, "gitlab.example.com/group/app")
    }

    /// A GitHub repository wins: glab is never asked (ADR-0026 §2).
    func testAGitHubRemoteRunsNoGlab() async {
        let glab = StubGitLabHostChecker(loggedIn: ["gitlab.example.com"])
        let issues = StubIssueLoader([.issues([IssueModelsTests.issue(12)])])
        _ = await loadedState(
            remotes: ["https://gitlab.example.com/group/app", "https://github.com/team/app"], issues: issues,
            checker: QueuedGHAuthReporter([report(["github.com"])]), gitlab: glab)
        XCTAssertEqual(glab.hosts, [])
        XCTAssertEqual(issues.requests, ["team/app"])
    }

    /// Auto refresh does not run glab again for the same answer; ⌘R does.
    func testGlabIsAskedAgainOnlyOnCommandR() async {
        let glab = StubGitLabHostChecker()
        let state = await loadedState(
            remotes: ["https://gitlab.example.com/group/app"], issues: StubIssueLoader([.issues([])]),
            checker: QueuedGHAuthReporter([report(["github.com"])]), gitlab: glab)
        XCTAssertEqual(glab.hosts.count, 1)
        state.refresh(.filesChanged(worktrees: [], refs: false, worktreeList: true))
        await state.loadTask?.value
        await state.gitlabCheckTask?.value
        XCTAssertEqual(glab.hosts.count, 1, "the same remotes: no glab")
        state.reload()
        await state.loadTask?.value
        await state.ghCheckTask?.value
        await state.gitlabCheckTask?.value
        XCTAssertEqual(glab.hosts.count, 2)
    }

    /// gh first (ADR-0026 §2): a remote on a host gh is logged in to is read through gh, and glab is never asked about
    /// it, even when glab is logged in there too.
    func testAHostGhIsLoggedInToIsNeverAskedOfGlab() async {
        let glab = StubGitLabHostChecker(loggedIn: ["ghe.example"])
        let issues = StubIssueLoader([.issues([issue])])
        _ = await loadedState(
            remotes: ["git@ghe.example:team/app.git"], issues: issues,
            checker: QueuedGHAuthReporter([report(["github.com", "ghe.example"])]), gitlab: glab)
        XCTAssertEqual(glab.hosts, [])
        XCTAssertEqual(issues.requests, ["ghe.example/team/app"])
    }

    /// A glab answer that arrives after another repository opened is dropped.
    func testALateGlabAnswerAfterAnotherRepositoryIsDropped() async {
        let glab = GatedGitLabHostChecker()
        let issues = StubIssueLoader([.issues([gitlabIssue])])
        var listing = WorktreeListing.mockup
        listing.remotes = [WorktreeListing.Remote(name: "origin", url: "https://gitlab.example.com/group/app")]
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(result: .success(listing)), issueLoader: issues,
            pullRequestLoader: StubPullRequestLoader([.unavailable]),
            ghChecker: QueuedGHAuthReporter([report(["github.com"])]), gitlabChecker: glab)
        func context(_ path: String) -> RepositoryContext {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            return RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil)
        }
        state.open(context("/tmp/dev/api"))
        state.reload()
        await state.loadTask?.value
        await state.ghCheckTask?.value
        let pending = state.gitlabCheckTask
        for _ in 0..<150 where glab.hosts.isEmpty { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(glab.hosts, ["gitlab.example.com"], "glab is waiting with its answer")
        state.open(context("/tmp/dev/other"))
        glab.release()
        await pending?.value
        await state.issuePanel.task?.value
        XCTAssertNil(state.issuePanel.repository)
        XCTAssertEqual(issues.requests, [])
    }

    // MARK: Switcher owner (#477)

    /// #477: the repository switcher names the owner of the issue source this load picked from inspected remotes: the
    /// GitHub or Gitea owner, or the GitLab namespace. Without a source there is no owner.
    func testTheSwitcherNamesTheIssueSourcesOwner() async {
        let github = await loadedState(
            remotes: ["https://github.com/team/app"], issues: StubIssueLoader([.issues([])]),
            checker: QueuedGHAuthReporter([report(["github.com"])]))
        XCTAssertEqual(github.displayedRepository?.owner, "team")
        XCTAssertEqual(github.displayedRepository?.repository, github.repository?.repository)

        let gitlab = await loadedState(
            remotes: ["git@gitlab.example.com:group/sub/app.git"], issues: StubIssueLoader([.issues([])]),
            checker: QueuedGHAuthReporter([report(["github.com"])]),
            gitlab: StubGitLabHostChecker(loggedIn: ["gitlab.example.com"]))
        XCTAssertEqual(gitlab.displayedRepository?.owner, "group/sub")

        let gitea = await loadedState(
            remotes: ["git@git.example.com:acme/widgets.git"], issues: StubIssueLoader([.issues([])]),
            checker: QueuedGHAuthReporter([report(["github.com"])]),
            gitea: StubGiteaInstanceChecker(["https://git.example.com"]))
        XCTAssertEqual(gitea.displayedRepository?.owner, "acme")

        let none = await loadedState(
            remotes: ["https://ghe.example/team/app"], issues: StubIssueLoader([.issues([])]),
            checker: QueuedGHAuthReporter([report(["github.com"])]))
        XCTAssertNil(none.displayedRepository?.owner, "no source picked: the name alone")
        XCTAssertNotNil(none.displayedRepository)
    }

    // MARK: Broken gh logins and glab (#467 with #154)

    /// SEC-T9-467-1 (with #154): a host gh lists only a broken login for is not gh's, so it becomes a glab candidate.
    /// glab logged in there reads its GitLab issues; otherwise the host gets the "Not logged in" notice, and gh is
    /// never asked about it.
    func testSECT9_467_1_AHostWithOnlyABrokenGhLoginGoesToGlab() async throws {
        let json =
            #"{"hosts":{"github.com":[{"active":true,"state":"success","login":"octo"}],"code.example.com":[{"active":true,"state":"error","login":"me"}]}}"#
        let report = try GHAuthParser.parseReport(Data(json.utf8))
        XCTAssertFalse(report.hosts.contains(try XCTUnwrap(RemoteHost("code.example.com"))))
        let gitlabIssue = IssueModelsTests.issue(
            3, "Pipeline", url: "https://code.example.com/group/app/-/issues/3")

        let issues = StubIssueLoader([.issues([gitlabIssue])])
        let glab = StubGitLabHostChecker(loggedIn: ["code.example.com"])
        let state = await loadedState(
            remotes: ["git@code.example.com:group/app.git"], issues: issues,
            checker: QueuedGHAuthReporter([report]), gitlab: glab)
        XCTAssertFalse(state.trustedGitHubHosts.contains(try XCTUnwrap(RemoteHost("code.example.com"))))
        XCTAssertEqual(glab.hosts, ["code.example.com"])
        XCTAssertEqual(issues.requests, ["code.example.com/group/app"], "read through glab, not gh")

        let none = StubGitLabHostChecker()
        let unread = StubIssueLoader([.issues([gitlabIssue])])
        let notLoggedIn = await loadedState(
            remotes: ["git@code.example.com:group/app.git"], issues: unread,
            checker: QueuedGHAuthReporter([report]), gitlab: none)
        XCTAssertEqual(unread.requests, [])
        XCTAssertEqual(notLoggedIn.issueListModel.notice?.text, "Not logged in to code.example.com")
    }

    private let giteaIssue = IssueModelsTests.issue(
        7, "Crash", url: "https://git.example.com/acme/widgets/issues/7")

    /// SEC-T11-449-4: with no GitHub repository and no host glab confirms, gt's credentialed instances are read once
    /// (local state, no request) and a remote on one of them shows its issues; without one, nothing is read and the
    /// notice offers the three login commands.
    func testSECT11_449_4_GiteaIssuesOnlyForAnInstanceGtHasCredentialsFor() async {
        let issues = StubIssueLoader([.issues([giteaIssue])])
        let none = StubGiteaInstanceChecker()
        let loggedOut = await loadedState(
            remotes: ["git@git.example.com:acme/widgets.git"], issues: issues,
            checker: QueuedGHAuthReporter([report(["github.com"])]), gitea: none)
        XCTAssertEqual(none.calls, 1)
        XCTAssertEqual(issues.requests, [])
        XCTAssertEqual(loggedOut.issueListModel.notice?.text, "Not logged in to git.example.com")

        let gt = StubGiteaInstanceChecker(["https://git.example.com"])
        let state = await loadedState(
            remotes: ["git@git.example.com:acme/widgets.git"], issues: issues,
            checker: QueuedGHAuthReporter([report(["github.com"])]), gitea: gt)
        XCTAssertEqual(issues.requests, ["git.example.com/acme/widgets"])
        XCTAssertEqual(state.issueListModel.rows.map(\.number), ["#7"])
        XCTAssertNotNil(state.issueListModel.rows.first?.browserURL, "this repository's issue page on the instance")
        XCTAssertNil(state.pullRequestStore.repository, "pull requests stay GitHub only")

    }

    /// Auto refresh does not run gt again for the same remotes, whatever gt answered; ⌘R does.
    func testGtIsAskedAgainOnlyOnCommandR() async {
        for instances in [[], ["https://git.example.com"]] {
            let gt = StubGiteaInstanceChecker(instances)
            let state = await loadedState(
                remotes: ["git@git.example.com:acme/widgets.git"], issues: StubIssueLoader([.issues([giteaIssue])]),
                checker: QueuedGHAuthReporter([report(["github.com"]), report(["github.com"])]), gitea: gt)
            XCTAssertEqual(gt.calls, 1)
            state.refresh(.filesChanged(worktrees: [], refs: false, worktreeList: true))
            await state.loadTask?.value
            await state.ghCheckTask?.value
            await state.gitlabCheckTask?.value
            XCTAssertEqual(gt.calls, 1, "the same remotes: no gt (\(instances))")
            state.reload()
            await state.loadTask?.value
            await state.ghCheckTask?.value
            await state.gitlabCheckTask?.value
            XCTAssertEqual(gt.calls, 2)
        }
    }

    /// SEC-T11-449-4: a gt answer that arrives after another repository opened is dropped.
    func testSECT11_449_4_ALateGtAnswerAfterAnotherRepositoryIsDropped() async {
        let gt = GatedGiteaInstanceChecker(["https://git.example.com"])
        let issues = StubIssueLoader([.issues([giteaIssue])])
        var listing = WorktreeListing.mockup
        listing.remotes = [WorktreeListing.Remote(name: "origin", url: "git@git.example.com:acme/widgets.git")]
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(result: .success(listing)), issueLoader: issues,
            pullRequestLoader: StubPullRequestLoader([.unavailable]),
            ghChecker: QueuedGHAuthReporter([report(["github.com"])]), gitlabChecker: StubGitLabHostChecker(),
            giteaChecker: gt)
        func context(_ path: String) -> RepositoryContext {
            let root = URL(fileURLWithPath: path, isDirectory: true)
            return RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil)
        }
        state.open(context("/tmp/dev/api"))
        state.reload()
        await state.loadTask?.value
        await state.ghCheckTask?.value
        let pending = state.gitlabCheckTask
        for _ in 0..<150 where gt.calls == 0 { try? await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(gt.calls, 1, "gt is waiting with its answer")
        state.open(context("/tmp/dev/other"))
        gt.release()
        await pending?.value
        await state.issuePanel.task?.value
        XCTAssertNil(state.issuePanel.repository)
        XCTAssertEqual(issues.requests, [])
    }

    /// The first CLI that confirms a login takes the host, in the order gh → glab → gt: with glab logged in, gt is not
    /// asked; a host gh is logged in to is never a gt candidate, even for a remote gh cannot read as `OWNER/NAME`.
    func testCLIsTakeAHostInTheOrderGhGlabGt() async {
        let issues = StubIssueLoader([.issues([giteaIssue])])
        let gt = StubGiteaInstanceChecker(["https://git.example.com", "https://git.example.com/sub"])
        _ = await loadedState(
            remotes: ["git@git.example.com:acme/widgets.git"], issues: issues,
            checker: QueuedGHAuthReporter([report(["github.com"])]),
            gitlab: StubGitLabHostChecker(loggedIn: ["git.example.com"]), gitea: gt)
        XCTAssertEqual(issues.requests, ["git.example.com/acme/widgets"], "glab's project")
        XCTAssertEqual(gt.calls, 0)

        let ghHost = StubIssueLoader([.issues([giteaIssue])])
        let state = await loadedState(
            remotes: ["https://git.example.com/sub/acme/widgets"], issues: ghHost,
            checker: QueuedGHAuthReporter([report(["github.com", "git.example.com"])]), gitea: gt)
        XCTAssertEqual(ghHost.requests, [], "gh handles git.example.com, so gt's instance there is skipped")
        XCTAssertNil(state.issuePanel.repository)
    }
}

/// Answers gt's credentialed instances from a fixed list and counts the calls.
final class StubGiteaInstanceChecker: GiteaInstanceChecking, @unchecked Sendable {
    private let lock = NSLock()
    private let instances: [GiteaInstance]
    private var count = 0

    init(_ urls: [String] = []) {
        instances = urls.compactMap(GiteaInstance.init)
    }

    var calls: Int { lock.withLock { count } }

    func loggedInInstances() async -> [GiteaInstance] {
        lock.withLock {
            count += 1
            return instances
        }
    }
}

/// Holds gt's answer until `release()`, so a test can change the repository meanwhile.
final class GatedGiteaInstanceChecker: GiteaInstanceChecking, @unchecked Sendable {
    private let lock = NSLock()
    private let instances: [GiteaInstance]
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var isReleased = false
    private var count = 0

    init(_ urls: [String]) {
        instances = urls.compactMap(GiteaInstance.init)
    }

    var calls: Int { lock.withLock { count } }

    func release() {
        let continuations = lock.withLock {
            isReleased = true
            defer { waiting = [] }
            return waiting
        }
        for continuation in continuations { continuation.resume() }
    }

    func loggedInInstances() async -> [GiteaInstance] {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                count += 1
                if isReleased { return true }
                waiting.append(continuation)
                return false
            }
            if resumeNow { continuation.resume() }
        }
        return instances
    }
}
