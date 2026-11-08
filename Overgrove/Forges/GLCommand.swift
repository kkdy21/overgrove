/// The only glab commands Overgrove can run (git-command-catalog.md §5.1, ADR-0026 §3).
///
/// Nothing here can write to GitLab, log in or out, print a token, open a browser, call the API directly, or ask about
/// every configured host: `auth status -t/--show-token`, `auth status --all`, `glab api`, `--web`, and every write
/// command have no case.
enum GLCommand: Sendable, Hashable {
    case version
    /// Login state for one host. glab refuses a host it has no configuration for without using the network.
    case authStatus(host: RemoteHost)
    /// Open issues of one project (glab's default state), one GitLab API page.
    case issueList(project: GitLabProject)

    /// GitLab's largest page; glab cannot select fields, so descriptions come along (ADR-0026 §4).
    static let pageSize = 50

    var arguments: [String] {
        switch self {
        case .version:
            ["--version"]
        case .authStatus(let host):
            ["auth", "status", "--hostname", host.name, "--output", "json"]
        case .issueList(let project):
            ["issue", "list", "--repo", project.url, "--output", "json", "--per-page", String(Self.pageSize)]
        }
    }
}
