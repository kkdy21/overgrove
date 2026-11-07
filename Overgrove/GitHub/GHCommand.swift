/// The only gh commands Overgrove can run (git-command-catalog.md §5, ADR-0004, threat T13).
///
/// Nothing here can write to GitHub, log in or out, or print a token: `gh auth login/logout/refresh/setup-git`,
/// `gh api`, `gh pr *`, `gh repo *`, `gh issue create/edit/close`, and `--show-token` have no case
/// (git-command-catalog.md §7). Repository-scoped commands always pass `--repo`, so gh never infers the repository
/// from a working directory.
enum GHCommand: Sendable, Hashable {
    case version
    case authStatus
    case issueList(repo: GitHubRepository)

    /// Only github.com is supported in v0.1 (ADR-0004 §8).
    static let host = "github.com"

    static let issueFields = "number,title,state,labels,assignees,updatedAt,url"

    var arguments: [String] {
        switch self {
        case .version:
            ["--version"]
        case .authStatus:
            ["auth", "status", "--hostname", Self.host, "--json", "hosts"]
        case .issueList(let repo):
            [
                "issue", "list", "--repo", repo.slug, "--state", "open", "--limit", "200", "--json",
                Self.issueFields,
            ]
        }
    }
}

/// A validated github.com `OWNER/NAME` for `--repo` (git-command-catalog.md §5).
///
/// OWNER is 1–39 ASCII letters, digits, or hyphens and does not start with a hyphen, so the `--repo` value can
/// never be read as an option. NAME is 1–100 ASCII letters, digits, `.`, `_`, or `-`, and is not `.` or `..`.
struct GitHubRepository: Sendable, Hashable, CustomStringConvertible {
    let owner: String
    let name: String

    init?(owner: String, name: String) {
        guard Self.isValidOwner(owner), Self.isValidName(name) else { return nil }
        self.owner = owner
        self.name = name
    }

    /// `OWNER/NAME`.
    var slug: String { "\(owner)/\(name)" }

    var description: String { slug }

    private static func isValidOwner(_ owner: String) -> Bool {
        let utf8 = owner.utf8
        return (1...39).contains(utf8.count) && utf8.first != UInt8(ascii: "-")
            && utf8.allSatisfy { isASCIIAlphanumeric($0) || $0 == UInt8(ascii: "-") }
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
