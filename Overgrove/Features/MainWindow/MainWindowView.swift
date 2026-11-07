import SwiftUI

/// S-01, the main window (screens.md S-01, ADR-0014): toolbar, three boxed panels on `PanelSplitView`, status bar.
///
/// This is the layout shell. Panel contents are placeholders until their features land (#65 worktrees, #68 graph,
/// #66/#67 detail); the toolbar and status bar read `AppState` and show empty states until their data exists.
struct MainWindowView: View {
    @Bindable var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.controlActiveState) private var controlActiveState
    @State private var isManagingRepositories = false
    @State private var showsFetchDetails = false

    var body: some View {
        window
            .focusedSceneValue(\.repositoryActions, focusedActions)
            .focusedSceneValue(\.navigationActions, navigationActions)
            .onExitCommand(perform: state.escape)
            // `⌘C` with no text selected copies what the selection names (interaction.md §3.1).
            .onCopyCommand {
                state.selectionCopyText.map { [NSItemProvider(object: RowActions.clipboardText($0) as NSString)] } ?? []
            }
            .sheet(isPresented: $isManagingRepositories) {
                ManageRepositoriesView(
                    model: repositoryMenu, isAdding: state.isAddingRepository, actions: repositoryActions,
                    dismiss: { isManagingRepositories = false })
            }
            .alert(item: $state.alert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message))
            }
            .alert(
                "Open in Terminal?", isPresented: terminalConfirmationShown, presenting: state.terminalConfirmation
            ) { _ in
                Button("Open Anyway", action: state.confirmOpenTerminal)
                // Cancel is the default button (`⏎`) as well as `⎋`.
                Button("Cancel", role: .cancel) { state.terminalConfirmation = nil }
                    .keyboardShortcut(.defaultAction)
            } message: { confirmation in
                Text(confirmation.message)
            }
            .task { state.restoreLastSelected() }
            // A closed window cannot show Stop: its fetch is stopped (security review of #77, T15); no more auto fetch.
            .onDisappear {
                state.fetch.stop()
                state.autoFetch.stop()
            }
            // Coming back from an editor: re-query what is stale (interaction.md §4, `.automatic`). Auto fetch runs
            // only while the window is key (#79).
            // `initial`: a window that opens already key counts as active (auto fetch ticks only while key).
            .onChange(of: controlActiveState, initial: true) { _, active in
                if active == .key { state.windowDidBecomeActive() }
                state.autoFetch.windowActivityChanged(isActive: active == .key)
            }
            .modifier(FetchFeedback(state: state, showsDetails: $showsFetchDetails))
            .modifier(SetupAssistantPresentation(state: state, setup: state.setup, addRepository: addRepository))
            // Settings › Repositories can remove the repository this window shows (#86).
            .onChange(of: state.registeredRepositories.map(\.id)) { state.closeIfUnregistered() }
    }

    private var focusedActions: FocusedRepositoryActions {
        FocusedRepositoryActions(
            isAdding: state.isAddingRepository, add: addRepository, canRefresh: state.repository != nil,
            refresh: state.reload, canFetch: state.fetch.canFetch, isFetching: state.fetchStatus.isFetching,
            fetch: state.fetch.fetch, stopFetch: state.fetch.stop, openSetup: state.setup.present)
    }

    private var terminalConfirmationShown: Binding<Bool> {
        Binding(
            get: { state.terminalConfirmation != nil },
            set: { if !$0 { state.terminalConfirmation = nil } })
    }

    private var navigationActions: FocusedNavigationActions {
        FocusedNavigationActions(
            canJumpToHead: state.canJumpToHead, jumpToHead: state.jumpToHead,
            canToggleWorktreeInfo: state.canToggleWorktreeInfo, toggleWorktreeInfo: state.toggleWorktreeInfo,
            focus: state.focus, fullPath: state.fullPathToCopy, copy: state.copy)
    }

    private var window: some View {
        VStack(spacing: 0) {
            PanelSplitView(layout: $state.panelLayout, onCommit: state.commitPanelLayout) {
                SidebarPanel(
                    hasRepository: state.repository != nil, worktreeStatus: state.worktreeList,
                    worktreeModel: state.worktreeListModel, selectedWorktree: state.focusedWorktreePath,
                    onSelectWorktree: state.selectWorktree, branchModel: state.branchListModel,
                    remoteURLTooltips: state.remoteURLTooltips,
                    stashRows: state.stashes.map(StashRow.init),
                    isStashListPartial: state.isStashListPartial, selectedStash: state.selectedStashOID,
                    onSelectStash: state.selectStash, issueModel: state.issueListModel,
                    selectedIssue: state.selectedIssueNumber, onSelectIssue: state.selectIssue,
                    onCheckIssuesAgain: state.checkIssuesAgain,
                    canCompareWorktree: { state.canCompare($0) },
                    onCompareWorktree: { state.showComparison(of: $0) })
            } center: {
                GraphPanel(
                    hasRepository: state.repository != nil, graphStore: state.graph,
                    highlightedCommits: state.highlightedCommits, onSelectCommit: state.selectCommit,
                    onSelectWip: state.selectFocusedWip, onOpen: { state.focus(.detail) },
                    diff: state.diffViewer,
                    onShowGraph: state.clearSelectedFile,
                    onShowDiffHistory: state.shownFileHistoryTarget == nil ? nil : { state.showHistoryOfShownFile() },
                    history: historyCenter, comparison: comparisonCenter)
            } detail: {
                DetailPanel(
                    focusedWorktree: state.snapshot?.focusedWorktree, worktreeStatus: state.worktreeList,
                    wipModel: state.wipDetailModel, worktreeModel: state.worktreeDetailModel,
                    selectedFile: state.selectedFile, onSelectFile: state.selectFile,
                    showsWorktreeSegment: state.selection.flatMap {
                        switch $0 {
                        case .worktreeInfo: true
                        case .wip: false
                        case .stash, .commit, .issue: nil
                        }
                    },
                    commitModel: state.commitDetailModel, commitLane: state.selectedCommitLane,
                    selectedCommitFile: state.commitDetail.selectedFile?.path,
                    onSelectCommitFile: state.selectCommitFile, onSelectParent: state.selectCommit,
                    onShowAllCommitFiles: state.showAllCommitFiles,
                    stashModel: state.stashDetailModel, selectedStashFile: state.selectedStashFile?.path,
                    onSelectStashFile: state.selectStashFile, issueModel: state.issueDetailModel,
                    onSelectLinkedWorktree: state.selectWorktree, onSelectLinkedCommit: state.selectLinkedCommit,
                    onShowChanges: state.showChanges, onShowWorktree: state.showWorktreeDetail,
                    comparisonList: comparisonList,
                    onCompare: state.canCompare() ? { state.showComparison() } : nil)
            }
            statusBar
        }
        // Under the toolbar too, so the title bar area is `surface.window` like the status bar (art-direction §3).
        .background(Tokens.Color.surfaceWindow.ignoresSafeArea())
        // `#n` badges on worktree, branch, and graph rows (#82).
        .environment(\.issueBadges, state.issueBadgeContext)
        .environment(\.rowMenu, state.rowMenuActions)
        .environment(\.panelFocusRequest, state.panelFocusRequest)
        .toolbar {
            MainToolbar(
                repository: state.repository,
                repositoryMenu: repositoryMenu,
                isAddingRepository: state.isAddingRepository,
                repositoryActions: repositoryActions,
                focusedWorktree: state.snapshot?.focusedWorktree,
                isSidebarCollapsed: state.panelLayout.isSidebarCollapsed,
                toggleSidebar: toggleSidebar,
                refresh: refreshAction,
                onCompare: state.canCompare() ? { state.showComparison() } : nil,
                onFetch: fetchAction,
                isFetching: state.fetchStatus.isFetching
            )
        }
        .toolbarBackground(Tokens.Color.surfaceWindow, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        // TODO(#74): filter the graph by message, author, SHA, ref, or #issue; ⌘G / ⌘⇧G between matches.
        .searchable(text: $state.searchText, placement: .toolbar, prompt: "Search commits, authors, refs, #issues")
        .navigationTitle(state.repository?.name ?? "Overgrove")
    }

    /// Relative fetch times ("2 min ago") stay current without a model change.
    private var statusBar: some View {
        TimelineView(.periodic(from: .now, by: statusRefreshInterval)) { context in
            StatusBar(
                items: StatusBarItem.items(
                    snapshot: state.snapshot, fetchStatus: state.fetchStatus, ghStatus: state.ghStatus,
                    now: context.date, hasFetchDetails: !state.fetch.failures.isEmpty,
                    isRefreshing: state.isRefreshing, fetchRemoteLimit: state.fetch.remoteLimit),
                onFetchDetails: state.fetch.hasDetails ? { showsFetchDetails = true } : nil,
                onGitHubSetup: { state.setup.present() })
        }
    }

    /// Fetch, or Stop while fetching; disabled without a repository.
    private var fetchAction: (() -> Void)? {
        guard state.fetch.canFetch else { return nil }
        let fetch = state.fetch
        return { fetch.status.isFetching ? fetch.stop() : fetch.fetch() }
    }

    /// S-09 when a file's history is open (#70).
    private var historyCenter: FileHistoryView? {
        guard state.history.isOpen else { return nil }
        let state = state
        return FileHistoryView(
            store: state.history, onBack: state.closeHistory, onSelect: state.selectHistoryEntry,
            onOpen: state.openHistoryDiff)
    }

    /// ⌘R from the toolbar; disabled without a repository.
    private var refreshAction: (() -> Void)? {
        guard state.repository != nil else { return nil }
        let state = state
        return { state.reload() }
    }

    private var repositoryMenu: RepositoryMenuModel {
        RepositoryMenuModel(repositories: state.registeredRepositories, openID: state.repository?.repository.id)
    }

    private var repositoryActions: RepositoryActions {
        RepositoryActions(
            open: { state.openRegistered($0) },
            add: addRepository,
            remove: { state.removeRepository($0) },
            manage: { isManagingRepositories = true })
    }

    /// NSOpenPanel, then registration. The picker is a sheet on the key window (or on the manage sheet).
    private func addRepository() {
        Task {
            guard let folder = await RepositoryPicker.choose(in: NSApp.keyWindow) else { return }
            await state.addRepository(at: folder)
        }
    }

    // MARK: Compare with base (#158)

    private var comparisonCenter: ComparisonCenterView? {
        guard let session = state.comparison, let model = state.comparisonModel else { return nil }
        return ComparisonCenterView(
            session: session, model: model, onBack: state.closeComparison, onChooseBase: state.chooseComparisonBase,
            onIncludeUncommitted: state.setIncludeUncommitted)
    }

    private var comparisonList: ComparisonListView? {
        guard let session = state.comparison, let model = state.comparisonModel else { return nil }
        return ComparisonListView(
            title: state.snapshot?.focusedWorktree?.title ?? "", session: session, model: model,
            onSelect: state.selectComparisonFile, onShowAll: state.showAllComparisonFiles)
    }

    private func toggleSidebar() {
        if reduceMotion {
            state.togglePanel(.sidebar)
        } else {
            withAnimation(.panelCollapse) { state.togglePanel(.sidebar) }
        }
    }

    /// Relative times ("2 min ago") update every 30 s; the running fetch timer ("12 s") every second.
    private var statusRefreshInterval: TimeInterval {
        if case .fetching = state.fetchStatus { return 1 }
        return 30
    }
}

// MARK: - Previews

#if DEBUG
    extension PanelLayoutStore {
        /// Previews keep their layouts out of the app's own preferences.
        static var preview: PanelLayoutStore {
            PanelLayoutStore(defaults: UserDefaults(suiteName: "io.github.kkdy21.overgrove.previews") ?? .standard)
        }
    }

    extension RepositoryRegistry {
        /// Previews keep their repositories out of the app's own preferences.
        static var preview: RepositoryRegistry {
            RepositoryRegistry(defaults: UserDefaults(suiteName: "io.github.kkdy21.overgrove.previews") ?? .standard)
        }
    }

    extension AppState {
        /// The repository of the high-fidelity mockup (design/mockups/main-window-*.png), for previews and the
        /// render test. Uses no file system or git.
        static func mockup(layoutStore: PanelLayoutStore = .preview) -> AppState {
            let state = AppState(layoutStore: layoutStore, registry: .preview)
            let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
            state.open(
                RepositoryContext(
                    repository: Repository(
                        rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                    owner: "acme"))
            state.showForPreview(.mockup)
            state.selectWorktree(GitPath("/tmp/dev/api-wt/42-rate-limit"))
            state.fetch.showForPreview(.idle(lastFetched: Date().addingTimeInterval(-120)))
            state.ghStatus = .loggedIn(login: "mina-dev")
            return state
        }
    }

    #Preview("Mockup data") {
        MainWindowView(state: .mockup()).frame(width: 1440, height: 900)
    }

    #Preview("No repository") {
        MainWindowView(state: AppState(layoutStore: .preview, registry: .preview))
            .frame(width: 1440, height: 900)
    }
#endif

/// The fetch failure Details sheet and the VoiceOver announcement when a fetch ends (#77).
private struct FetchFeedback: ViewModifier {
    let state: AppState
    @Binding var showsDetails: Bool

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $showsDetails) {
                FetchFailureDetailsView(
                    failures: state.fetch.failures, remoteLimit: state.fetch.remoteLimit,
                    dismiss: { showsDetails = false })
            }
            .onChange(of: state.fetchStatus) { old, new in
                // Auto fetch (#79) ends quietly: its result is in the status bar only (interaction.md §4.2).
                if !state.fetch.isAutomaticRun, let text = FetchAnnouncement.text(from: old, to: new) {
                    AccessibilityNotification.Announcement(text).post()
                }
            }
            // Settings › Fetch automatically and its interval (#79).
            .task(id: AutoFetchSettingKey(state.settings)) { state.autoFetch.update() }
    }
}

/// The setup assistant sheet (S-07, #85): first run, and Help › Setup Assistant….
private struct SetupAssistantPresentation: ViewModifier {
    let state: AppState
    @Bindable var setup: SetupAssistantState
    let addRepository: () -> Void

    func body(content: Content) -> some View {
        content.sheet(isPresented: $setup.isPresented) {
            SetupAssistantView(
                setup: setup, repositoryPath: repositoryPath, isAddingRepository: state.isAddingRepository,
                onChooseFolder: addRepository)
        }
    }

    /// `~/dev/api` of the open repository (`displayRootPath` is already escaped).
    private var repositoryPath: String? {
        guard let id = state.repository?.repository.id else { return nil }
        return state.registeredRepositories.first { $0.id == id }?.displayRootPath
    }
}

/// Changes when the auto fetch settings change, so the window's scheduler restarts (#79).
private struct AutoFetchSettingKey: Equatable {
    let isOn: Bool
    let minutes: Int

    @MainActor init(_ settings: AppSettings) {
        isOn = settings.autoFetch
        minutes = settings.autoFetchIntervalMinutes
    }
}
