/// Picks the GitHub repository whose issues and pull requests the app shows, from the repository's remotes
/// (git-command-catalog.md §5, #81, ADR-0025). The URL forms and host checks are `HostedRemoteURL` and
/// `TrustedHosts`, shared with other providers; this adds GitHub's `OWNER/NAME` rule. A remote on a host gh is not
/// logged in to leaves the panel at "No GitHub remote".
enum GitHubRemote {
    /// Remote names tried first, in the order gh itself uses: a fork's issues live on `upstream`.
    static let preferredNames = ["upstream", "github", "origin"]

    /// github.com only: before gh's login list is read, or when it cannot be.
    static let publicOnly = TrustedHosts(publicHost: GitHubRepository.publicHost)

    /// The first remote, preferred names first and then configuration order, whose URL is a GitHub repository on a
    /// trusted host.
    static func repository(
        remotes: [(name: String, url: String)], trusting hosts: TrustedHosts = publicOnly
    ) -> GitHubRepository? {
        match(remotes: remotes, trusting: hosts)?.repository
    }

    /// The same remote, with its name (Open on GitHub for its remote-tracking branches, #398).
    static func match(
        remotes: [(name: String, url: String)], trusting hosts: TrustedHosts = publicOnly
    ) -> (name: String, repository: GitHubRepository)? {
        let preferred = preferredNames.compactMap { name in remotes.first { $0.name == name } }
        let rest = remotes.filter { !preferredNames.contains($0.name) }
        return (preferred + rest).lazy.compactMap { remote in
            repository(fromURL: remote.url, trusting: hosts).map { (remote.name, $0) }
        }.first
    }

    /// Every remote whose URL is a GitHub repository on a trusted host, by name. A name listed twice keeps its first
    /// URL.
    static func repositories(
        remotes: [(name: String, url: String)], trusting hosts: TrustedHosts = publicOnly
    ) -> [String: GitHubRepository] {
        var result: [String: GitHubRepository] = [:]
        for remote in remotes where result[remote.name] == nil {
            if let repository = repository(fromURL: remote.url, trusting: hosts) { result[remote.name] = repository }
        }
        return result
    }

    /// The repository of the remote whose name is exactly `name`, byte for byte (#546). `remotes[name]` is not enough:
    /// a `String` key folds canonical equivalence, so a hand-edited `branch.<b>.remote` spelled with KELVIN SIGN
    /// (U+212A) or in NFD would find the GitHub remote spelled in ASCII or NFC, which git treats as a different remote.
    /// Found by key in O(1), then the stored key's bytes are compared.
    static func repository(named name: String, in remotes: [String: GitHubRepository]) -> GitHubRepository? {
        guard let found = remotes.index(forKey: name), remotes[found].key.utf8.elementsEqual(name.utf8) else {
            return nil
        }
        return remotes[found].value
    }

    /// `[HOST/]OWNER/NAME` from one of `HostedRemoteURL`'s forms, when HOST is trusted and the path is exactly
    /// `OWNER/NAME(.git)?` with valid names (`GitHubRepository`, ASCII only).
    static func repository(fromURL url: String, trusting hosts: TrustedHosts = publicOnly) -> GitHubRepository? {
        guard let remote = HostedRemoteURL(url), hosts.contains(remote.host), remote.pathSegments.count == 2,
            !remote.pathSegments[1].hasSuffix(".git")
        else { return nil }
        return GitHubRepository(owner: remote.pathSegments[0], name: remote.pathSegments[1], host: remote.host)
    }
}
