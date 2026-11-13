import SwiftUI

/// S-11's center area: base picker, `Include uncommitted`, the summary, and the picked file's patch (S-10's viewer).
/// It covers the graph until `‹ Graph` or `⎋` (screens.md S-11). Read-only (ADR-0011).
struct ComparisonCenterView: View {
    let session: ComparisonSession
    let model: ComparisonModel
    let onBack: () -> Void
    let onChooseBase: (FullRefName) -> Void
    let onIncludeUncommitted: (Bool) -> Void

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader {
                Button(action: onBack) {
                    Label("Graph", systemImage: "chevron.left")
                }
                .hoverButtonStyle()
                // `⎋` is handled once, by the window (`AppState.escape`, #633).
                .toolTip(String(localized: "Back to the graph (⎋)"))
                Text("Changes vs").font(Tokens.Font.headline).foregroundStyle(Tokens.Color.textPrimary)
                basePicker
                Spacer(minLength: Tokens.Spacing.sm)
                Toggle(
                    "Include uncommitted",
                    isOn: Binding(get: { session.includeUncommitted }, set: { onIncludeUncommitted($0) })
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(model.staleNotice != nil)
            }
            if let notice = model.staleNotice { ComparisonStaleNotice(text: notice) }
            Group {
                summary
                Tokens.Color.borderSeparator.frame(height: 1)
                content.frame(maxWidth: .infinity, maxHeight: .infinity).fadeIn(on: model.state.phase)
            }
            .staleComparison(model.staleNotice != nil)
        }
    }

    private var basePicker: some View {
        Menu {
            ForEach(session.bases, id: \.self) { base in
                Button(ComparisonModel.shortName(base)) { onChooseBase(base) }
            }
        } label: {
            Label(model.baseName, systemImage: "arrow.triangle.branch")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .disabled(session.bases.isEmpty || model.staleNotice != nil)
        .help("Choose the base branch")
    }

    @ViewBuilder
    private var summary: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            switch model.state {
            case .loading(let text):
                ProgressView().controlSize(.small)
                Text(text)
            default:
                if let summary = model.summary { Text(summary) }
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
        case .failed(let message, let canChooseBase):
            VStack(spacing: Tokens.Spacing.sm) {
                DetailState(symbol: "exclamationmark.triangle", tint: Tokens.Color.statusWarning, title: message)
                if canChooseBase && !session.bases.isEmpty {
                    basePicker
                }
            }
        case .loaded:
            if let file = session.selectedFile, let patch = session.patch {
                DiffViewerView(
                    title: PathValidator.displayable(file.path.display), sourceLabel: patchSource, state: patch,
                    onBack: onBack, showsBackButton: false)
            } else {
                PanelEmptyState(
                    symbol: "doc.text", title: String(localized: "Select a file"),
                    message: String(
                        localized: "Pick a file in the list to see its changes compared with \(model.baseName)."))
            }
        }
    }

    private var patchSource: String {
        if case .loaded(let document) = session.patch {
            return document.source.label
                + (document.source.kindLetter.isEmpty ? "" : " · \(document.source.kindLetter)")
        }
        return ""
    }
}

/// S-11's detail panel: COMMITS AHEAD, FILES CHANGED, UNTRACKED (screens.md S-11).
struct ComparisonListView: View {
    let title: String
    let session: ComparisonSession
    let model: ComparisonModel
    let onSelect: (ComparisonFile) -> Void
    let onShowAll: () -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Tokens.Spacing.md) {
                Text(
                    session.includeUncommitted
                        ? "compared with \(model.baseName), including uncommitted changes"
                        : "compared with \(model.baseName)" as LocalizedStringKey
                )
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Color.textTertiary)
                if case .loaded = model.state {
                    commits
                    files
                    if session.includeUncommitted && !model.untracked.isEmpty { untracked }
                } else if case .noChanges(let text) = model.state {
                    Text(text).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textSecondary)
                }
            }
            .padding(Tokens.Spacing.md)
            .staleComparison(model.staleNotice != nil)
        }
    }

    private var commits: some View {
        DetailCard {
            sectionTitle(String(localized: "COMMITS AHEAD"), count: model.commits.count, more: model.hasMoreCommits)
            if let count = model.uncommittedFileCount {
                HStack(spacing: Tokens.Spacing.sm) {
                    Image(systemName: "circle.dashed").foregroundStyle(Tokens.Color.textTertiary)
                        .accessibilityHidden(true)
                    Text("Uncommitted changes").font(Tokens.Font.callout)
                    Spacer()
                    Text(count == 1 ? "\(count) file" : "\(count) files" as LocalizedStringKey).font(
                        Tokens.Font.caption
                    )
                    .foregroundStyle(Tokens.Color.textSecondary)
                }
                .padding(.horizontal, FileRowView.horizontalPadding)
            }
            // TODO(#69): picking a commit opens its detail (S-03).
            ForEach(model.commits) { commit in
                HStack(spacing: Tokens.Spacing.sm) {
                    Text(commit.shortSHA).font(Tokens.Font.monoSmall).foregroundStyle(Tokens.Color.textTertiary)
                    Text(commit.subject).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textPrimary)
                        .lineLimit(1).truncationMode(.tail)
                }
                // Starts where the file rows' badges start (#577).
                .padding(.horizontal, FileRowView.horizontalPadding)
                .help(commit.subject + "\n" + commit.author)
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var files: some View {
        DetailCard {
            HStack {
                sectionTitle(
                    String(localized: "FILES CHANGED"), count: model.totalFileCount, more: model.isFileListPartial)
                Spacer()
                Text(model.totalLineChange).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.textSecondary)
            }
            // No card spacing between rows: they are 26pt each, like every detail file list (#577).
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.files) { row in
                    fileRow(row, isUntracked: false)
                }
            }
            if let title = model.showAllTitle {
                Button(title, action: onShowAll).buttonStyle(.link)
            }
        }
    }

    private var untracked: some View {
        DetailCard {
            sectionTitle(String(localized: "UNTRACKED"), count: model.untracked.count, more: false)
            VStack(alignment: .leading, spacing: 0) {
                ForEach(model.untracked) { row in fileRow(row, isUntracked: true) }
            }
        }
    }

    private func sectionTitle(_ title: String, count: Int, more: Bool) -> some View {
        Text("\(title) (\(WipDetailModel.formatted(count))\(more ? "+" : ""))" as String)
            .font(Tokens.Font.sectionHeader)
            .tracking(Tokens.Font.sectionHeaderTracking)
            .foregroundStyle(Tokens.Color.textTertiary)
    }

    private func fileRow(_ row: ComparisonModel.FileRow, isUntracked: Bool) -> some View {
        let isSelected = session.selectedFile?.path == row.path && session.selectedFile?.isUntracked == isUntracked
        return FileRowView(
            badge: isUntracked ? .status(letter: "?", group: .untracked) : .neutral(letter: row.kindLetter),
            directory: row.directory, fileName: row.fileName, lineCount: row.lineCount,
            pill: row.hasUncommittedChanges ? "WIP" : nil, isSelectable: row.isSelectable, isSelected: isSelected
        )
        .contentShape(Rectangle())
        .onTapGesture { if row.isSelectable { onSelect(ComparisonFile(path: row.path, isUntracked: isUntracked)) } }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel + (isUntracked ? ", untracked" : ""))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : (row.isSelectable ? .isButton : []))
        .accessibilityAction {
            if row.isSelectable { onSelect(ComparisonFile(path: row.path, isUntracked: isUntracked)) }
        }
    }
}

/// The line under S-11's header when the worktree list failed to load after the comparison ran (#374).
private struct ComparisonStaleNotice: View {
    let text: String

    var body: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(Tokens.Color.statusWarning)
                .accessibilityHidden(true)
            Text(text).foregroundStyle(Tokens.Color.textSecondary)
            Spacer(minLength: 0)
        }
        .font(Tokens.Font.callout)
        .padding(.horizontal, Tokens.Spacing.md)
        .frame(minHeight: Tokens.Size.rowSidebar)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    /// A stale S-11 (#374): dimmed like other stale data (interaction.md §4.1) and not interactive.
    fileprivate func staleComparison(_ isStale: Bool) -> some View {
        opacity(isStale ? Tokens.Opacity.stale : 1).allowsHitTesting(!isStale)
    }
}
