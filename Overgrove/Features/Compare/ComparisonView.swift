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
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Back to the graph (⎋)")
                Text("Changes vs").font(Tokens.Font.headline).foregroundStyle(Tokens.Color.textPrimary)
                basePicker
                Spacer(minLength: Tokens.Spacing.sm)
                Toggle(
                    "Include uncommitted",
                    isOn: Binding(get: { session.includeUncommitted }, set: { onIncludeUncommitted($0) })
                )
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            summary
            Tokens.Color.borderSeparator.frame(height: 1)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
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
        .disabled(session.bases.isEmpty)
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
                    symbol: "doc.text", title: "Select a file",
                    message: "Pick a file in the list to see its changes compared with \(model.baseName).")
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
                    "compared with \(model.baseName)"
                        + (session.includeUncommitted ? ", including uncommitted changes" : "")
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
        }
    }

    private var commits: some View {
        DetailCard {
            sectionTitle("COMMITS AHEAD", count: model.commits.count, more: model.hasMoreCommits)
            if let count = model.uncommittedFileCount {
                HStack(spacing: Tokens.Spacing.sm) {
                    Image(systemName: "circle.dashed").foregroundStyle(Tokens.Color.textTertiary)
                        .accessibilityHidden(true)
                    Text("Uncommitted changes").font(Tokens.Font.callout)
                    Spacer()
                    Text("\(count) \(count == 1 ? "file" : "files")").font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Color.textSecondary)
                }
            }
            // TODO(#69): picking a commit opens its detail (S-03).
            ForEach(model.commits) { commit in
                HStack(spacing: Tokens.Spacing.sm) {
                    Text(commit.shortSHA).font(Tokens.Font.monoSmall).foregroundStyle(Tokens.Color.textTertiary)
                    Text(commit.subject).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textPrimary)
                        .lineLimit(1).truncationMode(.tail)
                }
                .help("\(commit.subject)\n\(commit.author)")
                .accessibilityElement(children: .combine)
            }
        }
    }

    private var files: some View {
        DetailCard {
            HStack {
                sectionTitle("FILES CHANGED", count: model.totalFileCount, more: model.isFileListPartial)
                Spacer()
                Text(model.totalLineChange).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.textSecondary)
            }
            ForEach(model.files) { row in
                fileRow(row, isUntracked: false)
            }
            if let title = model.showAllTitle {
                Button(title, action: onShowAll).buttonStyle(.link)
            }
        }
    }

    private var untracked: some View {
        DetailCard {
            sectionTitle("UNTRACKED", count: model.untracked.count, more: false)
            ForEach(model.untracked) { row in fileRow(row, isUntracked: true) }
        }
    }

    private func sectionTitle(_ title: String, count: Int, more: Bool) -> some View {
        Text("\(title) (\(WipDetailModel.formatted(count))\(more ? "+" : ""))")
            .font(Tokens.Font.sectionHeader)
            .tracking(Tokens.Font.sectionHeaderTracking)
            .foregroundStyle(Tokens.Color.textTertiary)
    }

    private func fileRow(_ row: ComparisonModel.FileRow, isUntracked: Bool) -> some View {
        let isSelected = session.selectedFile?.path == row.path && session.selectedFile?.isUntracked == isUntracked
        return HStack(spacing: Tokens.Spacing.sm) {
            Text(row.kindLetter).font(Tokens.Font.monoSmall).foregroundStyle(Tokens.Color.textSecondary)
                .frame(width: Tokens.Spacing.md)
            (Text(row.directory).foregroundStyle(Tokens.Color.textTertiary)
                + Text(row.fileName).foregroundStyle(Tokens.Color.textPrimary).fontWeight(.medium))
                .font(Tokens.Font.callout)
                .lineLimit(1)
                .truncationMode(.head)
            if row.hasUncommittedChanges {
                Text("WIP").font(Tokens.Font.pill).foregroundStyle(Tokens.Color.textSecondary)
                    .padding(.horizontal, Tokens.Spacing.xs)
                    .background(Capsule().strokeBorder(Tokens.Color.borderSeparator))
            }
            Spacer(minLength: Tokens.Spacing.xs)
            if let change = row.lineChange {
                Text(change).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.textSecondary)
            }
        }
        .padding(.vertical, Tokens.Spacing.xxs)
        .padding(.horizontal, Tokens.Spacing.xs)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Tokens.Radius.md).fill(Tokens.Color.surfaceSelection)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if row.isSelectable { onSelect(ComparisonFile(path: row.path, isUntracked: isUntracked)) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(row.isSelectable ? .isButton : [])
        .accessibilityAction {
            if row.isSelectable { onSelect(ComparisonFile(path: row.path, isUntracked: isUntracked)) }
        }
    }
}
