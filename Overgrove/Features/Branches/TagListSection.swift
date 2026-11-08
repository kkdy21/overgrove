import SwiftUI

/// The sidebar's TAGS section (information-architecture.md §4.5, #377): newest first, collapsed at first, at most
/// `TagListModel.maximumRows` rows. Choosing a row selects the commit the tag points to, like Show in Graph on a branch;
/// the focused worktree stays (§2.2). Show and copy only.
struct TagListSection: View {
    let model: TagListModel
    /// The sidebar filter (#74); while it is on, the section opens so matches show.
    var query: String?
    /// The commit the detail panel shows, to keep the chosen row highlighted only while it is still selected.
    var selectedCommit: ObjectID?

    @Environment(\.rowMenu) private var actions
    /// Repositories often have hundreds of tags, so the section starts closed (§4.1).
    @State private var isExpanded = false
    /// The row chosen last: several tags can name one commit, and only the chosen one is highlighted.
    @State private var chosenID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarSectionHeader(title: "TAGS", count: model.count, isExpanded: $isExpanded)
            if isExpanded || query != nil {
                let visible = model.visible(query: query)
                if visible.rows.isEmpty {
                    Text(query == nil ? "No tags" : "No matching tags")
                        .font(Tokens.Font.callout)
                        .foregroundStyle(Tokens.Color.textTertiary)
                        .padding(.horizontal, Tokens.Spacing.md)
                        .frame(height: Tokens.Size.rowSidebar)
                }
                // One lazy stack and one timer for every relative date.
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visible.rows) { row in
                            TagRowView(
                                row: row, now: context.date,
                                isSelected: row.id == chosenID && row.commit == selectedCommit
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { choose(row) }
                            .accessibilityAction { choose(row) }
                            .contextMenu { TagRowMenu(row: row, onShow: { choose(row) }) }
                        }
                    }
                }
                if visible.hidden > 0 {
                    Text("\(WorktreeListModel.badgeText(visible.hidden)) more tags — filter to find one")
                        .font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Color.textTertiary)
                        .padding(.horizontal, Tokens.Spacing.md)
                        .frame(height: Tokens.Size.rowSidebar)
                }
            }
        }
    }

    private func choose(_ row: TagRow) {
        chosenID = row.id
        actions.showCommit(row.commit)
    }
}

private struct TagRowView: View {
    let row: TagRow
    let now: Date
    let isSelected: Bool

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Image(systemName: "tag").foregroundStyle(Tokens.Color.textTertiary).accessibilityHidden(true)
            Text(row.name)
                .font(Tokens.Font.callout)
                .foregroundStyle(Tokens.Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Tokens.Spacing.xs)
            if row.hasDetachedWorktree {
                Image(systemName: "tree").foregroundStyle(Tokens.Color.textSecondary).accessibilityHidden(true)
            }
            if let date = row.date {
                Text(StatusBarItem.relative(date, now: now))
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Color.textTertiary)
            }
        }
        .padding(.horizontal, Tokens.Spacing.sm)
        .frame(height: Tokens.Size.rowSidebar)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous).fill(Tokens.Color.surfaceSelection)
            }
        }
        .padding(.horizontal, Tokens.Spacing.xs + Tokens.Spacing.xxs)
        .help(row.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            row.date.map { row.accessibilityLabel + ", " + StatusBarItem.relative($0, now: now) }
                ?? row.accessibilityLabel
        )
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// A tag row's menu (interaction.md §5): show and copy only.
private struct TagRowMenu: View {
    let row: TagRow
    let onShow: () -> Void

    @Environment(\.rowMenu) private var actions

    var body: some View {
        Button("Show in Graph", action: onShow)
        Divider()
        Button("Copy Tag Name") { actions.copy(row.name) }
        Button("Copy SHA") { actions.copy(row.commit.hex) }
    }
}
