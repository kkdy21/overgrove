import Foundation
import Observation

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

/// Fetch state for the status bar (interaction.md §4.2). Driven by the fetch feature (#77).
enum FetchStatus: Equatable, Sendable {
    case never
    case idle(lastFetched: Date)
    case fetching(remotes: [String], since: Date, lastFetched: Date?)
    case failed(lastFetched: Date?)
}

/// The state of one main window, which later screens plug into (#64, docs/README.md §2.2 `App/`). Each window
/// owns one (`MainWindowScene`), so windows show different repositories independently.
///
/// It owns the open repository and its per-repository panel layout. Data slots (`snapshot`, `fetchStatus`,
/// `ghStatus`, `searchText`) are set by the features that produce them; the shell only displays them and shows empty
/// states until they arrive. Nothing here can write to a repository (ADR-0011).
@MainActor
@Observable
final class AppState {
    private let layoutStore: PanelLayoutStore

    private(set) var repository: RepositoryContext?
    /// TODO(#65): set by the worktree list and status loaders.
    var snapshot: RepositorySnapshot?
    /// TODO(#77): set by the fetch feature.
    var fetchStatus: FetchStatus = .never
    /// TODO(#83): set from `GHClient.authStatus()`; `nil` until checked.
    var ghStatus: GHAuthStatus?
    /// TODO(#74): drives graph search.
    var searchText = ""
    /// The panel layout, written when a change finishes (drag frames stay inside `PanelSplitView`); saved per
    /// repository by `commitPanelLayout`.
    var panelLayout: PanelLayout = .default

    init(layoutStore: PanelLayoutStore = PanelLayoutStore()) {
        self.layoutStore = layoutStore
    }

    /// Opens `context` in the main window: restores its panel layout and clears the previous repository's data.
    /// TODO(#84): called by repository registration and the repository switcher.
    func open(_ context: RepositoryContext) {
        repository = context
        panelLayout = layoutStore.layout(for: context.repository.id)
        snapshot = nil
        fetchStatus = .never
        searchText = ""
    }

    /// A finished layout change (drag released, toggle, keyboard step). Saved for the open repository; without one
    /// it stays in memory only.
    func commitPanelLayout(_ layout: PanelLayout) {
        panelLayout = layout
        if let repository {
            layoutStore.save(layout, for: repository.repository.id)
        }
    }

    /// The toolbar's sidebar button and the View menu.
    func togglePanel(_ side: PanelLayout.Side) {
        commitPanelLayout(panelLayout.toggling(side))
    }
}
