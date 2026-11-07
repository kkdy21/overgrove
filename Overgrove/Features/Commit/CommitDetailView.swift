import AppKit
import SwiftUI

/// S-03, one commit (screens.md S-03, #69): subject, message, meta, and changed files. Read-only: no cherry-pick,
/// revert, or checkout (ADR-0011). Signatures are not shown (verifying runs `gpg.program`, T7).
struct CommitDetailView: View {
    let model: CommitDetailModel
    /// The commit's lane in the graph: its pills use that color, as in the Refs column.
    var laneIndex = 0
    let selectedFile: GitPath?
    let onSelectFile: (FileStat) -> Void
    var onSelectParent: (ObjectID) -> Void = { _ in }
    var onShowAllFiles: () -> Void = {}

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
                    header
                    meta
                    files
                }
                .padding(Tokens.Spacing.md)
            }
            Tokens.Color.borderSeparator.frame(height: 1)
            HStack {
                Button("Copy SHA") {
                    // Copying to the clipboard is not a repository write (ADR-0011).
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.fullSHA, forType: .string)
                }
                .help(model.fullSHA)
                Spacer()
            }
            .padding(Tokens.Spacing.sm + Tokens.Spacing.xxs)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            Text(model.title)
                .font(Tokens.Font.title)
                .foregroundStyle(Tokens.Color.textPrimary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !model.body.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(model.body) { line in
                        Text(line.text.isEmpty ? " " : line.text)
                            .font(line.isTrailer ? Tokens.Font.monoSmall : Tokens.Font.body)
                            .foregroundStyle(line.isTrailer ? Tokens.Color.textSecondary : Tokens.Color.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .textSelection(.enabled)
            }
            if model.isPartial {
                Label("Too large to show in full", systemImage: "scissors")
                    .font(Tokens.Font.caption).foregroundStyle(Tokens.Color.textTertiary)
            }
        }
    }

    private var meta: some View {
        DetailCard {
            Grid(
                alignment: .leadingFirstTextBaseline, horizontalSpacing: Tokens.Spacing.md,
                verticalSpacing: Tokens.Spacing.xs
            ) {
                GridRow {
                    label("Author")
                    person(model.author)
                }
                ForEach(Array(model.coAuthors.enumerated()), id: \.offset) { _, coAuthor in
                    GridRow {
                        label("Co-author")
                        HStack(spacing: Tokens.Spacing.xs) {
                            if coAuthor.isAI {
                                // Not a person: an outline with `sparkles`, never an initials avatar (§3.5).
                                Image(systemName: "sparkles").font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(Tokens.Color.textTertiary)
                                    .frame(width: 16, height: 16)
                                    .overlay { Circle().strokeBorder(Tokens.Color.textTertiary, lineWidth: 1) }
                            }
                            Text(coAuthor.title).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textPrimary)
                                .lineLimit(1).truncationMode(.middle)
                                .help(coAuthor.tooltip)
                            if coAuthor.isAI { AIBadge() }
                        }
                    }
                }
                GridRow {
                    label("Date")
                    Text(model.date).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textPrimary)
                }
                if let committer = model.committer {
                    GridRow {
                        label("Committer")
                        person(committer)
                    }
                }
                if !model.parents.isEmpty {
                    GridRow {
                        label(model.parents.count > 1 ? "Parents" : "Parent")
                        HStack(spacing: Tokens.Spacing.sm) {
                            ForEach(model.parents, id: \.self) { parent in
                                Button(parent.short) { onSelectParent(parent) }
                                    .buttonStyle(.link)
                                    .font(Tokens.Font.monoSmall)
                                    .help(parent.hex)
                            }
                        }
                    }
                }
                if !model.pills.isEmpty {
                    GridRow {
                        label("Refs")
                        HStack(spacing: Tokens.Spacing.xs) {
                            ForEach(Array(model.pills.prefix(3).enumerated()), id: \.offset) { _, pill in
                                GraphRefPillView(
                                    pill: pill,
                                    laneColor: Tokens.Color.graphLanes[laneIndex % Tokens.Color.graphLanes.count],
                                    laneIndex: laneIndex)
                            }
                            if model.pills.count > 3 {
                                Text("+\(model.pills.count - 3)").font(Tokens.Font.caption)
                                    .foregroundStyle(Tokens.Color.textSecondary)
                                    .help(model.pills.dropFirst(3).map(\.tooltip).joined(separator: "\n"))
                            }
                        }
                    }
                }
                if !model.issues.isEmpty {
                    GridRow {
                        label(model.issues.count > 1 ? "Issues" : "Issue")
                        Text(model.issues.map { "#\($0)" }.joined(separator: " "))
                            .font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textLink)
                    }
                }
            }
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textTertiary)
    }

    private func person(_ person: CommitDetailModel.Person) -> some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Text(person.initials)
                .font(Tokens.Font.initials)
                .foregroundStyle(Tokens.Color.avatarInitials)
                .frame(width: 16, height: 16)
                .background(Circle().fill(Tokens.Color.avatars[person.avatarIndex % Tokens.Color.avatars.count]))
                .accessibilityHidden(true)
            Text(person.name).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textPrimary)
            Text(person.email).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.textSecondary)
                .lineLimit(1).truncationMode(.middle)
        }
    }

    @ViewBuilder
    private var files: some View {
        DetailCard {
            HStack {
                Text(model.filesHeader.uppercased())
                    .font(Tokens.Font.sectionHeader)
                    .tracking(Tokens.Font.sectionHeaderTracking)
                    .foregroundStyle(Tokens.Color.textTertiary)
                Spacer()
                Text(model.totalLineChange).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.textSecondary)
            }
            if let note = model.filesNote {
                Text(note).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.textTertiary)
            }
            switch model.files {
            case .loading:
                ProgressView().controlSize(.small)
            case .failed(let reason):
                Text(reason).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textSecondary)
            case .loaded(let rows, let hidden):
                if rows.isEmpty {
                    Text("No file changes").font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textTertiary)
                }
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in fileRow(row) }
                }
                if hidden > 0 {
                    Button("Show all \(WipDetailModel.formatted(rows.count + hidden)) files", action: onShowAllFiles)
                        .buttonStyle(.link)
                }
            }
        }
    }

    private func fileRow(_ row: CommitDetailModel.FileRow) -> some View {
        HStack(spacing: Tokens.Spacing.sm) {
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
            if selectedFile == row.stat.path {
                RoundedRectangle(cornerRadius: Tokens.Radius.md).fill(Tokens.Color.surfaceSelection)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if row.isSelectable { onSelectFile(row.stat) } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(row.isSelectable ? .isButton : [])
        .accessibilityAction { if row.isSelectable { onSelectFile(row.stat) } }
    }
}
