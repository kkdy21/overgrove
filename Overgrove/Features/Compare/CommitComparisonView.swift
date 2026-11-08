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
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Back to the graph (⎋)")
                Text("Compare").font(Tokens.Font.headline).foregroundStyle(Tokens.Color.textPrimary)
                Text(model.title).font(Tokens.Font.mono).foregroundStyle(Tokens.Color.textSecondary)
                Button(action: onSwap) {
                    Image(systemName: "arrow.left.arrow.right")
                }
                .buttonStyle(.borderless)
                .help("Swap base and target")
                .accessibilityLabel("Swap base and target")
                Spacer(minLength: Tokens.Spacing.sm)
            }
            summary
            Tokens.Color.borderSeparator.frame(height: 1)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
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
                    symbol: "doc.text", title: "Select a file",
                    message: "Pick a file in the list to see how it changed from \(model.base.shortSHA) to "
                        + "\(model.target.shortSHA).")
            }
        }
    }

    private var patchSource: String {
        guard case .loaded(let document) = session.patch else { return "" }
        return document.source.label + (document.source.kindLetter.isEmpty ? "" : " · \(document.source.kindLetter)")
    }
}

/// S-12's detail panel: BASE, TARGET, and FILES CHANGED (screens.md S-12).
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
                if case .loaded = model.state { files }
                if case .noChanges(let text) = model.state {
                    Text(text).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textSecondary)
                }
            }
            .padding(Tokens.Spacing.md)
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(Tokens.Font.sectionHeader)
            .tracking(Tokens.Font.sectionHeaderTracking)
            .foregroundStyle(Tokens.Color.textTertiary)
    }

    private func commitRow(_ row: CommitComparisonModel.CommitRow) -> some View {
        HStack(spacing: Tokens.Spacing.sm) {
            Text(row.shortSHA).font(Tokens.Font.monoSmall).foregroundStyle(Tokens.Color.textTertiary)
            Text(row.subject).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textPrimary)
                .lineLimit(1).truncationMode(.tail)
            if row.isAIAssisted { AIBadge() }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .onTapGesture { onShowCommit(row.oid) }
        .help(row.subject + "\n" + row.author)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onShowCommit(row.oid) }
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
        return HStack(spacing: Tokens.Spacing.sm) {
            Text(row.kindLetter).font(Tokens.Font.monoSmall).foregroundStyle(Tokens.Color.textSecondary)
                .frame(width: 14)
            (Text(row.directory).foregroundStyle(Tokens.Color.textTertiary)
                + Text(row.fileName).foregroundStyle(Tokens.Color.textPrimary).fontWeight(.medium))
                .font(Tokens.Font.callout)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: Tokens.Spacing.xs)
            Text(row.lineChange).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.textSecondary)
        }
        .padding(.vertical, Tokens.Spacing.xxs)
        .padding(.horizontal, Tokens.Spacing.xs)
        .background {
            if isSelected { RoundedRectangle(cornerRadius: Tokens.Radius.md).fill(Tokens.Color.surfaceSelection) }
        }
        .contentShape(Rectangle())
        .onTapGesture { if row.isSelectable { onSelectFile(row.stat) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : (row.isSelectable ? .isButton : []))
        .accessibilityAction { if row.isSelectable { onSelectFile(row.stat) } }
    }
}
