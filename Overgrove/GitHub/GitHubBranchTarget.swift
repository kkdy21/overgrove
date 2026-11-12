import Foundation

/// The GitHub repository and branch a sidebar branch row opens on GitHub (#406): the repository of the remote the
/// branch tracks, not only the one the issue panel uses. In a fork flow (`origin` is my fork, `upstream` the
/// original), a local branch tracking `origin/feat` opens `https://github.com/<me>/<repo>/tree/feat`.
///
/// Only remotes a verified listing inspected (a cached paint passes none) and `GitHubRemote` accepted (a trusted host, ADR-0025; valid
/// `OWNER/NAME`) count.
/// The remote name never comes from splitting a ref on `/`, because remote names may contain `/`:
/// - a local branch uses `branch.<name>.remote` and `branch.<name>.merge` (`Branch.upstreamRemote`,
///   `upstreamRemoteRef`, ADR-0023 §4); the branch on GitHub is the merge ref without `refs/heads/`;
/// - a remote-tracking row is matched against every configured remote name, longest first (#466), so `refs/remotes/my/fork/x`
///   belongs to `my/fork` when both `my` and `my/fork` exist. Its branch is the `refs/heads/` ref the remote's fetch
///   refspecs map it from (#490), not a guess from the default refspec; `HEAD` is not a branch.
struct GitHubBranchTarget: Equatable, Sendable {
    let repository: GitHubRepository
    /// The branch name on GitHub (`feat/x`), never empty.
    let branch: String

    /// For a local branch: its upstream's remote and merge ref. `nil` without an upstream, for a local upstream
    /// (`.`), a remote that is not a GitHub repository on a trusted host, or a merge ref outside `refs/heads/`.
    static func forLocal(_ branch: Branch, remotes: [String: GitHubRepository]) -> GitHubBranchTarget? {
        guard branch.kind == .local, let remote = branch.upstreamRemote, let repository = remotes[remote],
            let ref = branch.upstreamRemoteRef, FullRefName(ref) != nil
        else { return nil }
        return target(repository, ref, prefix: "refs/heads/")
    }

    /// For a remote-tracking ref (`refs/remotes/<remote>/<branch>`): the remote whose name is its longest matching
    /// prefix among every configured remote (`configuredRemotes`) and the GitHub ones, then that remote's GitHub
    /// repository. `nil` when that remote is not a GitHub repository (#466: with `my` on GitHub and `my/fork`
    /// elsewhere, `refs/remotes/my/fork/x` is `my/fork`'s, never `my`'s `fork/x`), an unknown remote, or
    /// `<remote>/HEAD`.
    static func forRemoteRef(
        _ ref: String, remotes: [String: GitHubRepository], configuredRemotes: [String],
        fetchRefspecs: [String: [String]]
    ) -> GitHubBranchTarget? {
        forRemoteRef(
            ref, remotes: remotes, index: RemoteNameIndex(configuredRemotes + remotes.keys),
            fetchRefspecs: fetchRefspecs.mapValues { $0.compactMap(FetchRefspec.init) })
    }

    /// The same, with the configured and GitHub remote names already indexed (once per sidebar, not per row).
    /// Names compare in bytes, so a remote spelled in NFD is not taken for one in NFC (#489).
    ///
    /// The branch is what the remote's fetch refspecs (`fetchRefspecs`, by remote name) map the ref from under
    /// `refs/heads/` (#490): `origin/pr/123` fetched from `refs/pull/123/head` opens nothing, and a remote without
    /// refspecs opens nothing.
    static func forRemoteRef(
        _ ref: String, remotes: [String: GitHubRepository], index: RemoteNameIndex,
        fetchRefspecs: [String: [FetchRefspec]]
    ) -> GitHubBranchTarget? {
        let prefix = "refs/remotes/"
        guard FullRefName(ref) != nil, ref.utf8.starts(with: prefix.utf8),
            let match = index.remote(of: String(decoding: ref.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)),
            // O(1) by key, then the stored key's bytes: a `String` key lookup folds normalization (#489, T15).
            let found = remotes.index(forKey: match), remotes[found].key.utf8.elementsEqual(match.utf8)
        else { return nil }
        let repository = remotes[found].value
        guard !ref.utf8.dropFirst(prefix.utf8.count + match.utf8.count + 1).elementsEqual("HEAD".utf8),
            let branch = FetchRefspec.sourceBranch(of: ref, refspecs: fetchRefspecs[match] ?? []),
            // The branch comes from the repository's refspec now, not only from the checked ref: check it again.
            FullRefName("refs/heads/\(branch)") != nil
        else { return nil }
        return GitHubBranchTarget(repository: repository, branch: branch)
    }

    /// The part of `ref` after `prefix`, compared in bytes (Swift `String` comparison folds normalization).
    private static func target(_ repository: GitHubRepository, _ ref: String, prefix: String) -> GitHubBranchTarget? {
        guard ref.utf8.starts(with: prefix.utf8) else { return nil }
        let branch = String(decoding: ref.utf8.dropFirst(prefix.utf8.count), as: UTF8.self)
        guard !branch.isEmpty else { return nil }
        return GitHubBranchTarget(repository: repository, branch: branch)
    }
}
