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
    /// The next step, when there is one (screens.md: "(가능하면) 다음 행동", #573).
    var action: (title: String, perform: () -> Void)?

    var body: some View {
        VStack(spacing: Tokens.Spacing.sm) {
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
            .accessibilityElement(children: .combine)
            if let action {
                Button(action.title, action: action.perform)
                    .controlSize(.regular)
                    .padding(.top, Tokens.Spacing.xs)
            }
        }
        .padding(Tokens.Spacing.lg)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
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
    /// `Add Repository…` in the empty sidebar (#573); `nil` hides the button.
    var onAddRepository: (() -> Void)?

    @Environment(\.panelFocusRequest) private var focusRequest
    /// A `⌘4` request ISSUES has not handled yet: the lazy list may not have built the section when it arrives.
    @State private var pendingIssuesFocus: UUID?

    /// Scroll target just before ISSUES.
    static let issuesAnchor = "sidebar.issues"

    private var query: String? { SidebarFilter.query(filter.wrappedValue) }

    var body: some View {
        PanelSection {
            SidebarFilterField(text: filter, focusRequest: filterFocusRequest)
        } content: {
            if hasRepository {
                ScrollViewReader { proxy in
                    ScrollView {
                        // Each section's header stays at the top while its rows scroll (interaction.md §2.1, #573).
                        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
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
                                Color.clear.frame(height: 0).id(Self.issuesAnchor)
                                IssueListSection(
                                    model: issueModel.filtered(query), selectedNumber: selectedIssue,
                                    onSelect: onSelectIssue,
                                    onCheckAgain: onCheckIssuesAgain, pendingFocus: pendingIssuesFocus,
                                    onFocusHandled: { pendingIssuesFocus = nil })
                            }
                        }
                    }
                    // `⌘4` (interaction.md §3.1): bring ISSUES into view first, so the lazy list builds it, then let it
                    // open and take focus.
                    .onChange(of: focusRequest) { _, request in
                        guard let request, request.panel == .issues, issueModel != nil else { return }
                        proxy.scrollTo(Self.issuesAnchor, anchor: .top)
                        pendingIssuesFocus = request.token
                    }
                }
            } else {
                PanelEmptyState(
                    symbol: "folder", title: String(localized: "No repository open"),
                    message: String(localized: "Add a repository to see its worktrees."),
                    action: onAddRepository.map { (String(localized: "Add Repository…"), $0) })
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
    /// Stashes in the graph (#384): drawn only when `showsStashes`.
    var stashes: [Stash] = []
    var selectedStash: ObjectID?
    var onSelectStash: (ObjectID) -> Void = { _ in }
    /// The WIP row shows the selection bar (#574).
    var isWipSelected = false
    var showsStashes = true
    /// The author chips' width and the room they get: the row fades at its end only when it overflows.
    @State private var chipsWidth: CGFloat = 0
    @State private var chipsViewport: CGFloat = 0
    var onSetShowsStashes: ((Bool) -> Void)?
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

    /// Which screen covers the center area, as the key the new screen fades in on (#576).
    enum Screen: Hashable {
        case graph, history, diff, comparison, commitComparison
    }

    var screen: Screen {
        if comparison != nil { return .comparison }
        if commitComparison != nil { return .commitComparison }
        if diff != nil { return .diff }
        if history != nil { return .history }
        return .graph
    }

    var body: some View {
        // S-09 to S-12 fade in over the graph, and the graph fades back in; another file's diff replaces the shown one
        // in place.
        screenContent.fadeIn(on: screen)
    }

    @ViewBuilder
    private var screenContent: some View {
        if let comparison {
            comparison
        } else if let commitComparison {
            commitComparison
        } else if let diff {
            DiffViewerView(
                title: diff.title, sourceLabel: diff.source, state: diff.state, onBack: onShowGraph,
                backTitle: history == nil
                    ? String(localized: "Graph", comment: "Back button to the graph")
                    : String(localized: "History", comment: "Back button to file history"),
                onShowHistory: onShowDiffHistory)
        } else if let history {
            history
        } else {
            graph
        }
    }

    private var graph: some View {
        PanelSection {
            if let authorSummary, authorSummary.hasChoices, graphStore?.status == .loaded {
                // Wider than the panel with many long names: the row scrolls rather than squeezing the `⋯` out, and
                // fades out at its end instead of cutting a chip in half (#574).
                ScrollView(.horizontal, showsIndicators: false) {
                    GraphAuthorFilterBar(summary: authorSummary, selection: authorFilter, onSelect: onSelectAuthor)
                        .onGeometryChange(for: CGFloat.self) {
                            $0.size.width
                        } action: {
                            chipsWidth = $0
                        }
                }
                .scrollBounceBehavior(.basedOnSize)
                .onGeometryChange(for: CGFloat.self) {
                    $0.size.width
                } action: {
                    chipsViewport = $0
                }
                .mask { TrailingFade(isActive: chipsWidth > chipsViewport + 0.5) }
                .padding(.trailing, Tokens.Spacing.sm)
            } else {
                Image(systemName: "person.2").foregroundStyle(Tokens.Color.textSecondary).accessibilityHidden(true)
                Text("Commits").font(Tokens.Font.headline).foregroundStyle(Tokens.Color.textPrimary)
                Spacer(minLength: Tokens.Spacing.sm)
            }
            if graphStore?.status == .loaded {
                GraphColumnMenu(
                    columns: columns, onChange: onCommitColumns, showsStashes: showsStashes,
                    onSetShowsStashes: onSetShowsStashes)
            }
        } content: {
            switch graphStore?.status {
            case .loaded?:
                if let graphStore {
                    GraphView(
                        store: graphStore, onSelectCommit: onSelectCommit, highlighted: highlightedCommits,
                        onSelectWip: onSelectWip, onOpen: onOpen, search: search, onFindNext: onFindNext,
                        onFindPrevious: onFindPrevious, authorMatches: authorMatches, columns: columns,
                        onCommitColumns: onCommitColumns, stashes: showsStashes ? stashes : [],
                        selectedStash: selectedStash, onSelectStash: onSelectStash, isWipSelected: isWipSelected)
                }
            case .loading?:
                ProgressView("Loading history…").controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message)?:
                PanelEmptyState(
                    symbol: "exclamationmark.triangle", title: String(localized: "History unavailable"),
                    message: message)
            case .idle?, nil:
                PanelEmptyState(
                    symbol: "point.3.connected.trianglepath.dotted", title: String(localized: "Commit graph"),
                    message: hasRepository
                        ? String(localized: "The history of every worktree appears here.")
                        : String(localized: "Open a repository to see its history."))
            }
        }
    }
}

/// Detail: the selected worktree's changes (S-02) or facts and safety (S-05), switched by the header segment.
struct DetailPanel: View {
    let focusedWorktree: FocusedWorktree?
    var worktreeStatus: WorktreeListStatus = .idle
    var wipModel: WipDetailModel?
    /// S-02's Submodules card (#108).
    var submoduleSection: SubmoduleSectionModel?
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
    /// The focused worktree's lane (`WorktreeRow.laneIndex`): the header's worktree tile (#578).
    var worktreeLane: Int?

    @State private var width: CGFloat = 0

    /// The header follows the content's order (#578): a comparison names what it compares instead of the WIP or
    /// commit behind it.
    private var header: DetailHeader {
        DetailHeader(
            DetailHeader.Subject(
                comparisonBase: comparisonList?.model.baseName,
                commitComparisonTitle: commitComparisonList?.model.title,
                commit: commitModel.map { ($0.shortSHA, $0.author, commitLane) },
                issueNumber: issueModel?.number, stashRef: stashModel?.refName,
                worktreeTitle: wipModel?.title ?? worktreeModel?.title ?? focusedWorktree?.title,
                worktreeLane: worktreeLane))
    }

    var body: some View {
        let header = header
        PanelSection {
            DetailHeaderMark(mark: header.mark)
            // The title keeps its room before the segment does and is cut at its end (#578).
            Text(header.title)
                .font(Tokens.Font.headline)
                .foregroundStyle(Tokens.Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
                .help(header.title)
            if let isWorktree = showsWorktreeSegment {
                Spacer(minLength: Tokens.Spacing.sm)
                DetailSegmentPicker(isWorktree: isWorktree, onChanges: onShowChanges, onWorktree: onShowWorktree)
                    .controlSize(width < Self.compactWidth ? .small : .regular)
            }
        } content: {
            detailContent.fadeIn(on: content)
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            width = $0
        }
    }

    /// What the panel shows, as the key new content fades in on (#576). Another commit or file under the same
    /// kind updates in place.
    enum Content: Hashable {
        case comparison, commitComparison, commit, issue, stash, worktree, wip, loading, empty
    }

    var content: Content {
        if comparisonList != nil { return .comparison }
        if commitComparisonList != nil { return .commitComparison }
        if commitModel != nil { return .commit }
        if issueModel != nil { return .issue }
        if stashModel != nil { return .stash }
        if worktreeModel != nil { return .worktree }
        if wipModel != nil { return .wip }
        return worktreeStatus.isAwaitingLoad ? .loading : .empty
    }

    @ViewBuilder
    private var detailContent: some View {
        Group {
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
                WipDetailView(
                    model: wipModel, selectedFile: selectedFile, onSelect: onSelectFile, submodules: submoduleSection)
            } else if worktreeStatus.isAwaitingLoad {
                ProgressView().controlSize(.small)
            } else {
                PanelEmptyState(
                    symbol: "doc.text.magnifyingglass", title: String(localized: "Details"),
                    message: String(localized: "Changes in the focused worktree or the selected commit appear here."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Below this width the `Changes | Worktree` segment is small, so the title keeps room at the panel's 300pt
    /// minimum (#578). No token.
    static let compactWidth: CGFloat = 340
}

extension SidebarPanel {
    /// REMOTE folder ids are `remote:<key>` with the name's byte key (`BranchListModel`, `BranchNode.key`, #565); the
    /// tooltip is `origin — github.com/acme/api`. Distinct names give distinct keys, so the keys stay unique.
    static func remoteFolderHelp(_ urls: [String: String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: urls.map { ("remote:\(BranchNode.key($0.key))", "\($0.key) — \($0.value)") })
    }
}

/// A mask that fades the last `Spacing.lg` of a row to clear when `isActive`, and shows everything otherwise.
private struct TrailingFade: View {
    let isActive: Bool

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
            LinearGradient(colors: [.black, isActive ? .clear : .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: Tokens.Spacing.lg)
        }
    }
}
