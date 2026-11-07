import SwiftUI

/// S-01, the main window (screens.md S-01, ADR-0014): toolbar, three boxed panels on `PanelSplitView`, status bar.
///
/// This is the layout shell. Panel contents are placeholders until their features land (#65 worktrees, #68 graph,
/// #66/#67 detail); the toolbar and status bar read `AppState` and show empty states until their data exists.
struct MainWindowView: View {
    @Bindable var state: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isManagingRepositories = false

    var body: some View {
        VStack(spacing: 0) {
            PanelSplitView(layout: $state.panelLayout, onCommit: state.commitPanelLayout) {
                SidebarPanel(
                    hasRepository: state.repository != nil, worktreeStatus: state.worktreeList,
                    worktreeModel: state.worktreeListModel, selectedWorktree: state.focusedWorktreePath,
                    onSelectWorktree: state.selectWorktree, canCompareWorktree: { state.canCompare($0) },
                    onCompareWorktree: { state.showComparison(of: $0) })
            } center: {
                GraphPanel(
                    hasRepository: state.repository != nil, graphStore: state.graph, diff: state.diffViewer,
                    onShowGraph: state.clearSelectedFile, comparison: comparisonCenter)
            } detail: {
                DetailPanel(
                    focusedWorktree: state.snapshot?.focusedWorktree, worktreeStatus: state.worktreeList,
                    wipModel: state.wipDetailModel, worktreeModel: state.worktreeDetailModel,
                    selectedFile: state.selectedFile, onSelectFile: state.selectFile,
                    showsWorktreeSegment: state.selection.map { if case .worktreeInfo = $0 { true } else { false } },
                    onShowChanges: state.showChanges, onShowWorktree: state.showWorktreeDetail,
                    comparisonList: comparisonList,
                    onCompare: state.canCompare() ? { state.showComparison() } : nil)
            }
            // Relative fetch times ("2 min ago") stay current without a model change.
            TimelineView(.periodic(from: .now, by: statusRefreshInterval)) { context in
                StatusBar(
                    items: StatusBarItem.items(
                        snapshot: state.snapshot, fetchStatus: state.fetchStatus, ghStatus: state.ghStatus,
                        now: context.date))
            }
        }
        // Under the toolbar too, so the title bar area is `surface.window` like the status bar (art-direction §3).
        .background(Tokens.Color.surfaceWindow.ignoresSafeArea())
        .toolbar {
            MainToolbar(
                repository: state.repository,
                repositoryMenu: repositoryMenu,
                isAddingRepository: state.isAddingRepository,
                repositoryActions: repositoryActions,
                focusedWorktree: state.snapshot?.focusedWorktree,
                isSidebarCollapsed: state.panelLayout.isSidebarCollapsed,
                toggleSidebar: toggleSidebar,
                onCompare: state.canCompare() ? { state.showComparison() } : nil
            )
        }
        .toolbarBackground(Tokens.Color.surfaceWindow, for: .windowToolbar)
        .toolbarBackground(.visible, for: .windowToolbar)
        // TODO(#74): filter the graph by message, author, SHA, ref, or #issue; ⌘G / ⌘⇧G between matches.
        .searchable(text: $state.searchText, placement: .toolbar, prompt: "Search commits, authors, refs, #issues")
        .navigationTitle(state.repository?.name ?? "Overgrove")
        .focusedSceneValue(
            \.repositoryActions,
            FocusedRepositoryActions(isAdding: state.isAddingRepository, add: addRepository)
        )
        .sheet(isPresented: $isManagingRepositories) {
            ManageRepositoriesView(
                model: repositoryMenu, isAdding: state.isAddingRepository, actions: repositoryActions,
                dismiss: { isManagingRepositories = false })
        }
        .alert(item: $state.alert) { alert in
            Alert(title: Text(alert.title), message: Text(alert.message))
        }
        .task { state.restoreLastSelected() }
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
            state.fetchStatus = .idle(lastFetched: Date().addingTimeInterval(-120))
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
