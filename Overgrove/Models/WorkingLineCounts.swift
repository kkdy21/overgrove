/// Per-file line counts of a worktree's uncommitted changes (screens.md S-02, #230): staged from
/// `diff --cached --numstat`, unstaged from `diff --numstat` (`ReadOnlyGitCommand.worktreeNumstat`).
///
/// Keyed by the new path, as `WorkingState` lists files. Untracked files never have counts (git diff does not list
/// them), and conflicted paths are left out on purpose (parsing-spec.md §8.3).
struct WorkingLineCounts: Sendable, Equatable {
    let staged: [GitPath: FileStat]
    let unstaged: [GitPath: FileStat]
    /// An output was cut at the size limit: files past the cut have no counts, and totals would be too small.
    let isPartial: Bool

    init(staged: [FileStat], unstaged: [FileStat], isPartial: Bool) {
        self.staged = Dictionary(staged.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        self.unstaged = Dictionary(unstaged.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        self.isPartial = isPartial
    }
}
