import Foundation

/// A worktree compared with its base branch from where they split, like a pull request's "Files changed" (#157,
/// git-command-catalog.md §3). Produced by `RepositoryService.compare(_:worktree:base:includeWorkingTree:)`.
///
/// Paths, ref names and commit text come from the repository: screens show them through
/// `PathValidator.displayable` (T14).
struct WorktreeComparison: Sendable, Equatable {
    /// Commits listed per comparison (`commitsAhead`). More are reported by `isCommitListPartial`.
    static let commitLimit = 500

    let base: FullRefName
    /// The base branch's tip when compared (part of the cache key).
    let baseTip: ObjectID
    /// HEAD when compared; `nil` for an unborn branch.
    let head: ObjectID?
    let includesWorkingTree: Bool
    /// Files changed since the merge-base: committed changes, plus uncommitted tracked changes with
    /// `includesWorkingTree`.
    let files: [FileStat]
    /// The file list was cut at the output limit.
    let isFileListPartial: Bool
    /// Untracked files from the worktree's last `status` (git diff does not list them). Empty unless
    /// `includesWorkingTree`.
    let untracked: [GitPath]
    /// Commits on HEAD that the base does not have, newest first, at most `commitLimit`.
    let commits: [CommitNode]
    let isCommitListPartial: Bool
    /// Ahead/behind against the base when HEAD is on a branch; `nil` when detached.
    let counts: RevListParser.Counts?

    /// The base to compare with when the user has not picked one: the target of `refs/remotes/origin/HEAD`, else
    /// `refs/heads/main`, else `refs/heads/master`. Only branches that exist in `refs` and point to a commit count
    /// (#559).
    static func defaultBase(in refs: RefParser.Listing) -> FullRefName? {
        let names = Set(refs.branches.filter { $0.commit != nil }.map(\.fullName))
        if let target = refs.branches.first(where: { $0.fullName == "refs/remotes/origin/HEAD" })?.symbolicTarget,
            names.contains(target), let base = FullRefName(target)
        {
            return base
        }
        for candidate in ["refs/heads/main", "refs/heads/master"] where names.contains(candidate) {
            return FullRefName(candidate)
        }
        return nil
    }
}

/// One file's patch in a comparison (`comparePatch`), as git printed it. Untracked files use `untrackedPreview`.
struct ComparisonPatch: Sendable, Equatable {
    let patch: Data
    let isTruncated: Bool
}

/// Why a comparison could not be made.
enum ComparisonError: Error, Sendable, Equatable {
    /// The worktree has no loaded status (missing, blocked, not part of the repository, …). Screens offer the
    /// comparison only for loaded worktrees.
    case worktreeNotQueried
    /// No base was given and none of the default candidates exists.
    case noBaseBranch
    /// The chosen base branch is not among the repository's branches.
    case baseNotFound(FullRefName)
    case git(GitError)

    var message: String {
        switch self {
        case .worktreeNotQueried:
            String(localized: "This worktree's status is not available, so it cannot be compared.")
        case .noBaseBranch:
            String(localized: "No base branch was found (origin/HEAD, main, or master). Choose one to compare with.")
        case .baseNotFound(let base):
            String(localized: "The base branch \(PathValidator.displayable(base.value)) no longer exists.")
        case .git(let error):
            error.message
        }
    }
}
