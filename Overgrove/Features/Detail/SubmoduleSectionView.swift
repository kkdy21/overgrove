import SwiftUI

/// S-02's Submodules card (#108): each submodule's own working tree, read only after its own settings were checked.
/// Display only: rows do nothing when clicked.
struct SubmoduleSectionView: View {
    let model: SubmoduleSectionModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Tokens.Spacing.xs) {
                Image(systemName: "shippingbox").foregroundStyle(Tokens.Color.textTertiary).accessibilityHidden(true)
                Text("Submodules").font(Tokens.Font.columnHeader).foregroundStyle(Tokens.Color.textPrimary)
                if case .rows(let rows) = model.content {
                    Text("\(rows.count + model.omitted)")
                        .font(Tokens.Font.pill)
                        .foregroundStyle(Tokens.Color.textSecondary)
                        .padding(.horizontal, Tokens.Spacing.xs + Tokens.Spacing.xxs)
                        .background(Capsule().fill(Tokens.Color.surfacePanel))
                }
                Spacer()
            }
            .padding(.horizontal, Tokens.Spacing.sm + Tokens.Spacing.xxs)
            .frame(height: WipGroupCard.headerHeight)
            .accessibilityAddTraits(.isHeader)

            content
            ForEach(notes, id: \.self) { note in
                Text(note)
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Color.textTertiary)
                    .padding(.horizontal, Tokens.Spacing.sm + Tokens.Spacing.xxs)
                    .frame(minHeight: Tokens.Size.rowFile)
            }
        }
        .padding(.bottom, Tokens.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .fill(Tokens.Color.surfaceRaised)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                .strokeBorder(Tokens.Color.borderSeparator, lineWidth: 1))
    }

    @ViewBuilder
    private var content: some View {
        switch model.content {
        case .checking:
            HStack(spacing: Tokens.Spacing.xs) {
                ProgressView().controlSize(.mini)
                Text("Checking submodules…").foregroundStyle(Tokens.Color.textTertiary)
            }
            .font(Tokens.Font.caption)
            .padding(.horizontal, Tokens.Spacing.sm + Tokens.Spacing.xxs)
            .frame(height: Tokens.Size.rowFile)
        case .failed:
            Text("Submodules could not be read.")
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Color.statusError)
                .padding(.horizontal, Tokens.Spacing.sm + Tokens.Spacing.xxs)
                .frame(height: Tokens.Size.rowFile)
        case .rows(let rows):
            ForEach(rows) { row in
                SubmoduleRowView(row: row)
            }
        }
    }

    private var notes: [String] {
        var notes: [String] = []
        if model.isGitmodulesRefused {
            notes.append(".gitmodules was not read: it is not a regular file in the worktree.")
        }
        if model.omitted > 0 { notes.append("\(model.omitted) more not inspected") }
        return notes
    }
}

private struct SubmoduleRowView: View {
    let row: SubmoduleSectionModel.Row

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Text(row.path)
                .font(Tokens.Font.mono)
                .foregroundStyle(Tokens.Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.head)
            if row.isUnlisted {
                Text("not in .gitmodules")
                    .font(Tokens.Font.pill)
                    .foregroundStyle(Tokens.Color.textTertiary)
            }
            Spacer(minLength: Tokens.Spacing.sm)
            if row.tone == .attention {
                Image(systemName: "exclamationmark.shield")
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Color.statusPrunable)
                    .accessibilityHidden(true)
            }
            Text(row.badge)
                .font(Tokens.Font.caption)
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.horizontal, Tokens.Spacing.sm + Tokens.Spacing.xxs)
        .frame(height: Tokens.Size.rowFile)
        .help(row.help ?? "")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SubmoduleSectionModel.accessibilityLabel(row))
        .accessibilityHint(row.help ?? "")
    }

    private var tint: Color {
        switch row.tone {
        case .quiet: Tokens.Color.textTertiary
        case .changed: Tokens.Color.statusUnstaged
        case .attention: Tokens.Color.textSecondary
        }
    }
}
