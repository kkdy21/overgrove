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
    /// The worktree's uncommitted changes (S-02, #66): the `Changes` segment.
    case wip(GitPath)
    /// The worktree's facts and safety (S-05, #67): the `Worktree` segment.
    case worktreeInfo(GitPath)

    /// The worktree either segment shows.
    var worktreePath: GitPath {
        switch self {
        case .wip(let path), .worktreeInfo(let path): path
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
    private let lineCountLoader: (any LineCountLoading)?
    private let inspector: any WorktreeInspecting
    private let diffLoader: any DiffLoading
    private let comparisonLoader: any ComparisonLoading
    /// S-11 (#158): the open comparison, `nil` when the center shows the graph or a WIP diff.
    private(set) var comparison: ComparisonSession?
    /// The comparison (and its patch) in flight; tests await them.
    private(set) var comparisonTask: Task<Void, Never>?
    private(set) var comparisonPatchTask: Task<Void, Never>?
    private var comparisonGeneration = 0
    /// The base the user picked per worktree, for the session (screens.md S-11: remembered per worktree).
    private var comparisonBases: [GitPath: FullRefName] = [:]

    private(set) var repository: RepositoryContext?
    /// The toolbar chip and status bar fields, derived from the worktree list and the focused worktree.
    var snapshot: RepositorySnapshot?
    /// The open repository's worktrees and their status.
    private(set) var worktreeList: WorktreeListStatus = .idle
    /// The focused worktree (information-architecture.md §2.2). `nil` focuses the main worktree.
    private(set) var focusedWorktreePath: GitPath?
    private(set) var selection: MainSelection?
    /// The file picked in the detail panel; the diff viewer (S-10, #232) shows it. Cleared when the focus moves.
    /// Every change starts (or, for `nil`, cancels) loading its diff.
    private(set) var selectedFile: FileSelection? {
        didSet {
            if selectedFile != oldValue { loadDiff() }
        }
    }
    /// The selected file's diff, `nil` without a selected file.
    private(set) var diffState: DiffLoadState?
    /// The diff load in flight; tests await it.
    private(set) var diffTask: Task<Void, Never>?
    private var diffGeneration = 0
    /// S-05 inspections by worktree, read when the `Worktree` segment opens; cleared on every reload.
    private(set) var worktreeInspections: [GitPath: WorktreeInspection] = [:]
    /// The S-05 inspection in flight; tests await it.
    private(set) var inspectionTask: Task<Void, Never>?
    /// The load in flight; tests await it.
    private(set) var loadTask: Task<Void, Never>?
    /// What the load in flight was started for; `nil` when none runs.
    private var runningTrigger: RepositoryService.Trigger?
    /// Dropping a removed repository's cache; tests await it.
    private(set) var forgetTask: Task<Void, Never>?
    /// The selected worktree's line counts (#230), for the status they were requested with.
    private var lineCounts: LineCountRequest?
    /// The line count query in flight; tests await it.
    private(set) var lineCountTask: Task<Void, Never>?
    /// Bumped on every open and close, so a load that finishes after the user moved on is dropped.
    private var loadGeneration = 0
    /// Whether this open has shown a service-verified result, not only the cached paint (security review of #243).
    private var hasVerifiedListing = false
    /// `.user` retries after superseded loads, and whether they ran out (the next activation loads everything).
    private var supersededRetries = 0
    private var needsFullLoad = false
    /// Bumped when S-05 inspections are dropped; unlike `loadGeneration`, background refreshes keep it.
    private var inspectionGeneration = 0
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
    ///   - inspector: Reads one worktree's configuration for S-05.
    ///   - diffLoader: Loads a picked file's patch for S-10.
    ///   - comparisonLoader: Compares a worktree with its base branch for S-11.
    ///   - lineCountLoader: Queries the WIP detail's line counts for the selected worktree. Defaults to `loader` when
    ///     it can (the live loader can); without one, the detail shows no line counts.
    init(
        layoutStore: PanelLayoutStore, registry: RepositoryRegistry, registrar: RepositoryRegistrar = .live,
        loader: any RepositoryLoading = LiveRepositoryLoader.live,
        inspector: any WorktreeInspecting = LiveWorktreeInspector.live,
        diffLoader: any DiffLoading = LiveDiffLoader.live,
        comparisonLoader: any ComparisonLoading = LiveComparisonLoader.live,
        lineCountLoader: (any LineCountLoading)? = nil
    ) {
        self.layoutStore = layoutStore
        self.registry = registry
        self.registrar = registrar
        self.loader = loader
        self.inspector = inspector
        self.diffLoader = diffLoader
        self.comparisonLoader = comparisonLoader
        self.lineCountLoader = lineCountLoader ?? (loader as? any LineCountLoading)
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
        runningTrigger = nil
        loadGeneration += 1
        hasVerifiedListing = false
        supersededRetries = 0
        needsFullLoad = false
        snapshot = nil
        worktreeList = .idle
        focusedWorktreePath = nil
        selection = nil
        selectedFile = nil
        closeComparison()
        comparisonBases = [:]
        lineCountTask?.cancel()
        lineCountTask = nil
        lineCounts = nil
        inspectionTask?.cancel()
        inspectionTask = nil
        worktreeInspections = [:]
        inspectionGeneration += 1
        fetchStatus = .never
        searchText = ""
    }

    // MARK: Worktrees (#65)

    /// Inspects the open repository and loads everything again (`.user`: opening a repository, ⌘R; overview.md §3.2).
    /// When the repository is not shown yet, its cached listing (no git) is painted first (PB-2). A newer request
    /// cancels this one, and its result is dropped.
    func reload() {
        refresh(.user)
    }

    /// The window became key (interaction.md §4): `.automatic` (debounced), once loaded and while no load runs.
    func windowDidBecomeActive() {
        guard repository != nil, runningTrigger == nil else { return }
        // The first load was superseded every time (another window): load everything.
        if needsFullLoad { return refresh(.user) }
        guard hasVerifiedListing, case .loaded = worktreeList else { return }
        refresh(.automatic)
    }

    /// Superseded first loads retried before falling back to Loading.
    static let maximumSupersededRetries = 2

    /// Starts a refresh for `trigger` (overview.md §5 decides what it re-queries). A full refresh in flight is not
    /// replaced by a narrower one: it already brings everything.
    private func refresh(_ trigger: RepositoryService.Trigger) {
        guard let repository else { return }
        if trigger != .user, runningTrigger == .user { return }
        loadTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        runningTrigger = trigger
        let isShown: Bool = if case .loaded = worktreeList { true } else { false }
        if !isShown { worktreeList = .loading }
        let loader = loader
        let target = repository.repository
        loadTask = Task { [weak self] in
            if !isShown, let cached = await loader.cachedListing(target) {
                self?.showCached(cached, generation: generation)
            }
            let result: Result<WorktreeListing?, RepositoryLoadError>
            do throws(RepositoryLoadError) {
                result = .success(try await loader.load(target, trigger: trigger))
            } catch {
                result = .failure(error)
            }
            self?.finishLoad(result, generation: generation)
        }
    }

    /// Paints a cached listing while the refresh that follows it runs.
    private func showCached(_ listing: WorktreeListing, generation: Int) {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        if case .loaded = worktreeList { return }
        apply(listing)
    }

    private func finishLoad(_ result: Result<WorktreeListing?, RepositoryLoadError>, generation: Int) {
        guard generation == loadGeneration, !Task.isCancelled else { return }
        runningTrigger = nil
        switch result {
        case .success(let listing?):
            hasVerifiedListing = true
            supersededRetries = 0
            needsFullLoad = false
            apply(listing)
        case .success(nil), .failure(.git(.cancelled)):
            // Superseded (another window asked for the same repository) or debounced away. A verified listing stays;
            // a cached paint is not kept as if it were current (security review of #243).
            guard !hasVerifiedListing else { break }
            if supersededRetries < Self.maximumSupersededRetries {
                supersededRetries += 1
                refresh(.user)
            } else {
                worktreeList = .loading
                snapshot = nil
                needsFullLoad = true
            }
        case .failure(let error):
            // The message can carry masked stderr, which still keeps separators such as U+2028.
            worktreeList = .failed(message: PathValidator.displayable(error.message))
            snapshot = nil
        }
    }

    private func apply(_ listing: WorktreeListing) {
        worktreeList = .loaded(listing)
        focusedWorktreePath = WorktreeListModel.focusedPath(in: listing, requested: focusedWorktreePath)
        if let path = selection?.worktreePath, path != focusedWorktreePath { selection = nil }
        selection = selection ?? focusedWorktreePath.map(MainSelection.wip)
        // Configuration may have changed since the last inspection.
        worktreeInspections = [:]
        inspectionGeneration += 1
        if case .worktreeInfo = selection { inspectSelectedWorktree() }
        snapshot = WorktreeListModel.snapshot(listing: listing, focused: focusedWorktreePath)
        // Keep the picked file only while it is still listed in the same group.
        // Same rule as `selectFile`: the row must still exist and still be selectable.
        if let file = selectedFile, wipDetailModel?.row(for: file)?.isSelectable != true {
            selectedFile = nil
        } else if selectedFile != nil {
            // Same file, new content: load its diff again.
            loadDiff()
        }
        // The load may have re-queried the status even if it reads the same (an edit inside a modified file).
        requestLineCounts(refresh: true)
    }

    /// The sidebar row model, `nil` until the list has loaded.
    var worktreeListModel: WorktreeListModel? {
        guard case .loaded(let listing) = worktreeList else { return nil }
        return WorktreeListModel(listing: listing, focused: focusedWorktreePath)
    }

    #if DEBUG
        /// Shows `listing` as if it had just loaded (previews and render tests; no git).
        func showForPreview(_ listing: WorktreeListing) {
            hasVerifiedListing = true
            apply(listing)
        }
    #endif

    /// Selecting a worktree row focuses that worktree and shows its changes (interaction.md §1.3). What is shown
    /// comes from the listing in memory (the service's cached overview) at once (PB-2); that worktree's status is
    /// then refreshed in the background (`.worktreeSelected`, overview.md §5).
    func selectWorktree(_ path: GitPath) {
        guard case .loaded(let listing) = worktreeList, listing.entries.contains(where: { $0.worktree.path == path })
        else { return }
        if focusedWorktreePath != path {
            selectedFile = nil
            // S-11 belongs to one worktree.
            if comparison?.worktree != path { closeComparison() }
        }
        focusedWorktreePath = path
        snapshot = WorktreeListModel.snapshot(listing: listing, focused: path)
        // The segment the user chose stays when they move to another worktree; `Changes` is the default.
        if case .worktreeInfo = selection {
            selection = .worktreeInfo(path)
            inspectSelectedWorktree()
        } else {
            selection = .wip(path)
            requestLineCounts()
        }
        refresh(.worktreeSelected(path))
    }

    // MARK: Worktree detail (#67)

    /// The `Changes | Worktree` segment.
    func showChanges() {
        guard let path = selection?.worktreePath else { return }
        selection = .wip(path)
        requestLineCounts()
    }

    func showWorktreeDetail() {
        guard let path = selection?.worktreePath else { return }
        selection = .worktreeInfo(path)
        inspectSelectedWorktree()
    }

    /// S-05 for the selected worktree, `nil` unless its `Worktree` segment is shown.
    var worktreeDetailModel: WorktreeDetailModel? {
        guard case .worktreeInfo(let path) = selection, let entry = entry(at: path) else { return nil }
        return WorktreeDetailModel(
            entry: entry, inspection: worktreeInspections[path], fetchStatus: fetchStatus, now: Date())
    }

    private func entry(at path: GitPath) -> WorktreeListing.Entry? {
        guard case .loaded(let listing) = worktreeList else { return nil }
        return listing.entries.first { $0.worktree.path == path }
    }

    /// Reads the shown worktree's configuration once per load, only for worktrees `RepositoryService` verified.
    private func inspectSelectedWorktree() {
        guard case .worktreeInfo(let path) = selection, worktreeInspections[path] == nil,
            let entry = entry(at: path), WorktreeDetailModel.shouldInspect(entry), let repository
        else { return }
        let generation = inspectionGeneration
        let inspector = inspector
        let target = repository.repository
        inspectionTask?.cancel()
        inspectionTask = Task { [weak self] in
            let result = await inspector.inspect(entry, of: target)
            guard let self, generation == self.inspectionGeneration, !Task.isCancelled else { return }
            self.worktreeInspections[path] = result
        }
    }

    // MARK: WIP detail (#66)

    /// S-02 for the selected worktree, `nil` unless a loaded worktree's WIP is selected.
    var wipDetailModel: WipDetailModel? {
        guard let entry = selectedWipEntry else { return nil }
        let counts: WipDetailModel.LineCounts
        if let lineCounts, case .loaded(let state) = entry.state, lineCounts.matches(entry.worktree.path, state) {
            counts = lineCounts.result
        } else {
            counts = .pending
        }
        return WipDetailModel(entry: entry, lineCounts: counts)
    }

    private var selectedWipEntry: WorktreeListing.Entry? {
        guard case .wip(let path) = selection, case .loaded(let listing) = worktreeList else { return nil }
        return listing.entries.first { $0.worktree.path == path }
    }

    /// Line counts requested for one worktree's status, and what came back.
    private struct LineCountRequest {
        let path: GitPath
        let state: WorkingState
        var result: WipDetailModel.LineCounts

        func matches(_ path: GitPath, _ state: WorkingState) -> Bool { self.path == path && self.state == state }
    }

    /// Queries the selected worktree's line counts unless the shown status already has them (#230). Only the
    /// selected worktree is queried, and only once its status has loaded; the service answers from its cache until
    /// that status is queried again.
    /// - Parameter refresh: Ask even when the status reads the same: after a load, the service knows whether it
    ///   re-queried that status (and runs no git if not). The current counts stay shown until the answer.
    private func requestLineCounts(refresh: Bool = false) {
        guard let lineCountLoader, let repository, let entry = selectedWipEntry, case .loaded(let state) = entry.state
        else { return }
        let path = entry.worktree.path
        let isSameStatus = lineCounts?.matches(path, state) ?? false
        if isSameStatus && !refresh { return }
        lineCountTask?.cancel()
        if !isSameStatus { lineCounts = LineCountRequest(path: path, state: state, result: .pending) }
        guard !state.staged.isEmpty || !state.unstaged.isEmpty else {
            lineCounts = LineCountRequest(
                path: path, state: state,
                result: .loaded(WorkingLineCounts(staged: [], unstaged: [], isPartial: false)))
            return
        }
        let loader = lineCountLoader
        let target = repository.repository
        lineCountTask = Task { [weak self] in
            let result: WipDetailModel.LineCounts
            do throws(RepositoryLoadError) {
                // `nil`: the service has no loaded status for it (e.g. evicted); show no counts rather than an error.
                guard let counts = try await loader.lineCounts(target, worktree: path) else { return }
                result = .loaded(counts)
            } catch {
                if error == .git(.cancelled) { return }
                result = .failed
            }
            self?.finishLineCounts(result, path: path, state: state)
        }
    }

    private func finishLineCounts(_ result: WipDetailModel.LineCounts, path: GitPath, state: WorkingState) {
        guard !Task.isCancelled, let lineCounts, lineCounts.matches(path, state) else { return }
        self.lineCounts?.result = result
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

    // MARK: Compare with base (#158)

    /// S-11's rows, `nil` without an open comparison.
    var comparisonModel: ComparisonModel? {
        guard let comparison else { return nil }
        let state: WorkingState? =
            if case .loaded(let state) = entry(at: comparison.worktree)?.state { state } else { nil }
        return ComparisonModel(session: comparison, workingState: state)
    }

    /// Whether `path` (default: the focused worktree) can be compared: its status loaded (#157 needs it).
    func canCompare(_ path: GitPath? = nil) -> Bool {
        guard let path = path ?? focusedWorktreePath, case .loaded = entry(at: path)?.state else { return false }
        return true
    }

    /// Opens S-11 for `path` (default: the focused worktree): `⌘⇧B`, the worktree row menu, S-05's button.
    func showComparison(of path: GitPath? = nil) {
        guard let path = path ?? focusedWorktreePath, canCompare(path) else { return }
        if focusedWorktreePath != path { selectWorktree(path) }
        selectedFile = nil
        comparison = ComparisonSession(worktree: path, base: comparisonBases[path])
        runComparison()
    }

    /// Back to the graph (`‹ Graph`, `⎋`).
    func closeComparison() {
        comparisonTask?.cancel()
        comparisonPatchTask?.cancel()
        comparisonTask = nil
        comparisonPatchTask = nil
        comparisonGeneration += 1
        comparison = nil
    }

    func chooseComparisonBase(_ base: FullRefName) {
        // Only a branch the repository listed (#157 checks again).
        guard let worktree = comparison?.worktree, comparison?.bases.contains(base) == true else { return }
        comparisonBases[worktree] = base
        comparison?.base = base
        runComparison()
    }

    func setIncludeUncommitted(_ include: Bool) {
        guard comparison != nil, comparison?.includeUncommitted != include else { return }
        comparison?.includeUncommitted = include
        runComparison()
    }

    func showAllComparisonFiles() {
        comparison?.showsAllFiles = true
    }

    private func runComparison() {
        guard let session = comparison, let repository else { return }
        comparisonTask?.cancel()
        comparisonPatchTask?.cancel()
        comparisonGeneration += 1
        let generation = comparisonGeneration
        comparison?.result = .loading
        comparison?.selectedFile = nil
        comparison?.patch = nil
        let loader = comparisonLoader
        let target = repository.repository
        comparisonTask = Task { [weak self] in
            let bases = await loader.bases(of: target)
            let base = session.base ?? bases.preferred
            let result: Result<WorktreeComparison, ComparisonError> =
                if let base {
                    await loader.compare(
                        target, worktree: session.worktree, base: base, includeUncommitted: session.includeUncommitted)
                } else {
                    .failure(.noBaseBranch)
                }
            guard let self, generation == self.comparisonGeneration, !Task.isCancelled else { return }
            self.comparison?.bases = bases.all
            switch result {
            case .success(let comparison):
                self.comparison?.base = comparison.base
                self.comparison?.result = .loaded(comparison)
            case .failure(let error):
                self.comparison?.base = base
                self.comparison?.result = .failed(error)
            }
        }
    }

    /// Picks a file in S-11: committed (and uncommitted) changes come from the comparison patch, untracked files from
    /// the same preview as S-02.
    func selectComparisonFile(_ file: ComparisonFile) {
        guard let session = comparison, case .loaded(let result) = session.result, let repository,
            // Untracked selections come only from the listed untracked files, and tracked ones from FILES CHANGED.
            let row = (file.isUntracked ? comparisonModel?.untracked : comparisonModel?.files)?
                .first(where: { $0.path == file.path }),
            row.isSelectable, let entry = entry(at: session.worktree)
        else { return }
        comparisonPatchTask?.cancel()
        comparison?.selectedFile = file
        comparison?.patch = .loading
        let generation = comparisonGeneration
        let loader = comparisonLoader
        let diffLoader = diffLoader
        let target = repository.repository
        let label =
            file.isUntracked
            ? "Untracked" : (row.hasUncommittedChanges ? "Committed + uncommitted" : "Committed")
        let source = DiffDocument.Source(label: label, kindLetter: row.kindLetter)
        comparisonPatchTask = Task { [weak self] in
            let loaded: DiffLoadResult
            if file.isUntracked {
                loaded = await diffLoader.load(
                    FileSelection(worktree: session.worktree, group: .untracked, path: file.path),
                    worktree: entry.worktree, of: target, isSubmodule: false)
            } else {
                loaded = await loader.patch(
                    target, worktree: session.worktree, base: result.base, file: file.path,
                    includeUncommitted: result.includesWorkingTree)
            }
            guard let self, generation == self.comparisonGeneration, !Task.isCancelled,
                self.comparison?.selectedFile == file
            else { return }
            switch loaded {
            case .patch(let patch):
                self.comparison?.patch = .loaded(DiffDocument(listing: patch, path: file.path, source: source))
            case .unavailable(let reason):
                self.comparison?.patch = .unavailable(reason)
            }
        }
    }

    // MARK: Diff viewer (#232)

    /// What the center area shows for the selected file: its title, `Staged · M`, and the load state.
    var diffViewer: (title: String, source: String, state: DiffLoadState)? {
        guard let file = selectedFile, let state = diffState else { return nil }
        let letter = wipDetailModel?.row(for: file)?.kindLetter
        let source = file.group.title + (letter.map { " · \($0)" } ?? "")
        let title: String
        if case .loaded(let document) = state {
            title = document.title
        } else {
            title = PathValidator.displayable(file.path.display)
        }
        return (title, source, state)
    }

    private func loadDiff() {
        diffTask?.cancel()
        diffGeneration += 1
        guard let file = selectedFile, case .loaded(let listing) = worktreeList,
            let entry = listing.entries.first(where: { $0.worktree.path == file.worktree }), let repository
        else {
            diffState = nil
            diffTask = nil
            return
        }
        let generation = diffGeneration
        let row = wipDetailModel?.row(for: file)
        // Fail closed: without its row the file cannot be shown to be an ordinary file.
        let isSubmodule = row?.isSubmodule ?? true
        let source = DiffDocument.Source(label: file.group.title, kindLetter: row?.kindLetter ?? "")
        let loader = diffLoader
        let target = repository.repository
        // A different file shows a spinner, not the previous file's diff under the new name; a reload of the same
        // file keeps the old diff on screen until the new one arrives.
        if case .loaded(let document) = diffState, document.title == PathValidator.displayable(file.path.display) {
        } else {
            diffState = .loading
        }
        diffTask = Task { [weak self] in
            let result = await loader.load(file, worktree: entry.worktree, of: target, isSubmodule: isSubmodule)
            guard let self, generation == self.diffGeneration, !Task.isCancelled else { return }
            switch result {
            case .patch(let patch):
                self.diffState = .loaded(DiffDocument(listing: patch, path: file.path, source: source))
            case .unavailable(let reason):
                self.diffState = .unavailable(reason)
            }
        }
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
        let location = URL(fileURLWithPath: entry.locationPath, isDirectory: true)
        guard let checked = try? PathValidator.checkRegistration(location), checked.resolved.path == entry.locationPath
        else {
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
        let removed = registry.repository(withID: id)?.repository
        registry.remove(id)
        if repository?.repository.id == id { close() }
        // Its cached results and inspections go too (`RepositoryService.forget`, overview.md §5).
        if let removed {
            let loader = loader
            forgetTask = Task { [weak self] in
                // Added again in the meantime: its new load must not be cancelled (security review of #243).
                guard self?.registry.repository(withID: id) == nil else { return }
                await loader.forget(removed)
            }
        }
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
