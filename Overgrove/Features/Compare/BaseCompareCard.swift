import SwiftUI

/// The base compare card pinned under S-02 and S-05 (#581, art-direction.md §7): `Changes vs [base ⌃]`, the base
/// commit, `n commits ahead · n behind · n files` with `+n −m`, and `Compare with Base…` (`⌘⇧B`, S-11). Accent 7% fill
/// with a 35% outline (`surface.compare-card`, `border.compare-card`).
struct BaseCompareCard: View {
    let model: BaseCompareCardModel
    let onChooseBase: (FullRefName) -> Void
    let onCompare: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xs) {
            header
            status
            Button("Compare with Base…", action: onCompare)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(!model.canCompare)
                .help("See what this worktree changed compared with its base branch (⌘⇧B)")
        }
        .padding(Tokens.Spacing.sm + Tokens.Spacing.xxs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            let shape = RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
            shape.fill(Tokens.Color.surfaceCompareCard)
                .overlay(shape.strokeBorder(Tokens.Color.borderCompareCard))
        }
    }

    private var header: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Image(systemName: "plusminus").foregroundStyle(Tokens.Color.textSecondary).accessibilityHidden(true)
            Text("Changes vs").foregroundStyle(Tokens.Color.textPrimary).fixedSize()
            Menu {
                ForEach(model.bases) { base in
                    Button(base.name) { onChooseBase(base.ref) }
                }
            } label: {
                Text(model.baseName).lineLimit(1).truncationMode(.middle)
            }
            .menuStyle(.borderlessButton)
            .fixedSize(horizontal: false, vertical: true)
            .layoutPriority(1)
            .disabled(model.bases.isEmpty)
            .help("Choose the base branch")
            Spacer(minLength: Tokens.Spacing.xs)
            if case .loaded(_, _, _, let baseCommit) = model.state {
                Text("base \(baseCommit)")
                    .font(Tokens.Font.monoSmall)
                    .foregroundStyle(Tokens.Color.textTertiary)
                    .fixedSize()
                    .help("The base branch's commit this comparison used")
            }
        }
        .font(Tokens.Font.callout.weight(.semibold))
    }

    @ViewBuilder
    private var status: some View {
        switch model.state {
        case .loading(let text):
            HStack(spacing: Tokens.Spacing.xs) {
                ProgressView().controlSize(.small)
                Text(text).foregroundStyle(Tokens.Color.textSecondary).lineLimit(1)
            }
            .font(Tokens.Font.callout)
        case .noBase(let text), .failed(let text):
            Text(text)
                .font(Tokens.Font.callout)
                .foregroundStyle(Tokens.Color.textSecondary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        case .loaded(let summary, let added, let deleted, _):
            HStack(spacing: Tokens.Spacing.sm) {
                Text(summary).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textPrimary).lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 0)
                LineCountText(added: added, deleted: deleted).font(Tokens.Font.monoSmall).layoutPriority(1)
            }
            .help(summary)
        }
    }
}
