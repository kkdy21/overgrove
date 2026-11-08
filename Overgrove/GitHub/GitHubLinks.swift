import Foundation

/// github.com pages for Open on GitHub (#398, interaction.md §5). Built only from a validated `GitHubRepository`, a
/// full object ID, a validated ref, and a representable path; each path component is percent-encoded on its own and
/// the URL is assembled with `URLComponents`, so repository text can never change the scheme, the host, or add a
/// query. The result still goes through `RowActions.browserTarget` (https only) before it opens.
enum GitHubLinks {
    /// `https://github.com/OWNER/NAME/commit/<oid>`.
    static func commit(_ repository: GitHubRepository, _ oid: ObjectID) -> URL? {
        url(repository, ["commit", oid.hex])
    }

    /// `https://github.com/OWNER/NAME/tree/<branch>` for a branch row's target (#406): the repository of the remote the
    /// branch tracks, resolved and validated by `GitHubBranchTarget`. `nil` for an empty name or `HEAD`; each
    /// `/`-separated part is encoded on its own.
    static func tree(_ target: GitHubBranchTarget) -> URL? {
        // `GitHubBranchTarget` already validated the ref; checked again here as defense in depth.
        guard !target.branch.isEmpty, target.branch != "HEAD", FullRefName("refs/heads/" + target.branch) != nil
        else { return nil }
        return url(
            target.repository,
            ["tree"] + target.branch.split(separator: "/", omittingEmptySubsequences: false).map(String.init))
    }

    /// `https://github.com/OWNER/NAME/blob/<oid>/<path>`. `nil` for a path git cannot name losslessly.
    static func file(_ repository: GitHubRepository, commit: ObjectID, path: GitPath) -> URL? {
        guard let argument = path.argument else { return nil }
        return url(
            repository,
            ["blob", commit.hex] + argument.split(separator: "/", omittingEmptySubsequences: false).map(String.init))
    }

    /// Characters left as they are inside one path component.
    private static let componentAllowed = CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/;?#%"))

    private static func url(_ repository: GitHubRepository, _ parts: [String]) -> URL? {
        let components = [repository.owner, repository.name] + parts
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        let encoded = components.compactMap { $0.addingPercentEncoding(withAllowedCharacters: componentAllowed) }
        guard encoded.count == components.count else { return nil }
        var url = URLComponents()
        url.scheme = "https"
        url.host = "github.com"
        url.percentEncodedPath = "/" + encoded.joined(separator: "/")
        return url.url
    }
}
