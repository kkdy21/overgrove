import SwiftUI

/// S-12's center area (#388, screens.md S-12): `Compare base → target`, `⇄`, the summary, and the picked file's patch
/// (S-10's viewer). It covers the graph until `‹ Graph` or `⎋`. Read-only.
struct CommitComparisonCenterView: View {
    let session: CommitComparisonSession
    let model: CommitComparisonModel
    let onBack: () -> Void
    let onSwap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader {
                Button(action: onBack) {
                    Label("Graph", systemImage: "chevron.left")
                }
                .hoverButtonStyle()
                // `⎋` is handled once, by the window (`AppState.escape`, #633).
                .toolTip(String(localized: "Back to the graph (⎋)"))
                Text("Compare").font(Tokens.Font.headline).foregroundStyle(Tokens.Color.textPrimary)
                Text(model.title).font(Tokens.Font.mono).foregroundStyle(Tokens.Color.textSecondary)
                Button(action: onSwap) {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .hoverButtonStyle()
                .toolTip(String(localized: "Swap base and target"))
                .accessibilityLabel("Swap base and target")
                Spacer(minLength: Tokens.Spacing.sm)
            }
            summary
            Tokens.Color.borderSeparator.frame(height: 1)
            content.frame(maxWidth: .infinity, maxHeight: .infinity).fadeIn(on: model.state.phase)
        }
    }

    @ViewBuilder
    private var summary: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            if case .loading(let text) = model.state {
                ProgressView().controlSize(.small)
                Text(text)
            } else if let summary = model.summary {
                Text(summary)
            }
            Spacer()
        }
        .font(Tokens.Font.callout)
        .foregroundStyle(Tokens.Color.textSecondary)
        .padding(.horizontal, Tokens.Spacing.md)
        .frame(height: Tokens.Size.rowSidebar)
    }

    @ViewBuilder
    private var content: some View {
        switch model.state {
        case .loading:
            Color.clear
        case .noChanges(let text):
            DetailState(symbol: "checkmark.circle", tint: Tokens.Color.statusOk, title: text)
        case .failed(let message):
            DetailState(symbol: "exclamationmark.triangle", tint: Tokens.Color.statusWarning, title: message)
        case .loaded:
            if let file = session.selectedFile, let patch = session.patch {
                DiffViewerView(
                    title: PathValidator.displayable(file.display), sourceLabel: patchSource, state: patch,
                    onBack: onBack, showsBackButton: false)
            } else {
                PanelEmptyState(
                    symbol: "doc.text", title: String(localized: "Select a file"),
                    message: String(
                        localized:
                            "Pick a file in the list to see how it changed from \(model.base.shortSHA) to \(model.target.shortSHA)."
                    ))
            }
        }
    }

    private var patchSource: String {
        guard case .loaded(let document) = session.patch else { return "" }
        return document.source.label + (document.source.kindLetter.isEmpty ? "" : " · \(document.source.kindLetter)")
    }
}

/// S-12's detail panel: BASE, TARGET, COMMITS (#389), and FILES CHANGED (screens.md S-12).
struct CommitComparisonListView: View {
    let session: CommitComparisonSession
    let model: CommitComparisonModel
    let onSelectFile: (FileStat) -> Void
    let onShowAll: () -> Void
    let onShowCommit: (ObjectID) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.md) {
                DetailCard {
                    sectionTitle("BASE")
                    commitRow(model.base)
                    sectionTitle("TARGET")
                    commitRow(model.target)
                }
                // Even two commits with the same tree can have commits between them.
                commits
                if case .loaded = model.state { files }
                if case .noChanges(let text) = model.state {
                    Text(text).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textSecondary)
                }
            }
            .padding(Tokens.Spacing.md)
        }
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(Tokens.Font.sectionHeader)
            .tracking(Tokens.Font.sectionHeaderTracking)
            .foregroundStyle(Tokens.Color.textTertiary)
    }

    private func commitRow(_ row: CommitComparisonModel.CommitRow) -> some View {
        HStack(spacing: Tokens.Spacing.sm) {
            // Avatar, short SHA, subject, AI badge (screens.md S-12, #660), as S-03 and S-09 show the author.
            GraphChipAvatar(initials: row.initials, avatarIndex: row.avatarIndex)
            Text(row.shortSHA).font(Tokens.Font.monoSmall).foregroundStyle(Tokens.Color.textTertiary)
            Text(row.subject).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textPrimary)
                .lineLimit(1).truncationMode(.tail)
            if row.isAIAssisted { AIBadge() }
            Spacer(minLength: 0)
            if !row.isInGraph {
                Text("Not in the graph").font(Tokens.Font.caption).foregroundStyle(Tokens.Color.textTertiary)
            }
        }
        // Starts where the file rows' badges start, and its hover sits where theirs does (#577).
        .padding(.horizontal, FileRowView.horizontalPadding)
        .padding(.vertical, Tokens.Spacing.xxs)
        .hoverHighlight(
            .rounded(radius: Tokens.Radius.md), isEnabled: row.isInGraph, horizontalInset: FileRowView.selectionInset
        )
        .contentShape(Rectangle())
        .onTapGesture { if row.isInGraph { onShowCommit(row.oid) } }
        .help(row.subject + "\n" + row.author)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(row.isInGraph ? .isButton : [])
        .accessibilityAction { if row.isInGraph { onShowCommit(row.oid) } }
    }

    /// What the target has that the base does not, newest first; a row opens that commit's S-03 like BASE/TARGET.
    private var commits: some View {
        DetailCard {
            sectionTitle(
                model.commitsNotice == nil
                    ? "COMMITS (\(WipDetailModel.formatted(model.commits.count))\(model.hasMoreCommits ? "+" : ""))"
                    : "COMMITS")
            if let notice = model.commitsNotice {
                Text(notice).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
                ForEach(model.commits, id: \.oid) { row in commitRow(row) }
            }
            if model.hasMoreCommits {
                Text("Showing the newest \(WipDetailModel.formatted(model.commits.count)) commits")
                    .font(Tokens.Font.caption).foregroundStyle(Tokens.Color.textTertiary)
            }
        }
        .help("Commits in \(model.target.shortSHA) that \(model.base.shortSHA) does not have")
    }

    private var files: some View {
        DetailCard {
            HStack {
                Text(
                    "FILES CHANGED (\(WipDetailModel.formatted(model.rows.count + model.hidden))\(model.isPartial ? "+" : ""))"
                )
                .font(Tokens.Font.sectionHeader)
                .tracking(Tokens.Font.sectionHeaderTracking)
                .foregroundStyle(Tokens.Color.textTertiary)
                Spacer()
                Text(model.totalLineChange).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.textSecondary)
            }
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.rows) { row in fileRow(row) }
            }
            if model.hidden > 0 {
                Button("Show all \(WipDetailModel.formatted(model.rows.count + model.hidden)) files", action: onShowAll)
                    .buttonStyle(.link)
            }
        }
    }

    private func fileRow(_ row: CommitDetailModel.FileRow) -> some View {
        let isSelected = session.selectedFile == row.stat.path
        return FileRowView(
            badge: .neutral(letter: row.kindLetter), directory: row.directory, fileName: row.fileName,
            lineCount: row.stat.lineCount, isSelectable: row.isSelectable, isSelected: isSelected
        )
        .contentShape(Rectangle())
        .onTapGesture { if row.isSelectable { onSelectFile(row.stat) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : (row.isSelectable ? .isButton : []))
        .accessibilityAction { if row.isSelectable { onSelectFile(row.stat) } }
    }
}
