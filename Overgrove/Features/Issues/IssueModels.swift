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

    init(_ issue: Issue, linkKind: IssueLinkIndex.Kind? = nil) {
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
    let rows: [IssueRow]
    /// `nil` when the list is not available (no count in the header).
    let count: Int?
    let notice: Notice?
    let isLoading: Bool

    init(content: IssueListContent?, isLoading: Bool, links: IssueLinkIndex = .empty) {
        self.isLoading = isLoading
        switch content {
        case nil:
            rows = []
            count = nil
            notice = nil
        case .loaded(_, let issues):
            rows = issues.map { (issue: $0, kind: links.kind($0.number)) }
                .sorted { lhs, rhs in
                    if (lhs.kind != nil) != (rhs.kind != nil) { return lhs.kind != nil }
                    return (lhs.issue.updatedAt, lhs.issue.number) > (rhs.issue.updatedAt, rhs.issue.number)
                }
                .map { IssueRow($0.issue, linkKind: $0.kind) }
            count = issues.count
            notice = issues.isEmpty ? Notice(symbol: "checkmark.circle", text: "No open issues", detail: nil) : nil
        // TODO(#83): guidance for these states (copyable `gh auth login`, Check again, S-07).
        case .noGitHubRemote:
            rows = []
            count = nil
            notice = Notice(symbol: "network.slash", text: "No GitHub remote", detail: nil)
        case .notInstalled:
            rows = []
            count = nil
            notice = Notice(symbol: "exclamationmark.triangle", text: "GitHub CLI not installed", detail: nil)
        case .notLoggedIn:
            rows = []
            count = nil
            notice = Notice(
                symbol: "person.crop.circle.badge.exclamationmark", text: "Not logged in to GitHub",
                detail: "Run gh auth login in Terminal.")
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
    /// `OWNER/NAME` the issues were read from: a repository's remote decides it, so it is always shown.
    let repository: String?
    let stateText: String
    let stateSymbol: String
    let updatedAt: Date
    /// Names only, escaped; GitHub's label colors are not used (screens.md S-06).
    let labels: [String]
    /// `@login`, escaped.
    let assignees: [String]
    /// `nil` when gh's URL is not a github.com issue page for this number, so the button is off.
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
        linkedWorktrees = links.worktrees
        linkedBranches = links.branches
        linkedCommits = commits
        hiddenLinkCount = links.hiddenCount
        number = "#\(issue.number)"
        title = PathValidator.displayable(issue.title)
        self.repository = repository?.slug
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
        browserURL = Self.browserURL(for: issue)
        urlText = PathValidator.displayable(issue.url.absoluteString)
    }

    /// gh's URL, when it is exactly `https://github.com/OWNER/NAME/issues/<number>` with valid names (screens.md
    /// S-06: https and the remote's GitHub host). The repository part may differ from the remote's (a renamed or
    /// transferred repository redirects), but nothing else can be opened from here.
    static func browserURL(for issue: Issue) -> URL? {
        guard let parts = URLComponents(url: issue.url, resolvingAgainstBaseURL: false), parts.scheme == "https",
            parts.host == GHCommand.host, parts.user == nil, parts.password == nil, parts.port == nil,
            parts.query == nil, parts.fragment == nil
        else { return nil }
        let path = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 5, path[0].isEmpty, path[3] == "issues", path[4] == "\(issue.number)",
            GitHubRepository(owner: String(path[1]), name: String(path[2])) != nil
        else { return nil }
        return issue.url
    }
}
