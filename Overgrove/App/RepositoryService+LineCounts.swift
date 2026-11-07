import Foundation

/// The WIP detail's per-file line counts (screens.md S-02, #230), queried for one worktree when its detail is shown.
extension RepositoryService {
    /// Staged and unstaged numstat of `worktree`, in parallel, after the same checks as its status (`prepare`).
    /// Returns `nil` when the worktree is not queried (foreign, blocked by its configuration, gone).
    ///
    /// `state` is the cached status the counts go with: its conflicted paths are dropped from the output, since git
    /// prints them twice and the screen shows no counts for them (parsing-spec.md §8.3).
    static func queryLineCounts(
        of worktree: Worktree,
        state: WorkingState,
        _ context: Context
    ) async throws -> WorkingLineCounts? {
        let listed = URL(fileURLWithPath: worktree.path.display, isDirectory: true)
        guard worktree.path.isRepresentable, !worktree.isBare, let folder = PathValidator.canonical(listed) else {
            return nil
        }
        guard case .ready(let safety) = try await prepare(worktree, at: folder, context) else { return nil }

        let client = context.client
        async let stagedOutput = client.run(.worktreeNumstat(staged: true), in: folder, safety: safety)
        async let unstagedOutput = client.run(.worktreeNumstat(staged: false), in: folder, safety: safety)
        let (staged, unstaged) = try await (stagedOutput, unstagedOutput)

        let conflicted = Set(state.conflicted.map(\.path))
        let stagedFiles = try NumstatParser.parseWorktreeFiles(
            staged.stdout, excluding: conflicted, truncated: staged.isTruncated)
        let unstagedFiles = try NumstatParser.parseWorktreeFiles(
            unstaged.stdout, excluding: conflicted, truncated: unstaged.isTruncated)
        return WorkingLineCounts(
            staged: stagedFiles.files, unstaged: unstagedFiles.files,
            isPartial: stagedFiles.isPartial || unstagedFiles.isPartial)
    }
}
