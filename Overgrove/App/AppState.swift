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
    let inspector: any WorktreeInspecting
    let diffLoader: any DiffLoading
    let stashLoader: any StashLoading
    let ghChecker: any GHAuthChecking
    /// The sidebar's ISSUES and S-06 (#81). gh problems stay inside it (ADR-0004 §4).
    let issuePanel: IssuePanelState
    /// The setup assistant (S-07, #85): git and GitHub CLI checks, first run and Help › Setup Assistant….
    let setup: SetupAssistantState
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
    /// S-11 (#158): the open comparison, `nil` when the center shows the graph or a WIP diff.
    var comparison: ComparisonSession?
    /// The comparison (and its patch) in flight; tests await them.
    var comparisonTask: Task<Void, Never>?
    var comparisonPatchTask: Task<Void, Never>?
    var comparisonGeneration = 0
    /// The base the user picked per worktree, for the session (screens.md S-11: remembered per worktree).
    var comparisonBases: [GitPath: FullRefName] = [:]

    var repository: RepositoryContext?
    /// The toolbar chip and status bar fields, derived from the worktree list and the focused worktree.
    var snapshot: RepositorySnapshot?
    /// The open repository's worktrees and their status.
    var worktreeList: WorktreeListStatus = .idle
    /// The focused worktree (information-architecture.md §2.2). `nil` focuses the main worktree.
    var focusedWorktreePath: GitPath?
    var selection: MainSelection?
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
    /// TODO(#74): drives graph search.
    var searchText = ""
    /// The panel layout, written when a change finishes (drag frames stay inside `PanelSplitView`); saved per
    /// repository by `commitPanelLayout`.
    var panelLayout: PanelLayout = .default
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
    ///   - fetcher: Fetches the open repository's remotes. Defaults to `loader` when it can; without one, Fetch is off.
    ///   - fetchRecords: The last fetch of each repository (`UserDefaults`).
    ///   - gitChecker, ghChecker: The setup assistant's git and GitHub CLI checks (S-07); `ghChecker` also feeds the
    ///     status bar's gh field (#83).
    init(
        layoutStore: PanelLayoutStore, registry: RepositoryRegistry, registrar: RepositoryRegistrar = .live,
        loader: any RepositoryLoading = LiveRepositoryLoader.live,
        inspector: any WorktreeInspecting = LiveWorktreeInspector.live,
        diffLoader: any DiffLoading = LiveDiffLoader.live,
        stashLoader: any StashLoading = LiveStashLoader.live,
        issueLoader: any IssueLoading = LiveIssueLoader.live,
        comparisonLoader: any ComparisonLoading = LiveComparisonLoader.live,
        lineCountLoader: (any LineCountLoading)? = nil,
        graphLoader: any GraphLoading = LiveGraphLoader.live,
        commitLoader: any CommitLoading = LiveCommitLoader.live,
        fetcher: (any RepositoryFetching)? = nil,
        fetchRecords: FetchRecordStore = FetchRecordStore(),
        gitChecker: any GitSetupChecking = LiveGitSetupChecker.live,
        ghChecker: any GHAuthChecking = LiveGHAuthChecker.live
    ) {
        self.ghChecker = ghChecker
        self.graph = GraphStore(loader: graphLoader)
        self.commitDetail = CommitDetailStore(loader: commitLoader)
        self.layoutStore = layoutStore
        self.registry = registry
        self.registrar = registrar
        self.loader = loader
        self.inspector = inspector
        self.diffLoader = diffLoader
        self.stashLoader = stashLoader
        issuePanel = IssuePanelState(loader: issueLoader)
        setup = SetupAssistantState(gitChecker: gitChecker, ghChecker: ghChecker)
        self.comparisonLoader = comparisonLoader
        self.lineCountLoader = lineCountLoader ?? (loader as? any LineCountLoading)
        fetch = FetchController(fetcher: fetcher ?? (loader as? any RepositoryFetching), store: fetchRecords)
        // After a fetch, re-query the worktree list, every status (ahead/behind), and the refs (overview.md §5).
        fetch.onFinished = { [weak self] in self?.refresh(.fetchCompleted) }
        issuePanel.onLoaded = { [weak self] issues in self?.issuesDidLoad(issues) }
    }

    /// The registered repositories, in the order they were added.
    var registeredRepositories: [RegisteredRepository] { registry.repositories }

    /// Opens `context` in the main window: restores its panel layout and clears the previous repository's data.
    func open(_ context: RepositoryContext) {
        repository = context
        panelLayout = layoutStore.layout(for: context.repository.id)
        clearRepositoryData()
    }

    func clearRepositoryData() {
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
        issuePanel.clear()
        graph.clear()
        commitDetail.clear()
    }
}
