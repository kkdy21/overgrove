/// Picks the github.com repository whose issues the panel shows, from the repository's remotes
/// (git-command-catalog.md §5, #81). Only the three github.com URL forms count; any other host leaves the panel at
/// "No GitHub remote".
enum GitHubRemote {
    /// Remote names tried first, in the order gh itself uses: a fork's issues live on `upstream`.
    static let preferredNames = ["upstream", "github", "origin"]

    private static let prefixes = ["https://github.com/", "git@github.com:", "ssh://git@github.com/"]

    /// The first remote, preferred names first and then configuration order, whose URL is a github.com repository.
    static func repository(remotes: [(name: String, url: String)]) -> GitHubRepository? {
        let preferred = preferredNames.compactMap { name in remotes.first { $0.name == name } }
        let rest = remotes.filter { !preferredNames.contains($0.name) }
        return (preferred + rest).lazy.compactMap { repository(fromURL: $0.url) }.first
    }

    /// Every remote whose URL is a github.com repository, by name. A name listed twice keeps its first URL.
    static func repositories(remotes: [(name: String, url: String)]) -> [String: GitHubRepository] {
        var result: [String: GitHubRepository] = [:]
        for remote in remotes where result[remote.name] == nil {
            if let repository = repository(fromURL: remote.url) { result[remote.name] = repository }
        }
        return result
    }

    /// `OWNER/NAME` from `https://github.com/OWNER/NAME(.git)?`, `git@github.com:OWNER/NAME(.git)?`, or
    /// `ssh://git@github.com/OWNER/NAME(.git)?`. Compared in UTF-8 bytes, so a combining mark cannot join a `/`;
    /// `GitHubRepository` then allows ASCII names only.
    static func repository(fromURL url: String) -> GitHubRepository? {
        guard let prefix = prefixes.first(where: { url.utf8.starts(with: $0.utf8) }) else { return nil }
        var path = String(decoding: url.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
        if path.hasSuffix(".git") { path.removeLast(4) }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[1].hasSuffix(".git") else { return nil }
        return GitHubRepository(owner: String(parts[0]), name: String(parts[1]))
    }
}
