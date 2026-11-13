import AppKit
import SwiftUI

/// The sidebar's STASHES section (information-architecture.md §4): newest first, `No stashes` when empty.
struct StashListSection: View {
    let rows: [StashRow]
    let isPartial: Bool
    let selectedID: ObjectID?
    let onSelect: (ObjectID) -> Void

    /// Open or closed, owned by the sidebar so the arrow keys know which rows show (#592); `nil` keeps it here.
    var expansion: Binding<Bool>?
    /// The sidebar has keyboard focus (#592): the selected row is `surface.selection`, otherwise inactive.
    var isListFocused = false

    @State private var ownExpanded = true
    private var isExpanded: Binding<Bool> { expansion ?? $ownExpanded }

    var body: some View {
        Section {
            // Rows are direct children of the sidebar's lazy stack: built only on screen (a crafted reflog can list tens of
            // thousands of entries, security review of #71, T15), and found by `scrollTo` (review of #598).
            if isExpanded.wrappedValue {
                if rows.isEmpty {
                    Text("No stashes")
                        .font(Tokens.Font.callout)
                        .foregroundStyle(Tokens.Color.textTertiary)
                        .padding(.horizontal, SidebarInset.content)
                        .frame(height: Tokens.Size.rowSidebar)
                } else {
                    if isPartial {
                        SidebarNotice(
                            symbol: "exclamationmark.triangle",
                            text: String(localized: "Some stashes could not be listed."))
                    }
                    ForEach(rows, id: \.sidebarScrollID) { row in
                        StashRowView(row: row, isSelected: row.id == selectedID, isListFocused: isListFocused)
                            .contentShape(Rectangle())
                            .onTapGesture { onSelect(row.id) }
                            .accessibilityAction { onSelect(row.id) }
                            .contextMenu { StashRowMenu(row: row, onShowChanges: { onSelect(row.id) }) }
                    }
                }
            }
        } header: {
            SidebarSectionHeader(
                title: String(localized: "STASHES", comment: "Sidebar section"), count: rows.count,
                isExpanded: isExpanded)
        }
    }
}

private struct StashRowView: View {
    let row: StashRow
    let isSelected: Bool
    /// The list has keyboard focus: the selection is `surface.selection`, otherwise `selection-inactive`.
    var isListFocused = false

    var body: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            Image(systemName: "archivebox").foregroundStyle(Tokens.Color.textTertiary).accessibilityHidden(true)
            Text(row.refName).font(Tokens.Font.monoSmall).foregroundStyle(Tokens.Color.textSecondary)
            Text(row.message).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textPrimary)
                .lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Tokens.Spacing.sm)
        .frame(height: Tokens.Size.rowSidebar)
        // One selection style for every sidebar row, and hover feedback on the others (#572).
        .background {
            if isSelected { SidebarSelectionBackground(isFocused: isListFocused) }
        }
        .hoverHighlight(.inset, isEnabled: !isSelected)
        .padding(.horizontal, SidebarInset.row)
        .help(row.message)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// S-04, one stash's contents (screens.md S-04). Read-only: no apply, pop, drop, or branch, not even a hint
/// (ADR-0011). TODO(#68): clicking the base commit selects it in the graph.
struct StashDetailView: View {
    let model: StashDetailModel
    let selectedFile: GitPath?
    let onSelectFile: (FileStat) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
                    header
                    info
                    files
                }
                .padding(Tokens.Spacing.md)
            }
            // Pinned on `surface.panel-header` like the panel's head (#578).
            PanelFooter {
                Button("Copy Ref") {
                    // Copying to the clipboard is not a repository write (ADR-0011).
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.refName, forType: .string)
                }
                .help(
                    "Copy \(model.refName). It names a different stash once stashes are added or dropped; its OID is \(model.oid)."
                )
            }
        }
    }

    /// The whole message and when it was stashed. `stash@{n}` is the panel's title already, so it is not repeated (#579).
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.sm) {
            Text(model.subject)
                .font(Tokens.Font.callout)
                .foregroundStyle(Tokens.Color.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            TimelineView(.periodic(from: .now, by: 30)) { context in
                Text(StatusBarItem.relative(model.date, now: context.date))
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Color.textTertiary)
                    .fixedSize()
            }
        }
    }

    private var info: some View {
        DetailCard {
            Grid(
                alignment: .leadingFirstTextBaseline, horizontalSpacing: Tokens.Spacing.md,
                verticalSpacing: Tokens.Spacing.xs
            ) {
                if let base = model.baseCommit { infoRow("Base commit", base, mono: true) }
                if let branch = model.branch {
                    GridRow {
                        Text("Branch").font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textTertiary)
                        HStack(spacing: Tokens.Spacing.xs) {
                            Text(branch).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textPrimary)
                                .lineLimit(2)
                            Text("(from message)").font(Tokens.Font.caption).foregroundStyle(Tokens.Color.textTertiary)
                        }
                    }
                }
                infoRow("Includes", model.includes, mono: false)
            }
        }
    }

    private func infoRow(_ label: LocalizedStringKey, _ value: String, mono: Bool) -> some View {
        GridRow {
            Text(label).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textTertiary)
            Text(value)
                .font(mono ? Tokens.Font.monoSmall : Tokens.Font.callout)
                .foregroundStyle(Tokens.Color.textPrimary)
                // Folds to a second line in a narrow panel, as S-05's rows do (#579).
                .lineLimit(2)
                .truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var files: some View {
        DetailCard {
            Text(
                "FILES (\(model.files.map { WipDetailModel.formatted($0.count) } ?? "…")\(model.isFileListPartial ? "+" : ""))"
            )
            .font(Tokens.Font.sectionHeader)
            .tracking(Tokens.Font.sectionHeaderTracking)
            .foregroundStyle(Tokens.Color.textTertiary)
            if let rows = model.files {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in fileRow(row) }
                }
                if model.hasUntrackedFiles {
                    // The same `?` badge as the rows it explains (#577).
                    Label {
                        Text("From the stash’s untracked-files commit")
                    } icon: {
                        FileKindBadge(badge: .status(letter: "?", group: .untracked))
                    }
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Color.textTertiary)
                }
            } else if let reason = model.filesUnavailable {
                Text(reason).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textSecondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func fileRow(_ row: StashDetailModel.FileRow) -> some View {
        let isSelected = selectedFile == row.file.path
        // The change kind in the neutral badge, as in S-03 (#602); files from the untracked part keep `?`.
        let badge: FileRowView.Badge =
            row.isFromUntracked
            ? .status(letter: "?", group: .untracked) : row.kindLetter.map { .neutral(letter: $0) } ?? .unknown
        return FileRowView(
            badge: badge, directory: row.directory,
            fileName: row.fileName, lineCount: row.file.lineCount, isSelectable: row.isSelectable,
            isSelected: isSelected
        )
        .contentShape(Rectangle())
        .onTapGesture { if row.isSelectable { onSelectFile(row.file) } }
        .contextMenu {
            FileRowMenu(
                worktree: nil, path: row.file.path, showDiff: { if row.isSelectable { onSelectFile(row.file) } })
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(
            selectedFile == row.file.path ? [.isButton, .isSelected] : (row.isSelectable ? .isButton : [])
        )
        .accessibilityAction { if row.isSelectable { onSelectFile(row.file) } }
    }
}

/// A stash row's menu (interaction.md §5): show and copy only. Apply, pop, and drop are never offered.
private struct StashRowMenu: View {
    let row: StashRow
    let onShowChanges: () -> Void

    @Environment(\.rowMenu) private var actions

    var body: some View {
        Button("Show Changes", action: onShowChanges)
        Divider()
        Button("Copy Ref") { actions.copy(row.refName) }
        Button("Copy SHA") { actions.copy(row.id.hex) }
    }
}

extension StashRow {
    /// The id `ForEach` and `scrollTo` share (#592).
    var sidebarScrollID: String { SidebarItem.stash(id).scrollID }
}
