import Foundation

/// The PR pill on worktree and local branch rows (information-architecture.md §4.3, priority 7; ADR-0023 §5).
/// Pure, so it is unit tested without views.
struct PullRequestBadge: Equatable {
    let number: Int
    /// `#123`.
    let text: String
    let symbol: String
    /// A draft gets the open symbol with a dashed outline; the state is never shown by colour alone.
    let isDraft: Bool
    let stateText: String
    /// `Pull request #123 (Open): <title>`, escaped.
    let help: String
    /// `pull request 123, open`, appended to the row's VoiceOver label.
    let accessibilityText: String

    init(_ pullRequest: PullRequest) {
        number = pullRequest.number
        text = "#\(pullRequest.number)"
        stateText = Self.stateText(pullRequest)
        isDraft = pullRequest.state == .open && pullRequest.isDraft
        symbol =
            switch pullRequest.state {
            case .open: "arrow.triangle.pull"
            case .merged: "checkmark.circle"
            case .closed: "xmark.circle"
            case .unknown: "questionmark.circle"
            }
        help = "Pull request #\(pullRequest.number) (\(stateText)): \(PathValidator.displayable(pullRequest.title))"
        accessibilityText = "pull request \(pullRequest.number), \(stateText.lowercased())"
    }

    static func stateText(_ pullRequest: PullRequest) -> String {
        switch pullRequest.state {
        case .open: pullRequest.isDraft ? "Draft" : "Open"
        case .merged: "Merged"
        case .closed: "Closed"
        case .unknown: "Unknown state"
        }
    }
}

/// S-05's "Pull request" card (screens.md S-05, ADR-0023 §5). A merged PR shows the fact only: no clean-up advice or
/// command (ADR-0021).
struct PullRequestCardModel: Equatable {
    let badge: PullRequestBadge
    /// Escaped.
    let title: String
    /// `Approved`, `Changes requested`, `Review required`; `nil` without a decision.
    let review: String?
    /// The base branch, escaped; `nil` when gh gave none.
    let base: String?
    /// `nil` unless gh's URL is exactly this repository's page for this PR, so the button is off.
    let browserURL: URL?
    /// What Copy URL puts on the clipboard, escaped.
    let urlText: String

    init(_ pullRequest: PullRequest, repository: GitHubRepository?) {
        badge = PullRequestBadge(pullRequest)
        title = PathValidator.displayable(pullRequest.title)
        review =
            switch pullRequest.reviewDecision {
            case .approved: "Approved"
            case .changesRequested: "Changes requested"
            case .reviewRequired: "Review required"
            case .none: nil
            }
        base = pullRequest.baseRefName.isEmpty ? nil : PathValidator.displayable(pullRequest.baseRefName)
        browserURL = repository.flatMap { Self.browserURL(for: pullRequest, in: $0) }
        urlText = PathValidator.displayable(pullRequest.url.absoluteString)
    }

    /// gh's URL, only when it is exactly `https://github.com/<OWNER>/<NAME>/pull/<number>` for the repository the
    /// list was read from (OWNER and NAME compared ASCII case-insensitively) and this PR's number. Stricter than the
    /// issue rule, which accepts any github.com `OWNER/NAME` (ADR-0023 §3).
    static func browserURL(for pullRequest: PullRequest, in repository: GitHubRepository) -> URL? {
        guard let parts = URLComponents(url: pullRequest.url, resolvingAgainstBaseURL: false), parts.scheme == "https",
            parts.host == GHCommand.host, parts.user == nil, parts.password == nil, parts.port == nil,
            parts.query == nil, parts.fragment == nil
        else { return nil }
        let path = parts.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: false)
        guard path.count == 5, path[0].isEmpty, path[3] == "pull", path[4] == "\(pullRequest.number)",
            asciiCaseInsensitiveEqual(path[1], repository.owner), asciiCaseInsensitiveEqual(path[2], repository.name)
        else { return nil }
        return pullRequest.url
    }

    private static func asciiCaseInsensitiveEqual(_ lhs: Substring, _ rhs: String) -> Bool {
        let lower = { (byte: UInt8) in (0x41...0x5A).contains(byte) ? byte | 0x20 : byte }
        return lhs.utf8.map(lower) == rhs.utf8.map(lower)
    }
}

/// What PR pills need from the app, handed down the view tree like `issueBadges`.
struct PullRequestBadgeContext: Equatable {
    var links: PullRequestLinkIndex = .empty

    /// The pill for a local branch (full ref name), `nil` without a linked PR.
    func badge(forBranch fullName: String?) -> PullRequestBadge? {
        fullName.flatMap(links.pullRequest(forBranch:)).map(PullRequestBadge.init)
    }
}
