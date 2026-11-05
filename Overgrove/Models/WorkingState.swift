/// A worktree's uncommitted state from `git status --porcelain=v2 -z --branch --show-stash` (parsing-spec.md §3).
struct WorkingState: Sendable, Hashable {
    enum Head: Sendable, Hashable {
        /// Short branch name, e.g. `main`.
        case branch(String)
        case detached
    }

    /// `nil` when the branch has no commits yet (`# branch.oid (initial)`).
    let headCommit: ObjectID?
    let head: Head
    let upstream: UpstreamStatus
    let stashCount: Int
    /// Index changes. A file changed in both index and worktree (`MM`) appears in `staged` and `unstaged`.
    let staged: [FileChange]
    let unstaged: [FileChange]
    let untracked: [FileChange]
    let conflicted: [FileChange]
    /// Output was cut at the size limit; the last record was dropped (parsing-spec.md §1.5).
    let isPartial: Bool
    /// Records of an unknown kind that were skipped (parsing-spec.md §1.6).
    let skippedRecords: Int

    var isClean: Bool { staged.isEmpty && unstaged.isEmpty && untracked.isEmpty && conflicted.isEmpty }

    /// Number of distinct changed paths, for sidebar badges.
    var changedPathCount: Int {
        Set((staged + unstaged + untracked + conflicted).map(\.path)).count
    }
}
