import Foundation

/// Where the issue panel reads issues from (S-06): a GitHub repository through gh (ADR-0004, ADR-0025), a GitLab
/// project through glab, or a Gitea repository through gt (ADR-0026). Chosen only from a verified listing's remotes, on a host the provider's CLI is
/// logged in to.
enum IssueSource: Sendable, Hashable {
    case github(GitHubRepository)
    case gitlab(GitLabProject)
    case gitea(GiteaRepository)

    var host: RemoteHost {
        switch self {
        case .github(let repository): repository.host
        case .gitlab(let project): project.host
        case .gitea(let repository): repository.instance.host
        }
    }

    /// Shown on S-06 so the user sees where the issues come from: `[HOST/]OWNER/NAME` for GitHub (no host for
    /// github.com), `HOST/NAMESPACE/NAME` for GitLab, `HOST[:PORT][/BASE]/OWNER/NAME` for Gitea.
    var slug: String {
        switch self {
        case .github(let repository): repository.slug
        case .gitlab(let project): project.description
        case .gitea(let repository): String(repository.description.dropFirst("https://".count))
        }
    }

    /// The path a commit message names this repository by in a cross-reference (`OWNER/NAME#12`, `group/app#12`).
    var referencePath: String {
        switch self {
        case .github(let repository): repository.ownerAndName
        case .gitlab(let project): project.path
        case .gitea(let repository): repository.slug
        }
    }

    var gitHubRepository: GitHubRepository? {
        if case .github(let repository) = self { return repository }
        return nil
    }

    /// The issue page to open, or `nil` when the CLI's URL is not exactly this repository's page for this issue on
    /// its host (ADR-0025 §5, ADR-0026 §5); then only Copy URL is offered.
    func browserURL(for issue: Issue) -> URL? {
        switch self {
        case .github(let repository): IssueDetailModel.browserURL(for: issue, host: repository.host)
        case .gitlab(let project): project.browserURL(for: issue)
        case .gitea(let repository): repository.browserURL(for: issue)
        }
    }
}
