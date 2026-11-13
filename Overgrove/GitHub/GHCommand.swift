/// The only gh commands Overgrove can run (git-command-catalog.md §5, ADR-0004, threat T13).
///
/// Nothing here can write to GitHub, log in or out, or print a token: `gh auth login/logout/refresh/setup-git`,
/// `gh api`, every `gh pr` other than `gh pr list` (ADR-0023), `gh repo *`, `gh issue create/edit/close`, and
/// `--show-token` have no case (git-command-catalog.md §7). Repository-scoped commands always pass `--repo`, so gh never infers the repository
/// from a working directory.
enum GHCommand: Sendable, Hashable {
    case version
    case authStatus
    case issueList(repo: GitHubRepository)
    /// Open, merged, and closed pull requests: the 200 most recently created (gh's order), ADR-0023.
    case prList(repo: GitHubRepository)

    /// GitHub's public host, always trusted. Other hosts are trusted only when gh reports a login for them
    /// (ADR-0025 §1).
    static let host = "github.com"

    static let issueFields = "number,title,state,labels,assignees,updatedAt,url"

    /// No body, comments, files, reviews, or CI status (ADR-0023 §1).
    static let pullRequestFields =
        "number,title,state,isDraft,isCrossRepository,headRefName,headRepositoryOwner,headRepository,baseRefName,"
        + "reviewDecision,mergedAt,updatedAt,url"

    var arguments: [String] {
        switch self {
        case .version:
            ["--version"]
        case .authStatus:
            ["auth", "status", "--json", "hosts"]
        case .issueList(let repo):
            [
                "issue", "list", "--repo", repo.repoArgument, "--state", "open", "--limit", "200", "--json",
                Self.issueFields,
            ]
        case .prList(let repo):
            [
                "pr", "list", "--repo", repo.repoArgument, "--state", "all", "--limit", "200", "--json",
                Self.pullRequestFields,
            ]
        }
    }
}

/// A validated GitHub `[HOST/]OWNER/NAME` for `--repo` (git-command-catalog.md §5, ADR-0025 §2–§3).
///
/// OWNER is 1–39 ASCII letters, digits, or hyphens and does not start with a hyphen, so the `--repo` value can
/// never be read as an option; an Enterprise Managed User's `handle_shortcode` is accepted too (`GitHubName`, #486).
/// NAME is 1–100 ASCII letters, digits, `.`, `_`, or `-`, and is not `.` or `..`. HOST is a `RemoteHost` (a DNS
/// name, which cannot start with a hyphen either); `github.com` unless a remote on a host gh is logged in to says
/// otherwise.
struct GitHubRepository: Sendable, Hashable, CustomStringConvertible {
    // swift-format-ignore: NeverForceUnwrap
    /// A constant that is a valid host name.
    static let publicHost = RemoteHost(GHCommand.host)!

    let host: RemoteHost
    let owner: String
    let name: String

    init?(owner: String, name: String, host: RemoteHost = Self.publicHost) {
        guard Self.isValidOwner(owner), Self.isValidName(name) else { return nil }
        self.host = host
        self.owner = owner
        self.name = name
    }

    /// `HOST/OWNER/NAME`, github.com included: the `--repo` value. The host is always named so gh never chooses it
    /// (ADR-0025 §3).
    var repoArgument: String { "\(host.name)/\(owner)/\(name)" }

    /// `OWNER/NAME` on github.com, `HOST/OWNER/NAME` elsewhere: what the app shows.
    var slug: String { host == Self.publicHost ? "\(owner)/\(name)" : "\(host.name)/\(owner)/\(name)" }

    /// `OWNER/NAME` on any host: how commit messages refer to the repository (`owner/name#12`).
    var ownerAndName: String { "\(owner)/\(name)" }

    var description: String { slug }

    private static func isValidOwner(_ owner: String) -> Bool {
        guard (1...39).contains(owner.utf8.count), let handle = GitHubName.handle(owner) else { return false }
        return !handle.isEmpty && handle.first != UInt8(ascii: "-")
            && handle.allSatisfy { isASCIIAlphanumeric($0) || $0 == UInt8(ascii: "-") }
    }

    private static func isValidName(_ name: String) -> Bool {
        let utf8 = name.utf8
        guard (1...100).contains(utf8.count), name != ".", name != ".." else { return false }
        return utf8.allSatisfy {
            isASCIIAlphanumeric($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-")
        }
    }

    private static func isASCIIAlphanumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte) || (0x41...0x5A).contains(byte) || (0x61...0x7A).contains(byte)
    }
}
