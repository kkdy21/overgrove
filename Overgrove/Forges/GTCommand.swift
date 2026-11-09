/// The only gt (gitea/cli) commands Overgrove can run (git-command-catalog.md §5.1, ADR-0026 §3).
///
/// Nothing here can write to Gitea, log in or out, print a token, open a browser, call the API directly, run an
/// extension, or ask the server to verify credentials: `gt api`, `gt <extension>`, `--web`, `auth status --verify`, and
/// every write command have no case.
enum GTCommand: Sendable, Hashable {
    case version
    /// Accounts gt has local credentials for. Reads only local state; no request is made (no `--verify`).
    case authStatus
    /// Open issues (not pull requests) of one repository on an instance gt has an account for.
    case issueList(repository: GiteaRepository)

    /// The fields read from `auth status` (ADR-0026 §4).
    static let authFields = "host,user,credential_available"
    /// The fields read from `issue list`; the body is not requested.
    static let issueFields = "number,title,state,labels,assignees,updated_at,url"
    static let issueLimit = 200

    var arguments: [String] {
        switch self {
        case .version:
            ["--version"]
        case .authStatus:
            ["auth", "status", "--json", Self.authFields]
        case .issueList(let repository):
            [
                "issue", "list", "--host", repository.instance.url, "--repo", repository.slug, "--state", "open",
                "--kind", "issues", "--limit", String(Self.issueLimit), "--no-input", "--json", Self.issueFields,
            ]
        }
    }
}
