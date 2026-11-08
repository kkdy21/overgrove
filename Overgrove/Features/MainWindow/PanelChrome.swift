import SwiftUI

/// The 40pt strip at the top of every panel: `surface.panel-header` with a `border.separator` line below
/// (art-direction.md §3, `size.panel-header`).
struct PanelHeader<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            content
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .frame(height: Tokens.Size.panelHeader)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.Color.surfacePanelHeader)
        .overlay(alignment: .bottom) {
            Tokens.Color.borderSeparator.frame(height: 1)
        }
    }
}

/// A panel with its header and a body that fills the rest.
struct PanelSection<Header: View, Content: View>: View {
    @ViewBuilder let header: Header
    @ViewBuilder let content: Content

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader { header }
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// What a panel shows before its feature or its data is there.
struct PanelEmptyState: View {
    let symbol: String
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: Tokens.Spacing.sm) {
            Image(systemName: symbol)
                .font(Tokens.Font.title)
                .foregroundStyle(Tokens.Color.textTertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(Tokens.Font.headline)
                .foregroundStyle(Tokens.Color.textSecondary)
            Text(message)
                .font(Tokens.Font.callout)
                .foregroundStyle(Tokens.Color.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(Tokens.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - The three panels of S-01

/// Sidebar: filter header, then WORKTREES / LOCAL / REMOTE / TAGS / STASHES / ISSUES.
struct SidebarPanel: View {
    let hasRepository: Bool
    var worktreeStatus: WorktreeListStatus = .idle
    var worktreeModel: WorktreeListModel?
    var selectedWorktree: GitPath?
    var onSelectWorktree: (GitPath) -> Void = { _ in }
    /// LOCAL and REMOTE (#72), and TAGS (#377).
    var branchModel: BranchListModel?
    /// The selected commit, for the chosen TAGS row's highlight (#377).
    var selectedCommit: ObjectID?
    /// Remote name → URL text for the REMOTE group tooltips (#86).
    var remoteURLTooltips: [String: String] = [:]
    /// STASHES (#71).
    var stashRows: [StashRow] = []
    var isStashListPartial = false
    var selectedStash: ObjectID?
    var onSelectStash: (ObjectID) -> Void = { _ in }
    /// ISSUES (#81).
    var issueModel: IssueListModel?
    var selectedIssue: Int?
    var onSelectIssue: (Int) -> Void = { _ in }
    var onCheckIssuesAgain: () -> Void = {}
    var canCompareWorktree: (GitPath) -> Bool = { _ in false }
    var onCompareWorktree: (GitPath) -> Void = { _ in }
    /// The Filter field (⌥⌘F, #74): worktrees, branches, stashes, and issues whose names contain it.
    var filter: Binding<String> = .constant("")
    var filterFocusRequest = 0

    private var query: String? { SidebarFilter.query(filter.wrappedValue) }

    var body: some View {
        PanelSection {
            SidebarFilterField(text: filter, focusRequest: filterFocusRequest)
        } content: {
            if hasRepository {
                ScrollView {
                    VStack(alignment: .leading, spacing: 0) {
                        WorktreeListSection(
                            status: worktreeStatus, model: worktreeModel?.filtered(query),
                            selectedPath: selectedWorktree,
                            onSelect: onSelectWorktree, canCompare: canCompareWorktree,
                            onCompare: onCompareWorktree)
                        if let branchModel {
                            BranchListSection(
                                title: "LOCAL", count: branchModel.localCount,
                                nodes: SidebarFilter.branches(branchModel.local, query: query),
                                warning: branchModel.warning, isFiltered: query != nil)
                            BranchListSection(
                                title: "REMOTE", count: branchModel.remoteCount,
                                nodes: SidebarFilter.branches(branchModel.remote, query: query),
                                folderHelp: Self.remoteFolderHelp(remoteURLTooltips), isFiltered: query != nil)
                            TagListSection(model: branchModel.tags, query: query, selectedCommit: selectedCommit)
                        }
                        if case .loaded = worktreeStatus {
                            StashListSection(
                                rows: stashRows.filter { SidebarFilter.matches(query, $0.refName, $0.message) },
                                isPartial: isStashListPartial, selectedID: selectedStash,
                                onSelect: onSelectStash)
                        }
                        if let issueModel {
                            IssueListSection(
                                model: issueModel.filtered(query), selectedNumber: selectedIssue,
                                onSelect: onSelectIssue,
                                onCheckAgain: onCheckIssuesAgain)
                        }
                    }
                }
            } else {
                PanelEmptyState(
                    symbol: "folder", title: "No repository open",
                    message: "Add a repository to see its worktrees.")
            }
        }
    }
}

/// Center: author filter header, column headers, and the commit graph (#68).
struct GraphPanel: View {
    let hasRepository: Bool
    var graphStore: GraphStore?
    /// Commits outlined for the selected issue (#82).
    var highlightedCommits: Set<ObjectID> = []
    var onSelectCommit: ((ObjectID) -> Void)?
    var onSelectWip: (() -> Void)?
    var onOpen: () -> Void = {}
    /// The toolbar search over the loaded graph (#74).
    var search: GraphSearchResult?
    var onFindNext: () -> Void = {}
    var onFindPrevious: () -> Void = {}
    /// The header's author chips (#255); `nil` until the graph loads.
    var authorSummary: GraphAuthorSummary?
    var authorFilter: GraphAuthorSelection = .all
    var authorMatches: Set<ObjectID>?
    var onSelectAuthor: (GraphAuthorSelection) -> Void = { _ in }
    /// Column widths and visibility (#255).
    var columns: GraphColumnLayout = .default
    var onCommitColumns: (GraphColumnLayout) -> Void = { _ in }
    /// A file picked in the detail panel covers the graph with its diff (S-10, #232).
    var diff: (title: String, source: String, state: DiffLoadState)?
    var onShowGraph: () -> Void = {}
    /// `Show History` of the diff's file (S-09, #70).
    var onShowDiffHistory: (() -> Void)?
    /// S-09 covers the graph while a file's history is open; a diff opened from it covers it in turn (#70).
    var history: FileHistoryView?

    /// S-11 covers the graph while a comparison is open (#158).
    var comparison: ComparisonCenterView?
    /// S-12 covers the graph while two commits are compared (#388).
    var commitComparison: CommitComparisonCenterView?

    var body: some View {
        if let comparison {
            comparison
        } else if let commitComparison {
            commitComparison
        } else if let diff {
            DiffViewerView(
                title: diff.title, sourceLabel: diff.source, state: diff.state, onBack: onShowGraph,
                backTitle: history == nil ? "Graph" : "History", onShowHistory: onShowDiffHistory)
        } else if let history {
            history
        } else {
            graph
        }
    }

    private var graph: some View {
        PanelSection {
            if let authorSummary, authorSummary.hasChoices, graphStore?.status == .loaded {
                // Wider than the panel with many long names: the row scrolls rather than squeezing the `⋯` out.
                ScrollView(.horizontal, showsIndicators: false) {
                    GraphAuthorFilterBar(summary: authorSummary, selection: authorFilter, onSelect: onSelectAuthor)
                }
                .scrollBounceBehavior(.basedOnSize)
            } else {
                Image(systemName: "person.2").foregroundStyle(Tokens.Color.textSecondary).accessibilityHidden(true)
                Text("Commits").font(Tokens.Font.headline).foregroundStyle(Tokens.Color.textPrimary)
                Spacer(minLength: Tokens.Spacing.sm)
            }
            if graphStore?.status == .loaded {
                GraphColumnMenu(columns: columns, onChange: onCommitColumns)
            }
        } content: {
            switch graphStore?.status {
            case .loaded?:
                if let graphStore {
                    GraphView(
                        store: graphStore, onSelectCommit: onSelectCommit, highlighted: highlightedCommits,
                        onSelectWip: onSelectWip, onOpen: onOpen, search: search, onFindNext: onFindNext,
                        onFindPrevious: onFindPrevious, authorMatches: authorMatches, columns: columns,
                        onCommitColumns: onCommitColumns)
                }
            case .loading?:
                ProgressView("Loading history…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message)?:
                PanelEmptyState(symbol: "exclamationmark.triangle", title: "History unavailable", message: message)
            case .idle?, nil:
                PanelEmptyState(
                    symbol: "point.3.connected.trianglepath.dotted", title: "Commit graph",
                    message: hasRepository
                        ? "The history of every worktree appears here." : "Open a repository to see its history.")
            }
        }
    }
}

/// Detail: the selected worktree's changes (S-02) or facts and safety (S-05), switched by the header segment.
struct DetailPanel: View {
    let focusedWorktree: FocusedWorktree?
    var worktreeStatus: WorktreeListStatus = .idle
    var wipModel: WipDetailModel?
    var worktreeModel: WorktreeDetailModel?
    var selectedFile: FileSelection?
    var onSelectFile: (FileSelection) -> Void = { _ in }
    /// `nil` hides the segment (nothing selected, or a selection that is not a worktree).
    var showsWorktreeSegment: Bool?
    /// S-03 when a commit is selected (#69).
    var commitModel: CommitDetailModel?
    var commitLane = 0
    var selectedCommitFile: GitPath?
    var onSelectCommitFile: (FileStat) -> Void = { _ in }
    var onSelectParent: (ObjectID) -> Void = { _ in }
    var onShowAllCommitFiles: () -> Void = {}
    /// S-04 when a stash is selected (#71).
    var stashModel: StashDetailModel?
    var selectedStashFile: GitPath?
    var onSelectStashFile: (FileStat) -> Void = { _ in }
    /// S-06 when an issue is selected (#81).
    var issueModel: IssueDetailModel?
    var onSelectLinkedWorktree: (GitPath) -> Void = { _ in }
    var onSelectLinkedCommit: (ObjectID) -> Void = { _ in }
    var onShowChanges: () -> Void = {}
    var onShowWorktree: () -> Void = {}
    /// S-11's lists while a comparison is open (#158).
    var comparisonList: ComparisonListView?
    /// S-12's commits and files (#388).
    var commitComparisonList: CommitComparisonListView?
    /// S-05's `Compare with Base…` (#158); `nil` disables it.
    var onCompare: (() -> Void)?
    /// S-05 "Treat as untrusted" (#107).
    var onSetUntrusted: ((Bool) -> Void)?

    private var title: String {
        if let commitModel { return "Commit \(commitModel.shortSHA)" }
        if let issueModel { return issueModel.number }
        if let stashModel { return stashModel.refName }
        return wipModel?.title ?? worktreeModel?.title ?? focusedWorktree?.title ?? "No selection"
    }

    var body: some View {
        PanelSection {
            Image(systemName: "tree.fill").foregroundStyle(Tokens.Color.textSecondary).accessibilityHidden(true)
            Text(title)
                .font(Tokens.Font.headline)
                .foregroundStyle(Tokens.Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            if let isWorktree = showsWorktreeSegment {
                Spacer(minLength: Tokens.Spacing.sm)
                DetailSegmentPicker(isWorktree: isWorktree, onChanges: onShowChanges, onWorktree: onShowWorktree)
            }
        } content: {
            if let comparisonList {
                comparisonList
            } else if let commitComparisonList {
                commitComparisonList
            } else if let commitModel {
                CommitDetailView(
                    model: commitModel, laneIndex: commitLane, selectedFile: selectedCommitFile,
                    onSelectFile: onSelectCommitFile, onSelectParent: onSelectParent,
                    onShowAllFiles: onShowAllCommitFiles)
            } else if let issueModel {
                IssueDetailView(
                    model: issueModel, onSelectWorktree: onSelectLinkedWorktree,
                    onSelectCommit: onSelectLinkedCommit)
            } else if let stashModel {
                StashDetailView(model: stashModel, selectedFile: selectedStashFile, onSelectFile: onSelectStashFile)
            } else if let worktreeModel {
                WorktreeDetailView(model: worktreeModel, onCompare: onCompare, onSetUntrusted: onSetUntrusted)
            } else if let wipModel {
                WipDetailView(model: wipModel, selectedFile: selectedFile, onSelect: onSelectFile)
            } else if worktreeStatus.isAwaitingLoad {
                ProgressView().controlSize(.small)
            } else {
                PanelEmptyState(
                    symbol: "doc.text.magnifyingglass", title: "Details",
                    message: "Changes in the focused worktree or the selected commit appear here.")
            }
        }
    }
}

extension SidebarPanel {
    /// REMOTE folder ids are `remote:<name>` (`BranchListModel`); the tooltip is `origin — github.com/acme/api`.
    static func remoteFolderHelp(_ urls: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: urls.map { ("remote:\($0.key)", "\($0.key) — \($0.value)") })
    }
}
