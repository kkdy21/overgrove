import Foundation

/// One load of a repository's worktree summary: everything PB-1 needs (performance-budget.md §2, overview.md §3.2).
/// Produced by `RepositoryService`; the shell reads it through `snapshot(focusing:)` (#65 builds the list from
/// `entries`).
struct RepositoryOverview: Sendable, Equatable {
    struct Entry: Sendable, Equatable {
        let worktree: Worktree
        let status: Status
    }

    enum Status: Sendable, Equatable {
        case loaded(WorkingState)
        /// This worktree's status failed; the other worktrees are unaffected.
        case failed(GitError)
        case notQueried(Reason)
    }

    enum Reason: Sendable, Equatable {
        /// The worktree's folder is gone (`prunable`): it is listed, never queried (INT-14).
        case prunable
        /// A bare main repository has no working tree.
        case bare
        /// The path is not valid UTF-8, so it cannot be passed to git (parsing-spec.md §1.3).
        case unrepresentablePath
        /// The listed path belongs to another repository. `worktree list` reads paths from files the repository
        /// controls, so a forged entry could point at a repository whose configuration was never inspected.
        case foreignRepository
        /// This worktree's own configuration (e.g. `config.worktree`) blocks queries (ADR-0009, fail closed).
        case inspectionBlocked(String)
    }

    /// In `worktree list` order: the main worktree first.
    let entries: [Entry]
    /// `worktree list` output was cut at the size limit; the last record was dropped (parsing-spec.md §1.5).
    let isWorktreeListPartial: Bool
    let refs: RefParser.Listing
    let stashes: StashParser.Listing
    /// The repository's own configuration inspection (main worktree): security report, remotes, fetch blocking.
    let inspection: RepoConfigInspection

    /// What the toolbar and status bar show (`AppState.snapshot`). The focused worktree is the one at `path`, or the
    /// main worktree when `path` is `nil` or not listed.
    func snapshot(focusing path: GitPath?) -> RepositorySnapshot {
        let focused =
            entries.first { $0.worktree.path == path } ?? entries.first { $0.worktree.isMain } ?? entries.first
        return RepositorySnapshot(
            focusedWorktree: focused.map(Self.focusedWorktree),
            worktreeCount: entries.count,
            prunableCount: entries.filter { $0.worktree.isPrunable }.count
        )
    }

    private static func focusedWorktree(_ entry: Entry) -> FocusedWorktree {
        guard case .loaded(let state) = entry.status else {
            // Without a status, show what the worktree list knows.
            return FocusedWorktree(
                branch: entry.worktree.branchShortName, headShortSHA: entry.worktree.head?.short, ahead: 0, behind: 0,
                hasUpstream: false)
        }
        let branch: String?
        switch state.head {
        case .branch(let name): branch = name
        case .detached: branch = nil
        }
        let hasUpstream: Bool
        if case .tracking = state.upstream { hasUpstream = true } else { hasUpstream = false }
        return FocusedWorktree(
            branch: branch,
            headShortSHA: (state.headCommit ?? entry.worktree.head)?.short,
            ahead: state.upstream.ahead,
            behind: state.upstream.behind,
            hasUpstream: hasUpstream
        )
    }
}
