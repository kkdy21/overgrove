/// One entry of `git worktree list --porcelain -z` (parsing-spec.md §2).
struct Worktree: Sendable, Hashable, Identifiable {
    enum Lock: Sendable, Hashable {
        case unlocked
        case locked(reason: String?)
    }

    let path: GitPath
    /// `nil` for an unborn branch.
    let head: ObjectID?
    /// Full ref name such as `refs/heads/main`; `nil` when detached or bare.
    let branch: String?
    let isMain: Bool
    let isDetached: Bool
    let isBare: Bool
    let lock: Lock
    let isPrunable: Bool
    let prunableReason: String?

    var id: GitPath { path }

    /// `main` for `refs/heads/main`.
    var branchShortName: String? {
        guard let branch else { return nil }
        let prefix = "refs/heads/"
        return branch.hasPrefix(prefix) ? String(branch.dropFirst(prefix.count)) : branch
    }

    var isLocked: Bool {
        if case .locked = lock { return true }
        return false
    }
}
