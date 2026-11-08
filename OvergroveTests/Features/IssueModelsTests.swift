import XCTest

@testable import Overgrove

/// The ISSUES section and S-06 models (#81).
final class IssueModelsTests: XCTestCase {
    static let repository = GitHubRepository(owner: "team", name: "app")!

    static func issue(
        _ number: Int, _ title: String = "Title", updated: TimeInterval = 0, labels: [String] = [],
        assignees: [String] = [], url: String? = nil, state: Issue.State = .open
    ) -> Issue {
        Issue(
            number: number, title: title, state: state, labels: labels.map { Issue.Label(name: $0, color: "ff0000") },
            assignees: assignees, updatedAt: Date(timeIntervalSince1970: 1_800_000_000 + updated),
            url: URL(string: url ?? "https://github.com/team/app/issues/\(number)")!)
    }

    func testRowsAreMostRecentlyUpdatedFirst() {
        let model = IssueListModel(
            content: .loaded(
                repository: Self.repository,
                issues: [Self.issue(1, updated: 10), Self.issue(3, updated: 30), Self.issue(2, updated: 30)]),
            isLoading: false)
        XCTAssertEqual(model.rows.map(\.number), ["#3", "#2", "#1"])
        XCTAssertEqual(model.count, 3)
        XCTAssertNil(model.notice)
    }

    func testShowsUpToTheTwoHundredIssuesGhReturns() {
        let issues = (1...200).map { Self.issue($0, updated: TimeInterval($0)) }
        let model = IssueListModel(content: .loaded(repository: Self.repository, issues: issues), isLoading: false)
        XCTAssertEqual(model.rows.count, 200)
        XCTAssertEqual(model.rows.first?.id, 200)
        XCTAssertTrue(GHCommand.issueList(repo: Self.repository).arguments.contains("200"))
    }

    func testStatesShowOneNoticeAndNoCount() {
        let cases: [(IssueListContent, String)] = [
            (.loaded(repository: Self.repository, issues: []), "No open issues"),
            (.noGitHubRemote, "No GitHub remote"),
            (.notInstalled, "GitHub CLI not installed"),
            (.notLoggedIn, "Not logged in to GitHub"),
            (.failed(repository: Self.repository, detail: "HTTP 404"), "Cannot read issues for team/app"),
        ]
        for (content, text) in cases {
            let model = IssueListModel(content: content, isLoading: false)
            XCTAssertEqual(model.notice?.text, text)
            XCTAssertTrue(model.rows.isEmpty)
        }
        XCTAssertEqual(
            IssueListModel(content: .failed(repository: Self.repository, detail: "HTTP 404"), isLoading: false)
                .notice?.detail, "HTTP 404")
        XCTAssertNil(IssueListModel(content: .notInstalled, isLoading: false).count)
        XCTAssertTrue(IssueListModel(content: nil, isLoading: true).isLoading)
    }

    /// #83: gh missing or logged out says what to run (copy only) and offers Check Again; a list does not.
    func testDegradedStatesGuideAndOfferCheckAgain() {
        let loggedOut = IssueListModel(content: .notLoggedIn, isLoading: false)
        XCTAssertEqual(loggedOut.guidance?.command, "gh auth login")
        XCTAssertTrue(loggedOut.canCheckAgain)
        XCTAssertEqual(IssueListModel(content: .notInstalled, isLoading: false).guidance?.command, "brew install gh")
        let failed = IssueListModel(content: .failed(repository: Self.repository, detail: "x"), isLoading: false)
        XCTAssertNil(failed.guidance)
        XCTAssertTrue(failed.canCheckAgain)
        XCTAssertTrue(IssueListModel(content: .noGitHubRemote, isLoading: false).canCheckAgain)
        let loaded = IssueListModel(content: .loaded(repository: Self.repository, issues: []), isLoading: false)
        XCTAssertFalse(loaded.canCheckAgain)
        XCTAssertNil(loaded.guidance)
        XCTAssertFalse(IssueListModel(content: nil, isLoading: true).canCheckAgain)
    }

    /// Titles, labels, and logins come from GitHub: control and bidi characters are escaped (display spoofing).
    func testRepositoryStringsAreEscaped() {
        let issue = Self.issue(
            7, "Fix\u{202E}gnp.exe\nnext", labels: ["bug\u{200B}"], assignees: ["oct\u{2028}cat"])
        let row = IssueRow(issue)
        XCTAssertFalse(row.title.unicodeScalars.contains { $0 == "\u{202E}" || $0 == "\n" })
        let detail = IssueDetailModel(issue, repository: Self.repository)
        XCTAssertEqual(detail.title, row.title)
        XCTAssertEqual(detail.labels, [PathValidator.displayable("bug\u{200B}")])
        XCTAssertFalse(detail.labels[0].unicodeScalars.contains("\u{200B}"))
        XCTAssertFalse(detail.assignees[0].unicodeScalars.contains("\u{2028}"))
        XCTAssertTrue(detail.assignees[0].hasPrefix("@"))
    }

    func testDetailShowsStateLabelsAndAssignees() {
        let detail = IssueDetailModel(
            Self.issue(12, "Worktree list", labels: ["type:feature", "area:ui"], assignees: ["octocat", "mina"]),
            repository: Self.repository)
        XCTAssertEqual(detail.number, "#12")
        XCTAssertEqual(detail.repository, "team/app")
        XCTAssertEqual(detail.stateText, "Open")
        XCTAssertEqual(detail.stateSymbol, "number.circle")
        XCTAssertEqual(detail.labels, ["type:feature", "area:ui"])
        XCTAssertEqual(detail.assignees, ["@octocat", "@mina"])
        XCTAssertEqual(detail.browserURL?.absoluteString, "https://github.com/team/app/issues/12")
        XCTAssertEqual(IssueDetailModel(Self.issue(1, state: .closed), repository: nil).stateSymbol, "checkmark.seal")
    }

    /// SEC-T13-05: Open in Browser hands `NSWorkspace` only a github.com issue page for that number (screens.md
    /// S-06): no other scheme, host, user, port, query, fragment, or path.
    func testBrowserURLIsOnlyAGitHubIssuePage() {
        // A renamed or transferred repository redirects: another valid OWNER/NAME is fine.
        XCTAssertNotNil(IssueDetailModel.browserURL(for: Self.issue(5, url: "https://github.com/new/name/issues/5")))
        for url in [
            "https://github.com/team/app/issues/6", "https://github.com/team/app/pull/5",
            "https://github.com/team/app/issues/5/x", "https://github.com/team/app/issues/5?x=1",
            "https://github.com/team/app/issues/5#top", "https://user@github.com/team/app/issues/5",
            "https://github.com:8443/team/app/issues/5", "https://github.com/-team/app/issues/5",
            "https://github.com/team/../issues/5", "https://github.com/team/app/issues/05",
            "https://github.com//app/issues/5", "https://github.com/team/a%2Fb/issues/5",
        ] {
            XCTAssertNil(IssueDetailModel.browserURL(for: Self.issue(5, url: url)), url)
        }
    }

    /// SEC-T9-09 (issue display): on another host, rows and the detail open only that host's issue pages over https.
    func testSECT9_09_OtherHostIssuePage() throws {
        let host = try XCTUnwrap(RemoteHost("ghe.example"))
        let repository = try XCTUnwrap(GitHubRepository(owner: "team", name: "app", host: host))
        let issue = Self.issue(5, url: "https://ghe.example/team/app/issues/5")
        XCTAssertNotNil(IssueDetailModel.browserURL(for: issue, host: host))
        XCTAssertNil(IssueDetailModel.browserURL(for: issue), "not a github.com page")
        XCTAssertNotNil(IssueDetailModel(issue, repository: repository).browserURL)
        XCTAssertEqual(IssueDetailModel(issue, repository: repository).repository, "ghe.example/team/app")
        let list = IssueListModel(content: .loaded(repository: repository, issues: [issue]), isLoading: false)
        XCTAssertNotNil(list.rows.first?.browserURL)
        for url in [
            "https://github.com/team/app/issues/5", "http://ghe.example/team/app/issues/5",
            "https://ghe.example.evil/team/app/issues/5", "https://ghe.example:8443/team/app/issues/5",
        ] {
            XCTAssertNil(IssueDetailModel(Self.issue(5, url: url), repository: repository).browserURL, url)
        }
    }
}
