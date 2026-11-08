import Foundation

/// A local or remote-tracking branch from `git for-each-ref` (parsing-spec.md §6).
struct Branch: Sendable, Hashable, Identifiable {
    enum Kind: Sendable, Hashable {
        case local
        case remote(remote: String)
    }

    /// Full ref name, e.g. `refs/heads/main` or `refs/remotes/origin/main`.
    let fullName: String
    let kind: Kind
    let target: ObjectID
    /// Upstream and ahead/behind from `%(upstream)` and `%(upstream:track,nobracket)`. The upstream name is the full
    /// ref name (`refs/remotes/origin/main`); remote-tracking branches have none.
    let upstreamStatus: UpstreamStatus
    /// Checked out in the main worktree (`%(HEAD)` is `*`).
    let isHead: Bool
    let committerDate: Date?
    /// Target of a symbolic ref such as `refs/remotes/origin/HEAD`.
    let symbolicTarget: String?
    /// The upstream's remote and its ref on that remote, from `branch.<name>.remote` and `branch.<name>.merge`
    /// (`%(upstream:remotename)`, `%(upstream:remoteref)`): `my/fork` and `refs/heads/feature`. A remote name may
    /// contain `/`, so these are never split out of `upstream` (ADR-0023 §4). `.` is the local repository. `nil`
    /// without an upstream or when the value is not valid UTF-8.
    var upstreamRemote: String? = nil
    var upstreamRemoteRef: String? = nil

    var id: String { fullName }

    /// Full upstream ref name, if configured (also when its remote-tracking ref is gone).
    var upstream: String? { upstreamStatus.upstreamName }

    /// `main` or `origin/main`.
    var shortName: String {
        for prefix in ["refs/heads/", "refs/remotes/"] where fullName.hasPrefix(prefix) {
            return String(fullName.dropFirst(prefix.count))
        }
        return fullName
    }
}

/// A tag from `git for-each-ref refs/tags` (parsing-spec.md §6).
struct Tag: Sendable, Hashable, Identifiable {
    let fullName: String
    /// The tag object for annotated tags, the commit for lightweight tags.
    let target: ObjectID
    /// The commit an annotated tag points to (`%(*objectname)`); `nil` for lightweight tags.
    let peeledTarget: ObjectID?
    let date: Date?

    var id: String { fullName }
    var shortName: String { fullName.hasPrefix("refs/tags/") ? String(fullName.dropFirst(10)) : fullName }
    /// The commit to show in the graph.
    var commit: ObjectID { peeledTarget ?? target }
}
