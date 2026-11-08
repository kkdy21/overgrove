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

    @State private var isExpanded = true
    @State private var openFolders: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarSectionHeader(title: title, count: count, isExpanded: $isExpanded)
            if isExpanded {
                if let warning {
                    SidebarNotice(symbol: "exclamationmark.triangle", text: warning)
                }
                if nodes.isEmpty {
                    Text(
                        isFiltered
                            ? "No matching branches" : title == "LOCAL" ? "No local branches" : "No remote branches"
                    )
                    .font(Tokens.Font.callout)
                    .foregroundStyle(Tokens.Color.textTertiary)
                    .padding(.horizontal, Tokens.Spacing.md)
                    .frame(height: Tokens.Size.rowSidebar)
                }
                // One lazy stack over the visible rows (folders flattened), one timer for every relative date.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    let rows = BranchListModel.visibleRows(
                        nodes, open: isFiltered ? SidebarFilter.folderIDs(nodes) : openFolders)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows, id: \.node.id) { item in
                            switch item.node {
                            case .branch(let row):
                                BranchRowView(row: row, depth: item.depth, now: title == "REMOTE" ? context.date : nil)
                            case .folder(let id, let name, let count, _):
                                folderRow(id: id, name: name, count: count, depth: item.depth)
                            }
                        }
                    }
                }
            }
        }
    }

    private func folderRow(id: String, name: String, count: Int, depth: Int) -> some View {
        let isOpen = openFolders.contains(id)
        return Button {
            if isOpen { openFolders.remove(id) } else { openFolders.insert(id) }
        } label: {
            HStack(spacing: Tokens.Spacing.xs) {
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isOpen ? 90 : 0))
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Color.textTertiary)
                Image(systemName: depth == 0 && title == "REMOTE" ? "globe" : "folder")
                    .foregroundStyle(Tokens.Color.textTertiary)
                Text(name).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textPrimary)
                Spacer()
                Text(WorktreeListModel.badgeText(count))
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Color.textTertiary)
            }
            .padding(.leading, Tokens.Spacing.md + CGFloat(depth) * Tokens.Spacing.lg)
            .padding(.trailing, Tokens.Spacing.md)
            .frame(height: Tokens.Size.rowSidebar)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(folderHelp[id] ?? "")
        .accessibilityLabel(name + ", \(count) branches")
        .accessibilityValue(isOpen ? "expanded" : "collapsed")
    }
}

private struct BranchRowView: View {
    let row: BranchRow
    let depth: Int
    /// Set for remote rows, which show the tip's relative date.
    let now: Date?

    @Environment(\.pullRequestBadges) private var pullRequests

    /// Only local branches are linked (ADR-0023 §4).
    private var pullRequest: PullRequestBadge? { pullRequests.badge(forBranch: row.id) }

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Image(systemName: "arrow.triangle.branch").foregroundStyle(Tokens.Color.textTertiary)
                .accessibilityHidden(true)
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
        .padding(.leading, Tokens.Spacing.md + CGFloat(depth) * Tokens.Spacing.lg)
        .padding(.trailing, Tokens.Spacing.md)
        .frame(height: Tokens.Size.rowSidebar)
        .help(row.help)
        .contextMenu { BranchRowMenu(row: row) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel + (pullRequest.map { ", " + $0.accessibilityText } ?? ""))
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
