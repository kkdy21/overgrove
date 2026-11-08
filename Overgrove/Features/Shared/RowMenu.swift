import SwiftUI

/// What row context menus can do (interaction.md §5, #73), handed down the view tree like `issueBadges`. Look and
/// copy only: there is no write action here, not even a disabled one.
struct RowMenuActions {
    /// The WIP row's worktree.
    var focusedWorktree: GitPath?
    var copy: @MainActor (String) -> Void = { _ in }
    var copyMessage: @MainActor (String) -> Void = { _ in }
    var showCommit: @MainActor (ObjectID) -> Void = { _ in }
    /// `Compare with Selected Commit` on a graph row (S-12, #388): whether it is on, and opening it.
    var canCompareCommit: @MainActor (ObjectID) -> Bool = { _ in false }
    var compareCommit: @MainActor (ObjectID) -> Void = { _ in }
    /// The full message when S-03 has loaded it, else the subject.
    var commitMessage: @MainActor (CommitNode) -> String = { $0.subject }
    /// The absolute path of `path` in `worktree` (the focused worktree when `nil`).
    var fullPath: @MainActor (_ worktree: GitPath?, _ path: GitPath) -> String? = { _, _ in nil }
    var revealFile: @MainActor (_ worktree: GitPath?, _ path: GitPath) -> Void = { _, _ in }
    var showWorktreeChanges: @MainActor (GitPath) -> Void = { _ in }
    var showWorktreeInfo: @MainActor (GitPath) -> Void = { _ in }
    var revealWorktree: @MainActor (GitPath) -> Void = { _ in }
    var openTerminal: @MainActor (GitPath) -> Void = { _ in }
    var showStash: @MainActor (ObjectID) -> Void = { _ in }
    var openInBrowser: @MainActor (URL) -> Void = { _ in }
    /// Open on GitHub (#398): the page of a commit, a remote-tracking ref of the GitHub remote, or a file at a commit;
    /// `nil` without a github.com remote or for anything that cannot be named on GitHub.
    var gitHubCommitURL: @MainActor (ObjectID) -> URL? = { _ in nil }
    var gitHubBranchURL: @MainActor (_ remoteRef: String) -> URL? = { _ in nil }
    var gitHubFileURL: @MainActor (_ commit: ObjectID, _ path: GitPath) -> URL? = { _, _ in nil }
    var linkedBranchTip: @MainActor (Int) -> ObjectID? = { _ in nil }
    /// S-09 for `path` in `worktree` (the focused worktree when `nil`), #70.
    var showHistory: @MainActor (_ worktree: GitPath?, _ path: GitPath) -> Void = { _, _ in }
}

private struct RowMenuActionsKey: EnvironmentKey {
    static let defaultValue = RowMenuActions()
}

extension EnvironmentValues {
    var rowMenu: RowMenuActions {
        get { self[RowMenuActionsKey.self] }
        set { self[RowMenuActionsKey.self] = newValue }
    }
}

/// The file row menu of S-02, S-03, and S-04 (interaction.md §5). Show History opens S-09 (#70).
struct FileRowMenu: View {
    /// The worktree the path is in; `nil` for commit and stash files, which are looked up in the focused worktree.
    let worktree: GitPath?
    let path: GitPath
    let showDiff: () -> Void
    /// The commit the file belongs to (S-03), for Open on GitHub; `nil` for working tree and stash files, which are
    /// not on GitHub (#398).
    var commit: ObjectID?

    @Environment(\.rowMenu) private var actions

    var body: some View {
        Button("Show Diff", action: showDiff)
        // A path that is not valid UTF-8 cannot be named in git's pathspec losslessly (#70).
        Button("Show History") { actions.showHistory(worktree, path) }
            .disabled(!path.isRepresentable)
        Divider()
        Button("Copy Path") { actions.copy(path.display) }
        Button("Copy Full Path") { if let full = actions.fullPath(worktree, path) { actions.copy(full) } }
            .disabled(actions.fullPath(worktree, path) == nil)
        Button("Reveal in Finder") { actions.revealFile(worktree, path) }
            // A path that is not valid UTF-8 has no file-level actions (GitPath).
            .disabled(!path.isRepresentable)
        if let commit {
            let url = actions.gitHubFileURL(commit, path)
            Button("Open on GitHub") { if let url { actions.openInBrowser(url) } }
                .disabled(url == nil)
        }
    }
}
