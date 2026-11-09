import AppKit
import SwiftUI

extension EnvironmentValues {
    @Entry var pullRequestBadges = PullRequestBadgeContext()
}

/// The PR pill (information-architecture.md §4.3, priority 7): state symbol and `#123` in a `text.secondary` outline,
/// dashed for a draft. Status colours are not used. Inert: the row's VoiceOver label carries it.
struct PullRequestPill: View {
    let badge: PullRequestBadge

    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        HStack(spacing: Tokens.Spacing.xxs) {
            Image(systemName: badge.symbol)
            Text(badge.text)
        }
        .font(Tokens.Font.pill)
        .foregroundStyle(Tokens.Color.textSecondary)
        .padding(.horizontal, Tokens.Spacing.xs)
        .overlay {
            Capsule().strokeBorder(
                Tokens.Color.textSecondary,
                style: StrokeStyle(
                    lineWidth: Tokens.controlOutlineWidth(contrast), dash: badge.isDraft ? [2, 2] : []))
        }
        .fixedSize()
        .help(badge.help)
        .accessibilityHidden(true)
    }
}

/// S-05's "Pull request" card, under the info card (screens.md S-05).
struct PullRequestCard: View {
    let model: PullRequestCardModel

    var body: some View {
        DetailCard {
            Text("Pull request").font(Tokens.Font.columnHeader).foregroundStyle(Tokens.Color.textPrimary)
            HStack(spacing: Tokens.Spacing.xs) {
                PullRequestPill(badge: model.badge)
                Text(model.badge.stateText).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textSecondary)
            }
            Text(model.title)
                .font(Tokens.Font.callout)
                .foregroundStyle(Tokens.Color.textPrimary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
            if let review = model.review {
                Text(review).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textSecondary)
            }
            if let base = model.base {
                Text("into \(base)").font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            HStack(spacing: Tokens.Spacing.sm) {
                Button("Open in Browser") {
                    if let url = model.browserURL { NSWorkspace.shared.open(url) }
                }
                .disabled(model.browserURL == nil)
                .help(
                    model.browserURL == nil
                        ? String(localized: "This link is not this repository's pull request page.") : model.urlText)
                Button("Copy URL") {
                    // Copying to the clipboard is not a repository write (ADR-0011).
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(model.urlText, forType: .string)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }
}
