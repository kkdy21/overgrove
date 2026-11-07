import AppKit
import SwiftUI

/// S-02, the focused worktree's uncommitted changes in the detail panel (screens.md S-02, art-direction.md §7).
///
/// Pick a file with a click or `↑`/`↓`; the diff viewer (S-10, #69) shows it. Nothing here changes the repository:
/// there is no staging, discard, or commit (ADR-0011).
///
/// TODO(#158): the base-branch comparison card pinned at the bottom. TODO(#67): the `Changes | Worktree` segment.
struct WipDetailView: View {
    let model: WipDetailModel
    let selectedFile: FileSelection?
    let onSelect: (FileSelection) -> Void

    @FocusState private var hasFocus: Bool

    var body: some View {
        ScrollView {
            // Lazy: thousands of rows (untracked up to the display limit, the other groups unbounded) are built only
            // as they scroll into view (security review of #66, T15).
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.md) {
                summary
                if let warning = model.warning {
                    SidebarNotice(symbol: "exclamationmark.triangle", text: warning)
                }
                content
            }
            .padding(Tokens.Spacing.md)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            HStack(spacing: Tokens.Spacing.xs) {
                Image(systemName: "folder").foregroundStyle(Tokens.Color.textTertiary).accessibilityHidden(true)
                Text(model.displayPath)
                    .lineLimit(1)
                    .truncationMode(.head)
                if let path = model.copyablePath {
                    Button {
                        // Copying to the clipboard is not a repository write (ADR-0011).
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(path, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("Copy Path")
                    .accessibilityLabel("Copy path")
                }
            }
            .font(Tokens.Font.callout)
            .foregroundStyle(Tokens.Color.textSecondary)
            if model.changedFileCount > 0 {
                Text(
                    "\(WipDetailModel.formatted(model.changedFileCount)) changed \(model.changedFileCount == 1 ? "file" : "files")"
                )
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Color.textTertiary)
                // Not shown yet: the added/removed ratio bar and `+n −m` totals need `diff --numstat` queries for the
                // focused worktree (proposed as a follow-up of #66).
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.content {
        case .changes(let groups):
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.md) {
                ForEach(groups) { group in
                    WipGroupCard(
                        group: group, selectedPath: selectedPath(in: group.group), isListFocused: hasFocus,
                        onSelect: { row in select(row) })
                }
            }
            .focusable()
            .focused($hasFocus)
            .focusEffectDisabled()
            .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                move(groups: groups, down: press.key == .downArrow)
            }
        case .clean:
            DetailState(symbol: "checkmark.circle", tint: Tokens.Color.statusOk, title: "Working tree clean")
        case .missing:
            DetailState(
                symbol: "questionmark.folder", tint: Tokens.Color.statusPrunable,
                title: "Worktree directory is missing",
                message: "Run git worktree prune in Terminal to clean up.")
        case .unavailable(let message):
            DetailState(
                symbol: "exclamationmark.triangle", tint: Tokens.Color.statusWarning, title: "Changes unavailable",
                message: message)
        }
    }

    private func selectedPath(in group: WorkingChangeGroup) -> GitPath? {
        guard let selectedFile, selectedFile.worktree == model.worktreePath, selectedFile.group == group else {
            return nil
        }
        return selectedFile.path
    }

    private func select(_ row: WipFileRow) {
        guard row.isSelectable else { return }
        onSelect(FileSelection(worktree: model.worktreePath, group: row.group, path: row.path))
    }

    /// `↑`/`↓` through every selectable file, across groups, in display order.
    private func move(groups: [WipGroupModel], down: Bool) -> KeyPress.Result {
        let rows = groups.flatMap(\.rows).filter(\.isSelectable)
        guard !rows.isEmpty else { return .ignored }
        let current = rows.firstIndex { row in
            selectedFile.map { $0.group == row.group && $0.path == row.path } ?? false
        }
        let next: Int
        if let current {
            next = min(max(current + (down ? 1 : -1), 0), rows.count - 1)
        } else {
            next = down ? 0 : rows.count - 1
        }
        select(rows[next])
        return .handled
    }
}

/// One group card (art-direction.md §7): `surface.raised`, radius 8, a 32pt head, 26pt file rows.
struct WipGroupCard: View {
    let group: WipGroupModel
    let selectedPath: GitPath?
    let isListFocused: Bool
    let onSelect: (WipFileRow) -> Void

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Tokens.Spacing.xs) {
                Image(systemName: group.group.symbol)
                    .foregroundStyle(group.group.tint)
                    .accessibilityHidden(true)
                Text(group.group.title).font(Tokens.Font.columnHeader).foregroundStyle(Tokens.Color.textPrimary)
                Text(group.countText)
                    .font(Tokens.Font.pill)
                    .foregroundStyle(Tokens.Color.textSecondary)
                    .padding(.horizontal, Tokens.Spacing.xs + Tokens.Spacing.xxs)
                    .background(Capsule().fill(Tokens.Color.surfacePanel))
                Spacer()
            }
            .padding(.horizontal, Tokens.Spacing.sm + Tokens.Spacing.xxs)
            .frame(height: Self.headerHeight)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(group.group.title), \(group.totalCount) files")
            .accessibilityAddTraits(.isHeader)

            ForEach(group.rows) { row in
                WipFileRowView(
                    row: row, isSelected: row.path == selectedPath, isListFocused: isListFocused
                )
                .contentShape(Rectangle())
                .onTapGesture { onSelect(row) }
                .accessibilityAction { onSelect(row) }
            }
            if let note = group.limitNote {
                Text(note)
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Color.textTertiary)
                    .padding(.horizontal, Tokens.Spacing.sm + Tokens.Spacing.xxs)
                    .frame(height: Tokens.Size.rowFile)
            }
        }
        .padding(.bottom, Tokens.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous).fill(Tokens.Color.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                .strokeBorder(Tokens.Color.borderSeparator, lineWidth: 1))
    }

    /// art-direction.md §7: card head 32, radius 8. No tokens for them.
    static let headerHeight: CGFloat = 32
    static let cornerRadius: CGFloat = 8
}

/// A file row: the change-kind badge, the path (directory dimmed, name emphasized), and a `submodule` tag.
struct WipFileRowView: View {
    let row: WipFileRow
    let isSelected: Bool
    let isListFocused: Bool

    var body: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            Text(row.kindLetter)
                .font(Tokens.Font.monoSmall)
                .foregroundStyle(row.group.onTint)
                .frame(width: Self.badgeSize, height: Self.badgeSize)
                .background(RoundedRectangle(cornerRadius: Tokens.Radius.sm).fill(row.group.tint))
                .accessibilityHidden(true)
            (Text(row.directory).foregroundStyle(Tokens.Color.textTertiary)
                + Text(row.fileName).foregroundStyle(
                    row.isSelectable ? Tokens.Color.textPrimary : Tokens.Color.textTertiary
                ).fontWeight(.medium))
                .font(Tokens.Font.callout)
                .lineLimit(1)
                .truncationMode(.head)
            if row.isSubmodule {
                Text("submodule")
                    .font(Tokens.Font.pill)
                    .foregroundStyle(Tokens.Color.textSecondary)
                    .padding(.horizontal, Tokens.Spacing.xs)
                    .background(Capsule().strokeBorder(Tokens.Color.borderSeparator))
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.Spacing.sm + Tokens.Spacing.xxs)
        .frame(height: Tokens.Size.rowFile)
        .background {
            if isSelected {
                let shape = RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous)
                // `surface.selection-inactive` equals `surface.raised` in light mode, so on a card the inactive
                // selection also gets an outline to stay visible.
                shape
                    .fill(isListFocused ? Tokens.Color.surfaceSelection : Tokens.Color.surfaceSelectionInactive)
                    .overlay(shape.strokeBorder(isListFocused ? Color.clear : Tokens.Color.borderStrong))
                    .padding(.horizontal, Tokens.Spacing.xs)
            }
        }
        .help(row.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(row.isSelectable ? (isSelected ? [.isButton, .isSelected] : .isButton) : [])
    }

    /// screens.md S-02: a 16pt square badge. No size token for it.
    static let badgeSize: CGFloat = 16
}

/// A whole-panel state: clean, missing folder, or unavailable status.
struct DetailState: View {
    let symbol: String
    let tint: Color
    let title: String
    var message: String?

    var body: some View {
        VStack(spacing: Tokens.Spacing.sm) {
            Image(systemName: symbol).font(Tokens.Font.title).foregroundStyle(tint).accessibilityHidden(true)
            Text(title).font(Tokens.Font.headline).foregroundStyle(Tokens.Color.textPrimary)
            if let message {
                Text(message)
                    .font(Tokens.Font.callout)
                    .foregroundStyle(Tokens.Color.textSecondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, Tokens.Spacing.xxl)
        .accessibilityElement(children: .combine)
    }
}

extension WorkingChangeGroup {
    /// Group status colour (iconography.md §5.1); the badge is filled with it.
    var tint: Color {
        switch self {
        case .conflicted: Tokens.Color.statusConflicted
        case .staged: Tokens.Color.statusStaged
        case .unstaged: Tokens.Color.statusUnstaged
        case .untracked: Tokens.Color.statusUntracked
        }
    }

    /// Letters on a badge filled with `tint` (`on-status.*`).
    var onTint: Color {
        switch self {
        case .conflicted: Tokens.Color.onStatusConflicted
        case .staged: Tokens.Color.onStatusStaged
        case .unstaged: Tokens.Color.onStatusUnstaged
        case .untracked: Tokens.Color.onStatusUntracked
        }
    }
}
