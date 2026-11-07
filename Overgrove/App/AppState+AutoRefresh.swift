import Foundation

/// Auto refresh (#119): what the window's `AutoRefreshController` asks of it.
extension AppState {
    /// Re-queries what changed on disk. Refused (`false`) while another load runs; the controller retries when it
    /// ends, so a refresh the user asked for is never replaced by an automatic one.
    func requestAutoRefresh(_ change: FileChangeSet) -> Bool {
        guard repository != nil, runningTrigger == nil, hasVerifiedListing else { return false }
        refresh(.filesChanged(worktrees: change.worktrees, refs: change.refs, worktreeList: change.worktreeList))
        return true
    }

    /// The window became visible again: nothing was watched while it was hidden, so refresh once (`.automatic`
    /// re-queries the worktree list and every status older than `statusFreshness`).
    func refreshAfterReappearing() {
        guard repository != nil, runningTrigger == nil, hasVerifiedListing else { return }
        refresh(.automatic)
    }
}
