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

    /// Open or closed, owned by the sidebar so the arrow keys know which rows show (#592); `nil` keeps it here.
    var expansion: Binding<Bool>?
    /// The sidebar has keyboard focus (#592): the selected row is `surface.selection`, otherwise inactive.
    var isListFocused = false
    /// Owned by the sidebar (#592): the row chosen last, and what choosing a row does. Without `onChoose` the section
    /// keeps the choice itself and shows the commit (previews, render tests).
    var chosenRef: String?
    var onChoose: ((TagRow) -> Void)?

    @Environment(\.rowMenu) private var actions
    /// Repositories often have hundreds of tags, so the section starts closed (§4.1).
    @State private var ownExpanded: Bool
    /// The row chosen last: several tags can name one commit, and only the chosen one is highlighted.
    @State private var ownChosenID: String?

    private var isExpanded: Binding<Bool> { expansion ?? $ownExpanded }
    private var chosenID: String? { onChoose == nil ? ownChosenID : chosenRef }

    /// - Parameter isInitiallyExpanded: `false` in the app (§4.1); previews and render tests open it.
    init(
        model: TagListModel, query: String? = nil, selectedCommit: ObjectID? = nil, isInitiallyExpanded: Bool = false,
        expansion: Binding<Bool>? = nil, isListFocused: Bool = false, chosenRef: String? = nil,
        onChoose: ((TagRow) -> Void)? = nil
    ) {
        self.model = model
        self.query = query
        self.selectedCommit = selectedCommit
        self.expansion = expansion
        self.isListFocused = isListFocused
        self.chosenRef = chosenRef
        self.onChoose = onChoose
        _ownExpanded = State(initialValue: isInitiallyExpanded)
    }

    var body: some View {
        Section {
            // Rows are direct children of the sidebar's lazy stack so `scrollTo` finds them (review of #598).
            if isExpanded.wrappedValue || query != nil {
                let visible = model.visible(query: query)
                if visible.rows.isEmpty {
                    Text(query == nil ? "No tags" : "No matching tags" as LocalizedStringKey)
                        .font(Tokens.Font.callout)
                        .foregroundStyle(Tokens.Color.textTertiary)
                        .padding(.horizontal, SidebarInset.content)
                        .frame(height: Tokens.Size.rowSidebar)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .sidebarOpaque()
                }
                ForEach(visible.rows, id: \.sidebarScrollID) { row in
                    // One timer per built row for the relative date; the stack builds only the rows on screen.
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        TagRowView(
                            row: row, now: context.date,
                            isSelected: row.id == chosenID && row.commit != nil && row.commit == selectedCommit,
                            isListFocused: isListFocused)
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { choose(row) }
                    .accessibilityAction { choose(row) }
                    .contextMenu { TagRowMenu(row: row, onShow: { choose(row) }) }
                    .sidebarOpaque()
                }
                if visible.hidden > 0 {
                    Text("\(WorktreeListModel.badgeText(visible.hidden)) more tags — filter to find one")
                        .font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Color.textTertiary)
                        .padding(.horizontal, SidebarInset.content)
                        .frame(height: Tokens.Size.rowSidebar)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .sidebarOpaque()
                }
            }
        } header: {
            SidebarSectionHeader(
                title: String(localized: "TAGS", comment: "Sidebar section"), count: model.count,
                isExpanded: isExpanded)
        }
    }

    /// A tag of a tree or blob selects nothing: the graph has no row for it, and the detail panel keeps what it shows
    /// (#432).
    private func choose(_ row: TagRow) {
        guard let commit = row.commit else { return }
        if let onChoose { return onChoose(row) }
        ownChosenID = row.id
        actions.showCommit(commit)
    }
}

private struct TagRowView: View {
    let row: TagRow
    let now: Date
    let isSelected: Bool
    /// The list has keyboard focus: the selection is `surface.selection`, otherwise `selection-inactive`.
    var isListFocused = false

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
        // One selection style for every sidebar row, and hover feedback on the others (#572).
        .background {
            if isSelected { SidebarSelectionBackground(isFocused: isListFocused) }
        }
        .hoverHighlight(.inset, isEnabled: !isSelected)
        .padding(.horizontal, SidebarInset.row)
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
        Button("Show in Graph", action: onShow).disabled(row.commit == nil)
        Divider()
        Button("Copy Tag Name") { actions.copy(row.name) }
        Button("Copy SHA") { actions.copy(row.object.hex) }
    }
}

extension TagRow {
    /// The id `ForEach` and `scrollTo` share (#592).
    var sidebarScrollID: String { commit.map { SidebarItem.tag(id: id, commit: $0).scrollID } ?? id }
}
