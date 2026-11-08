import Foundation

/// Picks GitLab projects from a repository's remotes (ADR-0026 §2). The URL forms and host rule are `HostedRemoteURL`
/// and `RemoteHost`, shared with GitHub (#117); this adds GitLab's `NAMESPACE/NAME` rule. A remote only names a
/// candidate: glab must report its host as logged in before anything is read from it.
enum GitLabRemote {
    /// Most hosts tried per load, so a repository with many remotes cannot make the app run glab for each.
    static let maximumHosts = 3

    /// Remotes in the order gh uses (ADR-0026 §2): `upstream` first, then configuration order. One project per host,
    /// the first remote on that host; hosts in `excluded` (github.com and gh's logged-in hosts, which gh handles) are
    /// skipped. At most `maximumHosts`.
    static func candidates(remotes: [(name: String, url: String)], excluding excluded: TrustedHosts) -> [GitLabProject]
    {
        let ordered = remotes.filter { $0.name == "upstream" } + remotes.filter { $0.name != "upstream" }
        var result: [GitLabProject] = []
        for remote in ordered where result.count < maximumHosts {
            guard let project = project(fromURL: remote.url), !excluded.contains(project.host),
                !result.contains(where: { $0.host == project.host })
            else { continue }
            result.append(project)
        }
        return result
    }

    /// The first host among `remotes` in a hosting form that no CLI is trusted for yet, for the "Not logged in to
    /// HOST" notice; `nil` when every remote is local or in another form.
    static func untrustedHost(remotes: [(name: String, url: String)], excluding excluded: TrustedHosts) -> RemoteHost? {
        let ordered = remotes.filter { $0.name == "upstream" } + remotes.filter { $0.name != "upstream" }
        return ordered.lazy.compactMap { HostedRemoteURL($0.url)?.host }.first { !excluded.contains($0) }
    }

    /// `NAMESPACE/NAME` from one of `HostedRemoteURL`'s forms (one trailing `.git` already dropped): every segment
    /// but the last is the namespace (1–20 groups), the last is the project.
    static func project(fromURL url: String) -> GitLabProject? {
        guard let remote = HostedRemoteURL(url), remote.pathSegments.count >= 2 else { return nil }
        return GitLabProject(
            host: remote.host, namespace: Array(remote.pathSegments.dropLast()),
            name: remote.pathSegments[remote.pathSegments.count - 1])
    }

    /// glab's `web_url` when it is exactly `https://HOST/NAMESPACE/NAME/-/issues/<iid>` or `…/-/work_items/<iid>` for
    /// this project (paths compared ASCII case-insensitively, as GitLab does), HOST the project's host, with no user,
    /// port, query, or fragment (ADR-0026 §5).
    static func issueURL(for issue: Issue, in project: GitLabProject) -> URL? {
        guard let parts = URLComponents(url: issue.url, resolvingAgainstBaseURL: false), parts.scheme == "https",
            parts.host == project.host.name, parts.user == nil, parts.password == nil, parts.port == nil,
            parts.query == nil, parts.fragment == nil
        else { return nil }
        let expected = (["", project.path, "-"]).joined(separator: "/")
        let path = parts.percentEncodedPath
        for kind in ["issues", "work_items"]
        where path.lowercased() == "\(expected)/\(kind)/\(issue.number)".lowercased() {
            return issue.url
        }
        return nil
    }
}
