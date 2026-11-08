import Foundation

/// `gh` login state (parsing-spec.md §10.1). The app never sees the token itself.
enum GHAuthStatus: Sendable, Hashable {
    case notInstalled
    case notLoggedIn
    case loggedIn(login: String)
}

/// One `gh auth status` reading (ADR-0025 §1): github.com's state for the status bar, and the hosts gh is logged in
/// to, which the app trusts besides github.com.
struct GHAuthReport: Sendable, Hashable {
    let status: GHAuthStatus
    /// Empty when gh is missing or lists no host.
    let hosts: Set<RemoteHost>
    /// Each host's active account, for display only (ADR-0025 §4); a host without a usable active account is absent.
    let accounts: [RemoteHost: GHAccount]

    init(status: GHAuthStatus, hosts: Set<RemoteHost>, accounts: [RemoteHost: GHAccount] = [:]) {
        self.status = status
        self.hosts = hosts
        self.accounts = accounts
    }
}

/// The account gh uses on one host (ADR-0025 §4). Overgrove only shows it: switching is the user's, in Terminal.
struct GHAccount: Sendable, Hashable {
    let host: RemoteHost
    /// A GitHub login (`GHAuthParser.isGitHubLogin`).
    let login: String
    /// The host's other accounts in gh.
    let otherCount: Int

    /// `login@host`.
    var text: String { PathValidator.displayable("\(login)@\(host.name)") }

    /// `+2 more`, `nil` with one account.
    var moreText: String? { otherCount > 0 ? "+\(otherCount) more" : nil }

    /// `gh auth switch --hostname HOST` to copy, `nil` with one account. Only the validated host goes in, never the
    /// login, and the text is escaped like every clipboard value (ADR-0021 §3).
    var switchCommand: String? {
        otherCount > 0 ? RowActions.clipboardText("gh auth switch --hostname \(host.name)") : nil
    }
}

/// A GitHub issue from `gh issue list --json` (parsing-spec.md §10.2).
struct Issue: Sendable, Hashable, Identifiable {
    enum State: String, Sendable, Hashable {
        case open = "OPEN"
        case closed = "CLOSED"
    }

    struct Label: Sendable, Hashable {
        let name: String
        /// Hex color without `#`, as returned by GitHub.
        let color: String?
    }

    let number: Int
    let title: String
    let state: State
    let labels: [Label]
    let assignees: [String]
    let updatedAt: Date
    let url: URL

    var id: Int { number }
}

/// A pull request from `gh pr list --json` (parsing-spec.md §10.3, ADR-0023). Text fields are raw: escape them before
/// showing them.
struct PullRequest: Sendable, Hashable, Identifiable {
    enum State: Sendable, Hashable {
        case open
        case closed
        case merged
        /// A value this version does not know.
        case unknown
    }

    enum ReviewDecision: Sendable, Hashable {
        case approved
        case changesRequested
        case reviewRequired
        /// No decision (gh prints an empty string), or a value this version does not know.
        case none
    }

    /// Where the PR's commits come from. Anyone can open a PR from a fork with any branch name, so a PR is tied to a
    /// branch only when all three match that branch's upstream (ADR-0023 §4).
    struct Head: Sendable, Hashable {
        let owner: String
        let name: String
        let branch: String
    }

    let number: Int
    let title: String
    let state: State
    let isDraft: Bool
    /// `nil` when gh gives no head repository or owner (a deleted fork): the PR is listed but linked to nothing.
    let head: Head?
    let baseRefName: String
    let reviewDecision: ReviewDecision
    let updatedAt: Date?
    let url: URL

    var id: Int { number }
}
