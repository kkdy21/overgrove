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

/// A non-interactive stand-in for a field that a later feature makes live (the sidebar filter).
struct PlaceholderField: View {
    let symbol: String
    let prompt: String
    let shortcut: String

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Image(systemName: symbol).accessibilityHidden(true)
            Text(prompt)
            Spacer(minLength: Tokens.Spacing.sm)
            Text(shortcut).font(Tokens.Font.monoSmall)
        }
        .font(Tokens.Font.callout)
        .foregroundStyle(Tokens.Color.textTertiary)
        .padding(.horizontal, Tokens.Spacing.sm)
        .frame(height: Tokens.Size.rowSidebar)
        .background(Tokens.Color.surfaceControl, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(prompt)
        .accessibilityAddTraits(.isStaticText)
    }
}

// MARK: - The three panels of S-01

/// Sidebar: filter header, then WORKTREES / LOCAL / REMOTE / STASHES / ISSUES.
struct SidebarPanel: View {
    let hasRepository: Bool
    var worktreeStatus: WorktreeListStatus = .idle
    var worktreeModel: WorktreeListModel?
    var selectedWorktree: GitPath?
    var onSelectWorktree: (GitPath) -> Void = { _ in }
    var canCompareWorktree: (GitPath) -> Bool = { _ in false }
    var onCompareWorktree: (GitPath) -> Void = { _ in }

    var body: some View {
        PanelSection {
            // TODO(#74): filter the sidebar.
            PlaceholderField(symbol: "magnifyingglass", prompt: "Filter", shortcut: "⌥⌘F")
        } content: {
            if hasRepository {
                // TODO(#72): LOCAL and REMOTE; TODO(#71): STASHES; TODO(#81): ISSUES.
                ScrollView {
                    WorktreeListSection(
                        status: worktreeStatus, model: worktreeModel, selectedPath: selectedWorktree,
                        onSelect: onSelectWorktree, canCompare: canCompareWorktree,
                        onCompare: onCompareWorktree)
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
    /// A file picked in the detail panel covers the graph with its diff (S-10, #232).
    var diff: (title: String, source: String, state: DiffLoadState)?
    var onShowGraph: () -> Void = {}

    /// S-11 covers the graph while a comparison is open (#158).
    var comparison: ComparisonCenterView?

    var body: some View {
        if let comparison {
            comparison
        } else if let diff {
            DiffViewerView(title: diff.title, sourceLabel: diff.source, state: diff.state, onBack: onShowGraph)
        } else {
            graph
        }
    }

    private var graph: some View {
        PanelSection {
            Image(systemName: "person.2").foregroundStyle(Tokens.Color.textSecondary).accessibilityHidden(true)
            Text("Commits").font(Tokens.Font.headline).foregroundStyle(Tokens.Color.textPrimary)
        } content: {
            switch graphStore?.status {
            case .loaded?:
                if let graphStore { GraphView(store: graphStore) }
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
    var onShowChanges: () -> Void = {}
    var onShowWorktree: () -> Void = {}
    /// S-11's lists while a comparison is open (#158).
    var comparisonList: ComparisonListView?
    /// S-05's `Compare with Base…` (#158); `nil` disables it.
    var onCompare: (() -> Void)?

    var body: some View {
        PanelSection {
            Image(systemName: "tree.fill").foregroundStyle(Tokens.Color.textSecondary).accessibilityHidden(true)
            Text(wipModel?.title ?? worktreeModel?.title ?? focusedWorktree?.title ?? "No selection")
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
            } else if let worktreeModel {
                WorktreeDetailView(model: worktreeModel, onCompare: onCompare)
            } else if let wipModel {
                WipDetailView(model: wipModel, selectedFile: selectedFile, onSelect: onSelectFile)
            } else if worktreeStatus == .loading {
                ProgressView().controlSize(.small)
            } else {
                PanelEmptyState(
                    symbol: "doc.text.magnifyingglass", title: "Details",
                    message: "Changes in the focused worktree or the selected commit appear here.")
            }
        }
    }
}
