import Foundation

/// One row of the sidebar's ISSUES section (screens.md S-06): `#12` and the title on one line.
struct IssueRow: Identifiable, Equatable {
    let id: Int
    let number: String
    /// Escaped.
    let title: String
    /// A linked worktree (`tree`) or local branch (`arrow.triangle.branch`), #82.
    let linkKind: IssueLinkIndex.Kind?
    let accessibilityLabel: String
    /// Open in Browser (#73): only an issue page for this number on the repository's host
    /// (`IssueDetailModel.browserURL(for:host:)`).
    let browserURL: URL?
    /// What Copy URL puts on the clipboard, escaped.
    let urlText: String

    init(_ issue: Issue, linkKind: IssueLinkIndex.Kind? = nil, host: RemoteHost = GitHubRepository.publicHost) {
        self.init(issue, linkKind: linkKind, browserURL: IssueDetailModel.browserURL(for: issue, host: host))
    }

    /// A row of `source`'s issues: Open in Browser follows that provider's issue page rule.
    init(_ issue: Issue, linkKind: IssueLinkIndex.Kind? = nil, source: IssueSource) {
        self.init(issue, linkKind: linkKind, browserURL: source.browserURL(for: issue))
    }

    private init(_ issue: Issue, linkKind: IssueLinkIndex.Kind?, browserURL: URL?) {
        id = issue.number
        number = "#\(issue.number)"
        title = PathValidator.displayable(issue.title)
        self.linkKind = linkKind
        let link: String? =
            switch linkKind {
            case .worktree: "linked worktree"
            case .branch: "linked branch"
            case nil: nil
            }
        accessibilityLabel = (["Issue \(issue.number)", title] + [link].compactMap { $0 }).joined(separator: ", ")
        self.browserURL = browserURL
        urlText = PathValidator.displayable(issue.url.absoluteString)
    }
}

/// The ISSUES section (information-architecture.md §4.2, screens.md S-06). Pure, so it is unit tested without views.
struct IssueListModel: Equatable {
    struct Notice: Equatable {
        let symbol: String
        let text: String
        /// Shown as the tooltip ("Details").
        let detail: String?
    }

    /// Issues linked to a worktree or local branch first, then most recently updated first
    /// (information-architecture.md §4.2).
    private(set) var rows: [IssueRow]
    /// `nil` when the list is not available (no count in the header).
    let count: Int?
    let notice: Notice?
    /// What to run in Terminal when gh is missing or logged out (shared with S-07, #85). Overgrove never runs it.
    private(set) var guidance: GHStatusGuidance?
    /// Login commands to copy for a host no CLI is logged in to (ADR-0026 §7), one per CLI. The host in them passed
    /// `RemoteHost`, so it is a plain DNS name. Overgrove never runs them.
    private(set) var hostCommands: [String] = []
    /// Check Again is offered: every state except a loaded list.
    let canCheckAgain: Bool
    let isLoading: Bool
    /// The gh account the issues are read as (ADR-0025 §4), only while a repository's issues are shown or failed.
    let account: GHAccount?

    /// The line above the commands under the notice: gh's guidance, or the host login hint.
    var setupMessage: String? {
        guidance?.message ?? (hostCommands.isEmpty ? nil : "Run one of these in Terminal, then check again:")
    }

    /// The commands to copy under the notice.
    var setupCommands: [String] {
        guidance?.command.map { [$0] } ?? hostCommands
    }

    /// The rows whose number or title contains the sidebar filter (#74); the count stays the list's.
    func filtered(_ query: String?) -> IssueListModel {
        guard query != nil else { return self }
        var copy = self
        copy.rows = rows.filter { SidebarFilter.matches(query, $0.number, $0.title) }
        return copy
    }

    init(content: IssueListContent?, isLoading: Bool, links: IssueLinkIndex = .empty, account: GHAccount? = nil) {
        self.isLoading = isLoading
        switch content {
        case .loaded, .failed: self.account = account
        default: self.account = nil
        }
        canCheckAgain = Self.offersCheckAgain(content)
        switch content {
        case nil:
            rows = []
            count = nil
            notice = nil
        case .loaded(let repository, let issues):
            rows = issues.map { (issue: $0, kind: links.kind($0.number)) }
                .sorted { lhs, rhs in
                    if (lhs.kind != nil) != (rhs.kind != nil) { return lhs.kind != nil }
                    return (lhs.issue.updatedAt, lhs.issue.number) > (rhs.issue.updatedAt, rhs.issue.number)
                }
                .map { IssueRow($0.issue, linkKind: $0.kind, source: repository) }
            count = issues.count
            notice = issues.isEmpty ? Notice(symbol: "checkmark.circle", text: "No open issues", detail: nil) : nil
        // Degraded states (#83): Git features are unaffected; only this section explains and offers Check Again.
        case .noGitHubRemote:
            rows = []
            count = nil
            notice = Notice(
                symbol: "network.slash", text: "No GitHub remote",
                detail: "Issues appear for repositories with a remote on github.com or a host gh is logged in to.")
        case .notLoggedInToHost(let host):
            rows = []
            count = nil
            notice = Notice(
                symbol: "person.crop.circle.badge.exclamationmark", text: "Not logged in to \(host.name)",
                detail: "Issues appear when GitHub CLI, GitLab CLI, or Gitea CLI is logged in to this host.")
            hostCommands = [
                "gh auth login --hostname \(host.name)", "glab auth login --hostname \(host.name)",
                "gt auth login --host https://\(host.name)",
            ]
        case .notInstalled:
            rows = []
            count = nil
            notice = Notice(symbol: "exclamationmark.triangle", text: "GitHub CLI not installed", detail: nil)
            guidance = GHStatusGuidance(status: .notInstalled)
        case .notLoggedIn:
            rows = []
            count = nil
            notice = Notice(
                symbol: "person.crop.circle.badge.exclamationmark", text: "Not logged in to GitHub", detail: nil)
            guidance = GHStatusGuidance(status: .notLoggedIn)
        case .failed(let repository, let detail):
            rows = []
            count = nil
            notice = Notice(
                symbol: "exclamationmark.triangle", text: "Cannot read issues for \(repository.slug)",
                detail: detail.isEmpty ? nil : detail)
        }
    }
}

/// S-06's detail for one issue. The body is never shown (no Markdown, no remote images); `Open in Browser` is.
struct IssueDetailModel: Equatable {
    static let bodyNotice = "The issue body is not shown in Overgrove. Open it in your browser to read or reply."

    let number: String
    /// Escaped.
    let title: String
    /// `[HOST/]OWNER/NAME` the issues were read from: a repository's remote decides it, so it is always shown.
    let repository: String?
    let stateText: String
    let stateSymbol: String
    let updatedAt: Date
    /// Names only, escaped; GitHub's label colors are not used (screens.md S-06).
    let labels: [String]
    /// `@login`, escaped.
    let assignees: [String]
    /// `nil` when gh's URL is not an issue page for this number on the repository's host, so the button is off.
    let browserURL: URL?
    /// What Copy URL puts on the clipboard.
    let urlText: String
    /// LINKED (#82): worktrees and branches named for the issue, and the latest commits that reference it.
    let linkedWorktrees: [IssueLinkIndex.WorktreeLink]
    let linkedBranches: [IssueLinkIndex.BranchLink]
    let linkedCommits: [CommitLink]
    /// Linked worktrees and branches past `IssueLinkIndex.limitPerKind` (`and N more`).
    let hiddenLinkCount: Int

    init(
        _ issue: Issue, repository: GitHubRepository?, links: IssueLinkIndex.Links = .init(),
        commits: [CommitLink] = []
    ) {
        self.init(issue, source: repository.map(IssueSource.github), links: links, commits: commits)
    }

    init(_ issue: Issue, source: IssueSource?, links: IssueLinkIndex.Links = .init(), commits: [CommitLink] = []) {
        linkedWorktrees = links.worktrees
        linkedBranches = links.branches
        linkedCommits = commits
        hiddenLinkCount = links.hiddenCount
        number = "#\(issue.number)"
        title = PathValidator.displayable(issue.title)
        repository = source?.slug
        switch issue.state {
        case .open:
            stateText = "Open"
            stateSymbol = "number.circle"
        case .closed:
            stateText = "Closed"
            stateSymbol = "checkmark.seal"
        }
        updatedAt = issue.updatedAt
        labels = issue.labels.map { PathValidator.displayable($0.name) }
        assignees = issue.assignees.map { "@" + PathValidator.displayable($0) }
        browserURL =
            source.map { $0.browserURL(for: issue) } ?? Self.browserURL(for: issue, host: GitHubRepository.publicHost)
        urlText = PathValidator.displayable(issue.url.absoluteString)
    }

    /// gh's URL, when it is exactly `https://HOST/OWNER/NAME/issues/<number>` with valid names and HOST the
    /// repository's host (screens.md S-06, ADR-0025 §5). The repository part may differ from the remote's (a renamed
    /// or transferred repository redirects), but nothing else can be opened from here.
    static func browserURL(for issue: Issue, host: RemoteHost = GitHubRepository.publicHost) -> URL? {
        guard let parts = URLComponents(url: issue.url, resolvingAgainstBaseURL: false), parts.scheme == "https",
            parts.host == host.name, parts.user == nil, parts.password == nil, parts.port == nil,
            parts.query == nil, parts.fragment == nil
        else { return nil }
        let path = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 5, path[0].isEmpty, path[3] == "issues", path[4] == "\(issue.number)",
            GitHubRepository(owner: String(path[1]), name: String(path[2])) != nil
        else { return nil }
        return issue.url
    }
}

extension IssueListModel {
    fileprivate static func offersCheckAgain(_ content: IssueListContent?) -> Bool {
        switch content {
        case .noGitHubRemote, .notInstalled, .notLoggedIn, .notLoggedInToHost, .failed: true
        case .loaded, nil: false
        }
    }
}
