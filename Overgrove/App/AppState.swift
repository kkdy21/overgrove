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
    case loaded(WorktreeListing)
    case failed(message: String)
}

/// The detail panel's subject (interaction.md §1). #65 selects worktrees; commits, stashes, and issues come with
/// their screens.
enum MainSelection: Equatable {
    /// The worktree's uncommitted changes (S-02, #66).
    case wip(GitPath)
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
    private let registry: RepositoryRegistry
    private let registrar: RepositoryRegistrar
    private let loader: any RepositoryLoading

    private(set) var repository: RepositoryContext?
    /// The toolbar chip and status bar fields, derived from the worktree list and the focused worktree.
    var snapshot: RepositorySnapshot?
    /// The open repository's worktrees and their status.
    private(set) var worktreeList: WorktreeListStatus = .idle
    /// The focused worktree (information-architecture.md §2.2). `nil` focuses the main worktree.
    private(set) var focusedWorktreePath: GitPath?
    private(set) var selection: MainSelection?
    /// The file picked in the detail panel; the diff viewer (S-10, #69) shows it. Cleared when the focus moves.
    private(set) var selectedFile: FileSelection?
    /// The load in flight; tests await it.
    private(set) var loadTask: Task<Void, Never>?
    /// Bumped on every open and close, so a load that finishes after the user moved on is dropped.
    private var loadGeneration = 0
    /// TODO(#77): set by the fetch feature.
    var fetchStatus: FetchStatus = .never
    /// TODO(#83): set from `GHClient.authStatus()`; `nil` until checked.
    var ghStatus: GHAuthStatus?
    /// TODO(#74): drives graph search.
    var searchText = ""
    /// The panel layout, written when a change finishes (drag frames stay inside `PanelSplitView`); saved per
    /// repository by `commitPanelLayout`.
    var panelLayout: PanelLayout = .default
    /// Shown as the window's alert; cleared when dismissed.
    var alert: AppAlert?
    /// True while a picked folder is being checked.
    private(set) var isAddingRepository = false

    /// - Parameters:
    ///   - layoutStore: Shared by every window; remembers each repository's panel layout.
    ///   - registry: Shared by every window; the registered repositories.
    ///   - registrar: Checks a picked folder (`.live` probes it through `GitClient`).
    ///   - loader: Inspects an opened repository and loads its worktrees.
    init(
        layoutStore: PanelLayoutStore, registry: RepositoryRegistry, registrar: RepositoryRegistrar = .live,
        loader: any RepositoryLoading = LiveRepositoryLoader.live
    ) {
        self.layoutStore = layoutStore
        self.registry = registry
        self.registrar = registrar
        self.loader = loader
    }

    /// The registered repositories, in the order they were added.
    var registeredRepositories: [RegisteredRepository] { registry.repositories }

    /// Opens `context` in the main window: restores its panel layout and clears the previous repository's data.
    func open(_ context: RepositoryContext) {
        repository = context
        panelLayout = layoutStore.layout(for: context.repository.id)
        clearRepositoryData()
    }

    private func clearRepositoryData() {
        loadTask?.cancel()
        loadTask = nil
        loadGeneration += 1
        snapshot = nil
        worktreeList = .idle
        focusedWorktreePath = nil
        selection = nil
        selectedFile = nil
        fetchStatus = .never
        searchText = ""
    }

    // MARK: Worktrees (#65)

    /// Inspects the open repository and loads its worktrees (overview.md §3.2). A newer open, close, or reload
    /// cancels this one, and its result is dropped.
    func reload() {
        guard let repository else { return }
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        if case .loaded = worktreeList {} else { worktreeList = .loading }
        let loader = loader
        let target = repository.repository
        loadTask = Task { [weak self] in
            let result: Result<WorktreeListing, RepositoryLoadError>
            do throws(RepositoryLoadError) {
                result = .success(try await loader.load(target))
            } catch {
                result = .failure(error)
            }
            self?.finishLoad(result, generation: generation)
        }
    }

    private func finishLoad(_ result: Result<WorktreeListing, RepositoryLoadError>, generation: Int) {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        switch result {
        case .success(let listing):
            worktreeList = .loaded(listing)
            focusedWorktreePath = WorktreeListModel.focusedPath(in: listing, requested: focusedWorktreePath)
            if case .wip(let path) = selection, path != focusedWorktreePath { selection = nil }
            selection = selection ?? focusedWorktreePath.map(MainSelection.wip)
            snapshot = WorktreeListModel.snapshot(listing: listing, focused: focusedWorktreePath)
            // Keep the picked file only while it is still listed in the same group.
            if let file = selectedFile, wipDetailModel?.row(for: file) == nil { selectedFile = nil }
        case .failure(.git(.cancelled)):
            break
        case .failure(let error):
            // The message can carry masked stderr, which still keeps separators such as U+2028.
            worktreeList = .failed(message: PathValidator.displayable(error.message))
            snapshot = nil
        }
    }

    /// The sidebar row model, `nil` until the list has loaded.
    var worktreeListModel: WorktreeListModel? {
        guard case .loaded(let listing) = worktreeList else { return nil }
        return WorktreeListModel(listing: listing, focused: focusedWorktreePath)
    }

    #if DEBUG
        /// Shows `listing` as if it had just loaded (previews and render tests; no git).
        func showForPreview(_ listing: WorktreeListing) {
            finishLoad(.success(listing), generation: loadGeneration)
        }
    #endif

    /// Selecting a worktree row focuses that worktree and shows its changes (interaction.md §1.3).
    func selectWorktree(_ path: GitPath) {
        guard case .loaded(let listing) = worktreeList, listing.entries.contains(where: { $0.worktree.path == path })
        else { return }
        if focusedWorktreePath != path { selectedFile = nil }
        focusedWorktreePath = path
        selection = .wip(path)
        snapshot = WorktreeListModel.snapshot(listing: listing, focused: path)
    }

    // MARK: WIP detail (#66)

    /// S-02 for the selected worktree, `nil` unless a loaded worktree's WIP is selected.
    var wipDetailModel: WipDetailModel? {
        guard case .wip(let path) = selection, case .loaded(let listing) = worktreeList,
            let entry = listing.entries.first(where: { $0.worktree.path == path })
        else { return nil }
        return WipDetailModel(entry: entry)
    }

    /// Picks a file in the WIP detail. Paths git cannot take back (not UTF-8) are not selectable.
    func selectFile(_ file: FileSelection) {
        guard let row = wipDetailModel?.row(for: file), row.isSelectable else { return }
        selectedFile = file
    }

    /// Back to the graph (`⎋`, interaction.md §3).
    func clearSelectedFile() {
        selectedFile = nil
    }

    /// A finished layout change (drag released, toggle, keyboard step). Saved for the open repository; without one
    /// it stays in memory only.
    func commitPanelLayout(_ layout: PanelLayout) {
        panelLayout = layout
        if let repository {
            layoutStore.save(layout, for: repository.repository.id)
        }
    }

    // MARK: Registration (#84)

    /// Registers a folder picked in `NSOpenPanel` and opens it. A worktree of a repository that is already registered
    /// opens that repository instead of adding it twice.
    func addRepository(at folder: URL) async {
        guard !isAddingRepository else { return }
        isAddingRepository = true
        defer { isAddingRepository = false }
        do {
            let registration = try await registrar.register(folder)
            switch registry.add(registration.entry) {
            case .added:
                openRegistered(registration.entry.id)
                if let notice = registration.notice {
                    alert = AppAlert(title: "Repository Added", message: notice)
                }
            case .alreadyRegistered:
                guard let existing = registry.repository(withID: registration.entry.id) else { return }
                openRegistered(existing.id)
                alert = AppAlert(
                    title: "Repository Already Added",
                    message: "“\(existing.name)” is already in Overgrove, at \(existing.displayRootPath).")
            case .rejected:
                // The registrar's checks make this unreachable; refuse rather than store a malformed path.
                alert = AppAlert(
                    title: "Couldn’t Add Repository",
                    message: RegistrationError.invalidPath(.controlCharacters).message)
            }
        } catch {
            if error != .git(.cancelled) {
                alert = AppAlert(title: "Couldn’t Add Repository", message: error.message)
            }
        }
    }

    /// Opens a registered repository. Its folder must still be where it was registered, not replaced by a symbolic
    /// link to somewhere else (T14); otherwise it stays closed and the alert says so.
    ///
    /// This is defense in depth only; it runs no git. The repository can still change before git runs, so the
    /// data loaders (#65) inspect it with `RepoConfigInspector` every time it is opened.
    /// - Parameter quietly: No alert for a missing folder (restoring at launch).
    func openRegistered(_ id: RegisteredRepository.ID, quietly: Bool = false) {
        guard let entry = registry.repository(withID: id) else { return }
        let root = URL(fileURLWithPath: entry.rootPath, isDirectory: true)
        guard let checked = try? PathValidator.checkRegistration(root), checked.resolved.path == entry.rootPath else {
            if !quietly {
                alert = AppAlert(
                    title: "Repository Not Found",
                    message:
                        "The folder of “\(entry.name)” is missing or was replaced (\(entry.displayRootPath)). Restore "
                        + "it, or remove the repository from Overgrove.")
            }
            return
        }
        // The owner needs GitHub remote detection, which is not built yet; the switcher shows the name alone.
        open(RepositoryContext(repository: entry.repository, owner: nil))
        registry.lastSelected = id
        reload()
    }

    /// Opens the repository shown last, once, when the window has none.
    func restoreLastSelected() {
        guard repository == nil, let id = registry.lastSelected else { return }
        openRegistered(id, quietly: true)
    }

    /// Removes a repository from Overgrove; its folder is not touched. Closes it if this window shows it.
    func removeRepository(_ id: RegisteredRepository.ID) {
        registry.remove(id)
        if repository?.repository.id == id { close() }
    }

    private func close() {
        repository = nil
        panelLayout = .default
        clearRepositoryData()
    }

    /// The toolbar's sidebar button and the View menu.
    func togglePanel(_ side: PanelLayout.Side) {
        commitPanelLayout(panelLayout.toggling(side))
    }
}
