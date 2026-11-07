import Foundation

/// The repository open in the main window, with what the toolbar shows about it.
struct RepositoryContext: Equatable, Sendable {
    let repository: Repository
    /// Remote owner for the repository switcher (`api` + `acme`); `nil` without a recognized GitHub remote.
    let owner: String?

    /// Directory name, as the repository switcher shows it (screens.md S-01).
    var name: String { repository.displayName }
}

/// The focused worktree as the toolbar chip and status bar show it.
struct FocusedWorktree: Equatable, Sendable {
    /// Short branch name; `nil` when HEAD is detached.
    let branch: String?
    let headShortSHA: String?
    let ahead: Int
    let behind: Int
    let hasUpstream: Bool
    /// Its last status was slow (#168): the status bar says so.
    var slowStatus: SlowStatusHint?

    /// `feat/42-rate-limit`, or `detached @ b2e8a44` (screens.md S-01).
    var title: String {
        if let branch { return branch }
        return "detached @ \(headShortSHA ?? "unknown")"
    }

    /// `↑2` when the branch is ahead of its upstream; nothing otherwise.
    var aheadBadge: String? {
        hasUpstream && ahead > 0 ? "↑\(ahead)" : nil
    }

    var accessibilityLabel: String {
        var label = "Focused worktree \(title)"
        if aheadBadge != nil { label += ", \(ahead) ahead" }
        return label
    }
}

/// Repository data the shell displays. Filled by the data loaders (#65 worktree list and status); `nil` until then.
struct RepositorySnapshot: Equatable, Sendable {
    let focusedWorktree: FocusedWorktree?
    let worktreeCount: Int
    let prunableCount: Int
}

/// Fetch state for the status bar (interaction.md §4.2). Driven by `FetchController` (#77).
enum FetchStatus: Equatable, Sendable {
    case never
    /// The last fetch Overgrove ran succeeded at this time (`FetchRecord`).
    case idle(lastFetched: Date)
    /// Overgrove has no record; `FETCH_HEAD`'s modification time stands in, marked as an estimate (overview.md §8).
    case estimated(lastFetched: Date)
    /// `remotes` is empty until the remotes to fetch are known.
    case fetching(remotes: [String], since: Date, lastFetched: Date?)
    /// The last attempt failed; `lastFetched` is the last success, if any.
    case failed(lastFetched: Date?)
    /// The user stopped the fetch (interaction.md §4.2, `Fetch cancelled`).
    case cancelled(lastFetched: Date?)

    /// The last known successful (or estimated) fetch.
    var lastFetched: Date? {
        switch self {
        case .never: nil
        case .idle(let date), .estimated(let date): date
        case .fetching(_, _, let date), .failed(let date), .cancelled(let date): date
        }
    }

    var isFetching: Bool {
        if case .fetching = self { return true }
        return false
    }
}

/// A message for the window's alert: a refused folder, a missing one, or a note about what was registered.
struct AppAlert: Equatable, Identifiable {
    let id = UUID()
    let title: String
    let message: String

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.title == rhs.title && lhs.message == rhs.message }
}

/// What the sidebar's worktree list shows (#65).
enum WorktreeListStatus: Equatable {
    case idle
    case loading
    /// Drawn from the last session's `LaunchSnapshot` while the first load runs (ADR-0018 §5, #109): rows only, and
    /// nothing can be selected or opened until the load replaces it.
    case snapshot(WorktreeListModel)
    case loaded(WorktreeListing)
    case failed(message: String)

    var isSnapshot: Bool {
        if case .snapshot = self { true } else { false }
    }

    /// Waiting for the first load: nothing loaded, or only a launch snapshot.
    var isAwaitingLoad: Bool {
        switch self {
        case .loading, .snapshot: true
        case .idle, .loaded, .failed: false
        }
    }
}

/// The detail panel's subject (interaction.md §1). #65 selects worktrees; commits, stashes, and issues come with
/// their screens.
enum MainSelection: Equatable {
    /// The worktree's uncommitted changes (S-02, #66): the `Changes` segment.
    case wip(GitPath)
    /// The worktree's facts and safety (S-05, #67): the `Worktree` segment.
    case worktreeInfo(GitPath)
    /// A stash's contents (S-04, #71), by OID: `stash@{n}` shifts when stashes change.
    case stash(ObjectID)
    /// A commit picked in the graph (S-03, #69).
    case commit(ObjectID)
    /// An issue (S-06, #81), by number.
    case issue(Int)

    /// The worktree either segment shows; `nil` for a stash, a commit, or an issue.
    var worktreePath: GitPath? {
        switch self {
        case .wip(let path), .worktreeInfo(let path): path
        case .stash, .commit, .issue: nil
        }
    }
}

/// The groups of the WIP detail (S-02), in display order.
enum WorkingChangeGroup: String, CaseIterable, Sendable {
    case conflicted
    case staged
    case unstaged
    case untracked
}

/// A file picked in the detail panel: the secondary selection that drives the diff viewer (interaction.md §1,
/// S-10, #69). `group` tells a staged diff from an unstaged one for the same `MM` path.
struct FileSelection: Equatable, Sendable {
    let worktree: GitPath
    let group: WorkingChangeGroup
    let path: GitPath
    /// The old name when the file was renamed, so its diff pairs both names (#309).
    var originalPath: GitPath?
}
