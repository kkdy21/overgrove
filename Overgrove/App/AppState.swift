import Foundation
import Observation

/// The state of one main window, which later screens plug into (#64, docs/README.md §2.2 `App/`). Each window
/// owns one (`MainWindowScene`), so windows show different repositories independently.
///
/// It owns the open repository and its per-repository panel layout. Data slots (`snapshot`, `fetchStatus`,
/// `ghStatus`, `searchText`) are set by the features that produce them; the shell only displays them and shows empty
/// states until they arrive. Nothing here can write to a repository (ADR-0011).
@MainActor
@Observable
final class AppState {
    let layoutStore: PanelLayoutStore
    let registry: RepositoryRegistry
    let registrar: RepositoryRegistrar
    let loader: any RepositoryLoading
    let lineCountLoader: (any LineCountLoading)?
    /// S-02's Submodules section for the selected worktree (#108).
    let submodules: SubmodulePanel
    let inspector: any WorktreeInspecting
    /// The last session's sidebar per repository (ADR-0018, #109); `nil` turns launch snapshots off (tests, previews).
    let launchSnapshots: LaunchSnapshotStore?
    /// The git executable and version the listings come from, for a snapshot's header. Read after a load, when git
    /// has been found already.
    let gitIdentity: @Sendable () async -> (executable: URL, version: GitVersion)?
    /// When each repository's snapshot was last written, and the write waiting for the 10-second spacing (ADR-0018 §3).
    @ObservationIgnored var launchSnapshotWrites: [String: Date] = [:]
    @ObservationIgnored var launchSnapshotTask: Task<Void, Never>?
    let diffLoader: any DiffLoading
    let stashLoader: any StashLoading
    let ghChecker: any GHAuthChecking
    /// The sidebar's ISSUES and S-06 (#81). gh problems stay inside it (ADR-0004 §4).
    let issuePanel: IssuePanelState
    /// The setup assistant (S-07, #85): git and GitHub CLI checks, first run and Help › Setup Assistant….
    let setup: SetupAssistantState
    /// App preferences shared by every window (S-08, #86).
    let settings: AppSettings
    /// S-04 (#71): the selected stash's files, and the file whose patch the center shows.
    var stashDetail: StashDetailState?
    var selectedStashFile: FileStat?
    var stashFileDiff: DiffLoadState?
    /// The stash loads in flight; tests await them.
    var stashTask: Task<Void, Never>?
    var stashFileTask: Task<Void, Never>?
    var stashGeneration = 0
    /// The stash whose files `stashDetail` holds.
    var loadedStashOID: ObjectID?
    let comparisonLoader: any ComparisonLoading
    /// The commit graph of the open repository (S-01 center, #68).
    let graph: GraphStore
    /// S-03 for the selected commit and the patch of a file picked in it (#69).
    let commitDetail: CommitDetailStore
    /// S-12's file list and patches (#388); the same loader S-03 uses.
    let commitLoader: any CommitLoading
    /// S-09 (#70): the open file history, which covers the graph until closed.
    let history: FileHistoryStore
    /// S-11 (#158): the open comparison, `nil` when the center shows the graph or a WIP diff.
    var comparison: ComparisonSession?
    /// The comparison (and its patch) in flight; tests await them.
    var comparisonTask: Task<Void, Never>?
    var comparisonPatchTask: Task<Void, Never>?
    var comparisonGeneration = 0
    /// The base the user picked per worktree, for the session (screens.md S-11: remembered per worktree).
    var comparisonBases: [GitPath: FullRefName] = [:]
    /// S-12 (#388): the open comparison of two commits, `nil` when the center shows something else.
    var commitComparison: CommitComparisonSession?
    /// Its file list and patch in flight; tests await them.
    var commitComparisonTask: Task<Void, Never>?
    var commitComparisonPatchTask: Task<Void, Never>?
    var commitComparisonGeneration = 0

    var repository: RepositoryContext?
    /// The toolbar chip and status bar fields, derived from the worktree list and the focused worktree.
    var snapshot: RepositorySnapshot?
    /// The open repository's worktrees and their status.
    var worktreeList: WorktreeListStatus = .idle
    /// The focused worktree (information-architecture.md §2.2). `nil` focuses the main worktree.
    var focusedWorktreePath: GitPath?
    /// The detail panel's subject. Each change the user makes is recorded for Back and Forward (#378).
    var selection: MainSelection? {
        didSet {
            guard let selection, selection != oldValue, !isMovingInSelectionHistory else { return }
            let entry = SelectionHistory.Entry(selection: selection, focus: focusedWorktreePath)
            if isSelectingAutomatically {
                selectionHistory.replaceCurrent(entry)
            } else {
                selectionHistory.record(entry)
            }
        }
    }
    /// Back and Forward over `selection` (`⌘[` / `⌘]`, interaction.md §1.4, #378). Cleared with the repository.
    var selectionHistory = SelectionHistory()
    /// Set while the app, not the user, picks the selection (a refresh's fallback): it replaces the current entry.
    @ObservationIgnored var isSelectingAutomatically = false
    /// Set while Back or Forward restores an entry, which must not be recorded again.
    @ObservationIgnored var isMovingInSelectionHistory = false
    /// The file picked in the detail panel; the diff viewer (S-10, #232) shows it. Cleared when the focus moves.
    /// Every change starts (or, for `nil`, cancels) loading its diff.
    var selectedFile: FileSelection? {
        didSet {
            if selectedFile != oldValue { loadDiff() }
        }
    }
    /// The selected file's diff, `nil` without a selected file.
    var diffState: DiffLoadState?
    /// The diff load in flight; tests await it.
    var diffTask: Task<Void, Never>?
    var diffGeneration = 0
    /// S-05 inspections by worktree, read when the `Worktree` segment opens; cleared on every reload.
    var worktreeInspections: [GitPath: WorktreeInspection] = [:]
    /// The S-05 inspection in flight; tests await it.
    var inspectionTask: Task<Void, Never>?
    /// The load in flight; tests await it.
    var loadTask: Task<Void, Never>?
    /// What the load in flight was started for; `nil` when none runs.
    var runningTrigger: RepositoryService.Trigger?
    /// Dropping a removed repository's cache; tests await it.
    var forgetTask: Task<Void, Never>?
    /// The selected worktree's line counts (#230), for the status they were requested with.
    var lineCounts: LineCountRequest?
    /// The line count query in flight; tests await it.
    var lineCountTask: Task<Void, Never>?
    /// Bumped on every open and close, so a load that finishes after the user moved on is dropped.
    var loadGeneration = 0
    /// Whether this open has shown a service-verified result, not only the cached paint (security review of #243).
    var hasVerifiedListing = false
    /// `.user` retries after superseded loads, and whether they ran out (the next activation loads everything).
    var supersededRetries = 0
    var needsFullLoad = false
    /// Bumped when S-05 inspections are dropped; unlike `loadGeneration`, background refreshes keep it.
    var inspectionGeneration = 0
    /// Fetch / Stop, the status bar's fetch field, and the last fetch of each repository (#77).
    let fetch: FetchController
    /// Auto refresh while the window is visible (#119).
    let autoRefresh: AutoRefreshController
    /// Auto fetch for this window (#79); off unless Settings turns it on.
    let autoFetch: AutoFetchScheduler
    /// The status bar's fetch field.
    var fetchStatus: FetchStatus { fetch.status }
    /// A local refresh is running: the status bar shows `Refreshing…` (interaction.md §4).
    var isRefreshing: Bool { runningTrigger != nil }
    /// The status bar's gh field (#83): checked whenever the issues load (a GitHub remote) and on Check Again; `nil`
    /// until checked or when the check failed.
    var ghStatus: GHAuthStatus?
    /// The gh check in flight; tests await it.
    var ghCheckTask: Task<Void, Never>?
    var ghCheckGeneration = 0
    /// A gh login check is running.
    var isCheckingGitHub = false
    /// The toolbar search (#74): dims graph rows that do not match; ⌘G/⌘⇧G step through matches.
    var searchText = ""
    /// The sidebar's Filter field (⌥⌘F, #74).
    var sidebarFilter = ""
    /// Bumped by Edit › Filter Sidebar (⌥⌘F); the field takes focus when it changes.
    var sidebarFilterFocusRequest = 0
    /// The last search over the loaded graph, reused until the query or the loaded pages change.
    @ObservationIgnored var searchCache: (key: SearchCacheKey, result: GraphSearchResult)?
    /// The graph's author filter chip (#255): rows by other authors are dimmed; with a search both must match.
    var authorFilter: GraphAuthorSelection = .all
    /// The author chips and the picked chip's commits over the loaded pages, reused until the pages change.
    @ObservationIgnored var authorSummaryCache: (key: GraphHistoryKey, summary: GraphAuthorSummary)?
    @ObservationIgnored var authorFilterCache: (key: GraphHistoryKey, result: GraphAuthorFilterResult)?
    /// `⌘1`–`⌘4` asked for a panel (interaction.md §1.2, #73); the panel's list takes keyboard focus when it changes.
    var panelFocusRequest: PanelFocusRequest?
    /// The pasteboard and Finder for row menus and copy commands (#73); tests put a recorder here.
    var rowActions: any RowActionPerforming = LiveRowActions.shared
    /// Open in Terminal waiting for "Open Anyway" (`TerminalGuard`, #73).
    var terminalConfirmation: TerminalConfirmation?
    /// The panel layout, written when a change finishes (drag frames stay inside `PanelSplitView`); saved per
    /// repository by `commitPanelLayout`.
    var panelLayout: PanelLayout = .default
    /// The graph's column widths and visibility (#255), saved per repository by `commitGraphColumns`.
    var graphColumns: GraphColumnLayout = .default
    /// Shown as the window's alert; cleared when dismissed.
    var alert: AppAlert?
    /// True while a picked folder is being checked.
    var isAddingRepository = false

    /// Line counts requested for one worktree's status, and what came back.
    struct LineCountRequest {
        let path: GitPath
        let state: WorkingState
        var result: WipDetailModel.LineCounts

        func matches(_ path: GitPath, _ state: WorkingState) -> Bool { self.path == path && self.state == state }
    }

    /// Sidebar LOCAL and REMOTE, built once per load (sorting thousands of refs on every render would stall clicks;
    /// security review of #72). `nil` until the list loads with refs.
    var branchListModel: BranchListModel?

    /// The sidebar's ISSUES section.
    /// Worktrees and branches named for issues (#82), built once per listing.
    var issueLinks: IssueLinkIndex = .empty

    /// The newest commits whose subject names `number`. Cached and extended page by page, so a render does not rescan
    /// every loaded commit (security review of #82, T15).
    @ObservationIgnored var commitLinkCache: CommitLinkCache?

    struct CommitLinkCache {
        let number: Int
        let repository: String?
        let first: ObjectID?
        var scanned: Int
        var found: [CommitLink]
    }

    /// - Parameters:
    ///   - layoutStore: Shared by every window; remembers each repository's panel layout.
    ///   - registry: Shared by every window; the registered repositories.
    ///   - registrar: Checks a picked folder (`.live` probes it through `GitClient`).
    ///   - loader: Inspects an opened repository and loads its worktrees.
    ///   - inspector: Reads one worktree's configuration for S-05.
    ///   - diffLoader: Loads a picked file's patch for S-10.
    ///   - stashLoader: Reads a stash's files and patches for S-04.
    ///   - issueLoader: Reads the open issues through gh for S-06.
    ///   - comparisonLoader: Compares a worktree with its base branch for S-11.
    ///   - graphLoader: Reads commit graph pages for the center panel (#68).
    ///   - lineCountLoader: Queries the WIP detail's line counts for the selected worktree. Defaults to `loader` when
    ///     it can (the live loader can); without one, the detail shows no line counts.
    ///   - submoduleLoader: Inspects the selected worktree's submodules for S-02 (#108). Defaults to `loader` when it can.
    ///   - historyLoader: Reads a file's history for S-09.
    ///   - fetcher: Fetches the open repository's remotes. Defaults to `loader` when it can; without one, Fetch is off.
    ///   - fetchRecords: The last fetch of each repository (`UserDefaults`).
    ///   - gitChecker, ghChecker: The setup assistant's git and GitHub CLI checks (S-07); `ghChecker` also feeds the
    ///     status bar's gh field (#83).
    ///   - settings: App preferences (S-08); shared by every window. A fresh one from `UserDefaults` if `nil`.
    ///   - fileWatcher: File events for auto refresh (#119); FSEvents by default.
    init(
        layoutStore: PanelLayoutStore, registry: RepositoryRegistry, registrar: RepositoryRegistrar = .live,
        loader: any RepositoryLoading = LiveRepositoryLoader.live,
        inspector: any WorktreeInspecting = LiveWorktreeInspector.live,
        diffLoader: any DiffLoading = LiveDiffLoader.live,
        stashLoader: any StashLoading = LiveStashLoader.live,
        issueLoader: any IssueLoading = LiveIssueLoader.live,
        comparisonLoader: any ComparisonLoading = LiveComparisonLoader.live,
        lineCountLoader: (any LineCountLoading)? = nil,
        submoduleLoader: (any SubmoduleLoading)? = nil,
        graphLoader: any GraphLoading = LiveGraphLoader.live,
        commitLoader: any CommitLoading = LiveCommitLoader.live,
        historyLoader: any FileHistoryLoading = LiveFileHistoryLoader.live,
        fetcher: (any RepositoryFetching)? = nil,
        fetchRecords: FetchRecordStore = FetchRecordStore(),
        gitChecker: any GitSetupChecking = LiveGitSetupChecker.live,
        ghChecker: any GHAuthChecking = LiveGHAuthChecker.live,
        settings: AppSettings? = nil,
        fileWatcher: any FileEventWatching = LiveFileEventWatcher.live,
        launchSnapshots: LaunchSnapshotStore? = nil,
        gitIdentity: @escaping @Sendable () async -> (executable: URL, version: GitVersion)? = {
            guard let environment = try? await LiveGitClient.shared.client().environment else { return nil }
            return (environment.executable, environment.version)
        }
    ) {
        self.launchSnapshots = launchSnapshots
        self.gitIdentity = gitIdentity
        self.ghChecker = ghChecker
        self.graph = GraphStore(loader: graphLoader)
        self.commitDetail = CommitDetailStore(loader: commitLoader)
        self.commitLoader = commitLoader
        self.history = FileHistoryStore(loader: historyLoader)
        self.layoutStore = layoutStore
        self.registry = registry
        self.registrar = registrar
        self.loader = loader
        self.inspector = inspector
        self.diffLoader = diffLoader
        self.stashLoader = stashLoader
        issuePanel = IssuePanelState(loader: issueLoader)
        let appSettings = settings ?? AppSettings()
        self.settings = appSettings
        // Use Default for a refused Settings choice (ADR-0019 §4): forget it, then rediscover on next use.
        setup = SetupAssistantState(
            gitChecker: gitChecker, ghChecker: ghChecker,
            useDefaultGit: {
                appSettings.gitExecutablePath = nil
                await LiveGitClient.shared.reset()
            })
        self.comparisonLoader = comparisonLoader
        self.lineCountLoader = lineCountLoader ?? (loader as? any LineCountLoading)
        submodules = SubmodulePanel(loader: submoduleLoader ?? (loader as? any SubmoduleLoading))
        fetch = FetchController(fetcher: fetcher ?? (loader as? any RepositoryFetching), store: fetchRecords)
        // The registry's untrusted flag, read when each fetch starts (#107).
        fetch.isUntrusted = { [registry] repository in registry.repository(withID: repository.id)?.isUntrusted ?? false
        }
        // After a fetch, re-query the worktree list, every status (ahead/behind), and the refs (overview.md §5).
        autoRefresh = AutoRefreshController(watcher: fileWatcher)
        autoFetch = AutoFetchScheduler(settings: self.settings, fetch: fetch)
        fetch.onFinished = { [weak self] in self?.refresh(.fetchCompleted) }
        issuePanel.onLoaded = { [weak self] issues in self?.issuesDidLoad(issues) }
        autoRefresh.request = { [weak self] change in self?.requestAutoRefresh(change) ?? false }
        stopFetchWhenUntrusted()
    }

    /// The registered repositories, in the order they were added.
    var registeredRepositories: [RegisteredRepository] { registry.repositories }

    /// Opens `context` in the main window: restores its panel layout and clears the previous repository's data.
    func open(_ context: RepositoryContext) {
        repository = context
        panelLayout = layoutStore.layout(for: context.repository.id)
        graphColumns = layoutStore.columns(for: context.repository.id)
        clearRepositoryData()
    }

    func clearRepositoryData() {
        autoRefresh.update(nil)
        submodules.clear()
        loadTask?.cancel()
        loadTask = nil
        runningTrigger = nil
        loadGeneration += 1
        hasVerifiedListing = false
        supersededRetries = 0
        needsFullLoad = false
        snapshot = nil
        worktreeList = .idle
        branchListModel = nil
        issueLinks = .empty
        focusedWorktreePath = nil
        selection = nil
        selectionHistory.clear()
        selectedFile = nil
        stashTask?.cancel()
        stashGeneration += 1
        stashDetail = nil
        loadedStashOID = nil
        clearStashFile()
        closeComparison()
        comparisonBases = [:]
        lineCountTask?.cancel()
        lineCountTask = nil
        lineCounts = nil
        inspectionTask?.cancel()
        inspectionTask = nil
        worktreeInspections = [:]
        inspectionGeneration += 1
        fetch.open(repository?.repository)
        searchText = ""
        authorFilter = .all
        sidebarFilter = ""
        issuePanel.clear()
        graph.clear()
        commitDetail.clear()
        history.reset()
    }
}
