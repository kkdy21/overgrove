import AppKit
import SwiftUI

/// The sidebar's STASHES section (information-architecture.md §4): newest first, `No stashes` when empty.
struct StashListSection: View {
    let rows: [StashRow]
    let isPartial: Bool
    let selectedID: ObjectID?
    let onSelect: (ObjectID) -> Void

    @State private var isExpanded = true
    @FocusState private var hasFocus: Bool

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 0) {
                if isExpanded {
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
                        // Lazy: a crafted reflog can list tens of thousands of entries (security review of #71, T15).
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows) { row in
                                StashRowView(row: row, isSelected: row.id == selectedID, isListFocused: hasFocus)
                                    .contentShape(Rectangle())
                                    .onTapGesture {
                                        hasFocus = true
                                        onSelect(row.id)
                                    }
                                    .accessibilityAction { onSelect(row.id) }
                                    .contextMenu { StashRowMenu(row: row, onShowChanges: { onSelect(row.id) }) }
                            }
                        }
                        // Takes keyboard focus when a row is clicked, so the selection shows as focused like WORKTREES
                        // and ISSUES (interaction.md §1.2, #572).
                        .focusable(!rows.isEmpty)
                        .focused($hasFocus)
                        .focusEffectDisabled()
                    }
                }
            }
        } header: {
            SidebarSectionHeader(
                title: String(localized: "STASHES", comment: "Sidebar section"), count: rows.count,
                isExpanded: $isExpanded)
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
            Tokens.Color.borderSeparator.frame(height: 1)
            HStack {
                Button("Copy Ref") {
                    // Copying to the clipboard is not a repository write (ADR-0011).
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.refName, forType: .string)
                }
                .help(
                    "Copy \(model.refName). It names a different stash once stashes are added or dropped; its OID is \(model.oid)."
                )
                Spacer()
            }
            .padding(Tokens.Spacing.sm + Tokens.Spacing.xxs)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            HStack {
                Text(model.refName).font(Tokens.Font.headline).foregroundStyle(Tokens.Color.textPrimary)
                Spacer()
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(StatusBarItem.relative(model.date, now: context.date))
                        .font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Color.textTertiary)
                }
            }
            Text(model.subject)
                .font(Tokens.Font.callout)
                .foregroundStyle(Tokens.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
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
                .lineLimit(1)
                .truncationMode(.tail)
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
                    Label("From the stash’s untracked-files commit", systemImage: "questionmark.circle")
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
        HStack(spacing: Tokens.Spacing.sm) {
            (Text(row.directory).foregroundStyle(Tokens.Color.textTertiary)
                + Text(row.fileName).foregroundStyle(Tokens.Color.textPrimary).fontWeight(.medium))
                .font(Tokens.Font.callout)
                .lineLimit(1)
                .truncationMode(.head)
            if row.isFromUntracked {
                Image(systemName: "questionmark.circle").foregroundStyle(Tokens.Color.statusUntracked)
                    .accessibilityLabel("from untracked files")
            }
            Spacer(minLength: Tokens.Spacing.xs)
            if let change = row.lineChange {
                Text(change).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.textSecondary)
            }
        }
        .padding(.vertical, Tokens.Spacing.xxs)
        .padding(.horizontal, Tokens.Spacing.xs)
        .background {
            if selectedFile == row.file.path {
                RoundedRectangle(cornerRadius: Tokens.Radius.md).fill(Tokens.Color.surfaceSelection)
            }
        }
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
