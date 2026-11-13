import SwiftUI

/// The sidebar's LOCAL or REMOTE section (information-architecture.md §4, art-direction.md §6): one-line rows,
/// folders (`feat/`) and remotes that open and close, the checked-out `tree` mark, ahead/behind, and `gone`.
///
/// A row's menu shows its tip in the graph and copies its names (#73).
struct BranchListSection: View {
    let title: String
    let count: Int
    let nodes: [BranchNode]
    var warning: String?
    /// Tooltips for folder rows by id; REMOTE uses it for each remote's URL (Settings › Show full remote URLs, #86).
    var folderHelp: [String: String] = [:]
    /// The sidebar filter is on (#74): every folder shows its matches, and an empty list says so.
    var isFiltered = false
    /// The commit the detail panel shows, to keep the chosen row highlighted only while it is still selected (#572).
    var selectedCommit: ObjectID?

    /// Open or closed, and the open folders, owned by the sidebar so the arrow keys know which rows show (#592);
    /// `nil` keeps them here (previews, render tests).
    var expansion: Binding<Bool>?
    var folders: Binding<Set<String>>?
    /// The sidebar has keyboard focus (#592): the selected row is `surface.selection`, otherwise inactive.
    var isListFocused = false
    /// Owned by the sidebar (#592): the row chosen last, and what choosing a row does. Without `onChoose` the section
    /// keeps the choice itself and shows the tip (previews, render tests).
    var chosenRef: String?
    var onChoose: ((BranchRow) -> Void)?

    @State private var ownExpanded = true
    @State private var ownFolders: Set<String> = []
    /// The row chosen last: several branches can share a tip, and only the chosen one is highlighted (as in TAGS).
    @State private var ownChosenID: String?

    private var isExpanded: Binding<Bool> { expansion ?? $ownExpanded }
    private var openFolders: Binding<Set<String>> { folders ?? $ownFolders }
    private var chosenID: String? { onChoose == nil ? ownChosenID : chosenRef }
    @Environment(\.rowMenu) private var actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// `title` stays `LOCAL` or `REMOTE` (it picks the empty text and the relative dates); only the header is localized.
    private var displayTitle: String {
        switch title {
        case "LOCAL": String(localized: "LOCAL", comment: "Sidebar section")
        case "REMOTE": String(localized: "REMOTE", comment: "Sidebar section")
        default: title
        }
    }

    var body: some View {
        Section {
            // The rows are direct children of the sidebar's lazy stack, not a stack of their own: `scrollTo` can only
            // find a row the outer stack knows, even one it has not built yet (`⌘↓` past hundreds of rows, review of
            // #598).
            if isExpanded.wrappedValue {
                if let warning {
                    SidebarNotice(symbol: "exclamationmark.triangle", text: warning)
                }
                if nodes.isEmpty {
                    Text(
                        isFiltered
                            ? "No matching branches"
                            : title == "LOCAL"
                                ? "No local branches"
                                : "No remote branches"
                                    as LocalizedStringKey
                    )
                    .font(Tokens.Font.callout)
                    .foregroundStyle(Tokens.Color.textTertiary)
                    .padding(.horizontal, SidebarInset.content)
                    .frame(height: Tokens.Size.rowSidebar)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .sidebarOpaque()
                }
                // Identified by the arrow keys' scroll id (folders flattened into the visible rows).
                ForEach(visibleRows, id: \.node.sidebarScrollID) { item in
                    switch item.node {
                    case .branch(let row): branchRow(row, depth: item.depth).sidebarOpaque()
                    case .folder(let id, let name, let count, _):
                        folderRow(id: id, name: name, count: count, depth: item.depth).sidebarOpaque()
                    }
                }
            }
        } header: {
            SidebarSectionHeader(title: displayTitle, count: count, isExpanded: isExpanded)
        }
    }

    private var visibleRows: [(node: BranchNode, depth: Int)] {
        BranchListModel.visibleRows(
            nodes, open: isFiltered ? SidebarFilter.folderIDs(nodes) : openFolders.wrappedValue)
    }

    @ViewBuilder
    private func branchRow(_ row: BranchRow, depth: Int) -> some View {
        let isSelected = Self.isHighlighted(row, chosenID: chosenID, selectedCommit: selectedCommit)
        Group {
            if title == "REMOTE" {
                // Remote rows show the tip's relative date; one timer per built row, and the stack builds only the
                // rows on screen.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    BranchRowView(
                        row: row, depth: depth, now: context.date, isSelected: isSelected, isListFocused: isListFocused)
                }
            } else {
                BranchRowView(row: row, depth: depth, now: nil, isSelected: isSelected, isListFocused: isListFocused)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { choose(row) }
        .accessibilityAction { choose(row) }
    }

    /// A row is highlighted while it is the one chosen last and its tip is still the selected commit: several
    /// branches can share a tip, and choosing something else in the graph drops the highlight.
    nonisolated static func isHighlighted(_ row: BranchRow, chosenID: String?, selectedCommit: ObjectID?) -> Bool {
        row.id == chosenID && row.tip != nil && row.tip == selectedCommit
    }

    /// Clicking a branch row selects its tip commit, like Show in Graph (interaction.md §2, #572). A branch of a tree
    /// or blob has no tip in the graph, so it selects nothing.
    private func choose(_ row: BranchRow) {
        guard let tip = row.tip else { return }
        if let onChoose { return onChoose(row) }
        ownChosenID = row.id
        actions.showCommit(tip)
    }

    private func folderRow(id: String, name: String, count: Int, depth: Int) -> some View {
        let isOpen = openFolders.wrappedValue.contains(id)
        return Button {
            // `motion.duration-standard` for disclosures, at once under Reduce Motion (#572).
            withMotion(.standard, reduceMotion: reduceMotion) {
                if isOpen { openFolders.wrappedValue.remove(id) } else { openFolders.wrappedValue.insert(id) }
            }
        } label: {
            HStack(spacing: Tokens.Spacing.xs) {
                BranchTreeLead(
                    depth: depth, disclosure: isOpen ? .open : .closed,
                    symbol: depth == 0 && title == "REMOTE" ? "globe" : "folder")
                Text(name).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textPrimary)
                Spacer()
                Text(WorktreeListModel.badgeText(count))
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Color.textTertiary)
            }
            .padding(.leading, Tokens.Spacing.sm)
            .padding(.trailing, Tokens.Spacing.sm)
            .frame(height: Tokens.Size.rowSidebar)
            .hoverHighlight(.inset)
            .padding(.horizontal, SidebarInset.row)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(folderHelp[id] ?? "")
        .accessibilityLabel(name + ", \(count) branches")
        .accessibilityValue(isOpen ? "expanded" : "collapsed")
    }
}

/// The start of a LOCAL or REMOTE tree row (#615): the depth's indent, a disclosure slot (the chevron on a folder,
/// empty on a branch), and an icon slot, all fixed widths. Folder and branch rows of one depth so put their icons and
/// names on the same x, and one level is the disclosure slot and its gap, so a child's disclosure slot starts under
/// its folder's icon, as in Finder and Xcode outlines.
struct BranchTreeLead: View {
    enum Disclosure { case none, closed, open }

    let depth: Int
    let disclosure: Disclosure
    let symbol: String

    static let disclosureWidth = Tokens.Spacing.md
    static let iconWidth = Tokens.Spacing.lg
    /// One level: the disclosure slot and the gap after it.
    static let levelIndent = disclosureWidth + Tokens.Spacing.xs

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            // The slot keeps its width even when empty (a branch row): an empty `Group` would take none.
            Color.clear
                .frame(width: Self.disclosureWidth, height: 1)
                .overlay {
                    if disclosure != .none {
                        Image(systemName: "chevron.right")
                            .rotationEffect(.degrees(disclosure == .open ? 90 : 0))
                            .font(Tokens.Font.caption)
                            .foregroundStyle(Tokens.Color.textTertiary)
                    }
                }
            Image(systemName: symbol)
                .foregroundStyle(Tokens.Color.textTertiary)
                .frame(width: Self.iconWidth)
                .accessibilityHidden(true)
        }
        .padding(.leading, CGFloat(depth) * Self.levelIndent)
    }
}

private struct BranchRowView: View {
    let row: BranchRow
    let depth: Int
    /// Set for remote rows, which show the tip's relative date.
    let now: Date?
    var isSelected = false
    var isListFocused = false

    @Environment(\.pullRequestBadges) private var pullRequests

    /// Only local branches are linked (ADR-0023 §4).
    private var pullRequest: PullRequestBadge? { pullRequests.badge(forBranch: row.id) }

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            BranchTreeLead(depth: depth, disclosure: .none, symbol: "arrow.triangle.branch")
            Text(row.name)
                .font(row.isDefault ? Tokens.Font.bodyEmphasized : Tokens.Font.callout)
                .foregroundStyle(Tokens.Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Tokens.Spacing.xs)
            if let pullRequest { PullRequestPill(badge: pullRequest) }
            if let number = row.issueNumber { IssueNumberBadge(number: number) }
            if row.isUpstreamGone {
                Text("gone").font(Tokens.Font.pill).foregroundStyle(Tokens.Color.statusPrunable)
            }
            if row.ahead > 0 {
                Text("↑" + WorktreeListModel.badgeText(row.ahead)).font(Tokens.Font.pill)
                    .foregroundStyle(Tokens.Color.statusAhead)
            }
            if row.behind > 0 {
                Text("↓" + WorktreeListModel.badgeText(row.behind)).font(Tokens.Font.pill)
                    .foregroundStyle(Tokens.Color.statusBehind)
            }
            if let now, let date = row.date {
                Text(StatusBarItem.relative(date, now: now))
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Color.textTertiary)
            }
            if row.isCheckedOut {
                Image(systemName: "tree").foregroundStyle(Tokens.Color.textSecondary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, Tokens.Spacing.sm)
        .padding(.trailing, Tokens.Spacing.sm)
        .frame(height: Tokens.Size.rowSidebar)
        // The same selection and hover as every sidebar row (#572).
        .background {
            if isSelected { SidebarSelectionBackground(isFocused: isListFocused) }
        }
        .hoverHighlight(.inset, isEnabled: !isSelected)
        .padding(.horizontal, SidebarInset.row)
        .help(row.help)
        .contextMenu { BranchRowMenu(row: row) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel + (pullRequest.map { ", " + $0.accessibilityText } ?? ""))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .issueBadgeAction(row.issueNumber)
    }
}

/// A branch row's menu (interaction.md §5): show and copy only.
private struct BranchRowMenu: View {
    let row: BranchRow

    @Environment(\.rowMenu) private var actions

    var body: some View {
        Button("Show in Graph") { if let tip = row.tip { actions.showCommit(tip) } }
            .disabled(row.tip == nil)
        Divider()
        Button("Copy Name") { actions.copy(row.fullDisplayName) }
        Button("Copy Upstream Name") { if let upstream = row.upstreamName { actions.copy(upstream) } }
            .disabled(row.upstreamName == nil)
        Divider()
        let url = row.gitHubTarget.flatMap { actions.gitHubBranchURL($0) }
        Button("Open on GitHub") { if let url { actions.openInBrowser(url) } }
            .disabled(url == nil)
    }
}

extension BranchNode {
    /// The id `ForEach` and `scrollTo` share: a branch row with a tip uses its `SidebarItem` scroll id.
    var sidebarScrollID: String {
        switch self {
        case .branch(let row): row.tip.map { SidebarItem.branch(id: row.id, tip: $0).scrollID } ?? id
        case .folder: id
        }
    }
}
