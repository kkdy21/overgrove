import AppKit
import SwiftUI

/// S-05, the `Worktree` segment: an info card and the SECURITY card (screens.md S-05, security-review.md §6).
///
/// There is no Fetch button here: fetch is per repository and lives in the toolbar. Nothing here changes the
/// repository (ADR-0011).
struct WorktreeDetailView: View {
    let model: WorktreeDetailModel
    /// `Compare with Base…` (`⌘⇧B`, S-11); `nil` disables it.
    var onCompare: (() -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
                InfoCard(model: model)
                Button("Compare with Base…") { onCompare?() }
                    .disabled(onCompare == nil)
                    .help("See what this worktree changed compared with its base branch (⌘⇧B)")
                if let slow = model.slowStatus {
                    SlowStatusCard(hint: slow)
                }
                if let security = model.security {
                    SecurityCard(model: security)
                } else if let reason = model.securityUnavailable {
                    DetailCard {
                        Text("Security").font(Tokens.Font.columnHeader).foregroundStyle(Tokens.Color.textPrimary)
                        Text(reason).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    DetailCard {
                        HStack(spacing: Tokens.Spacing.sm) {
                            ProgressView().controlSize(.small)
                            Text("Inspecting configuration…").font(Tokens.Font.callout)
                                .foregroundStyle(Tokens.Color.textSecondary)
                        }
                    }
                }
            }
            .padding(Tokens.Spacing.md)
        }
    }
}

/// A card on the detail panel (art-direction.md §7): `surface.raised`, radius 8, 1px `border.separator`.
struct DetailCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.sm) { content }
            .padding(Tokens.Spacing.sm + Tokens.Spacing.xxs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: WipGroupCard.cornerRadius, style: .continuous)
                    .fill(Tokens.Color.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: WipGroupCard.cornerRadius, style: .continuous)
                    .strokeBorder(Tokens.Color.borderSeparator, lineWidth: 1))
    }
}

private struct InfoCard: View {
    let model: WorktreeDetailModel

    var body: some View {
        DetailCard {
            Grid(
                alignment: .leadingFirstTextBaseline, horizontalSpacing: Tokens.Spacing.md,
                verticalSpacing: Tokens.Spacing.xs
            ) {
                ForEach(model.info) { row in
                    GridRow {
                        Text(row.label)
                            .font(Tokens.Font.callout)
                            .foregroundStyle(Tokens.Color.textTertiary)
                            .gridColumnAlignment(.leading)
                        HStack(spacing: Tokens.Spacing.xs) {
                            if row.isWarning {
                                Image(systemName: "exclamationmark.triangle")
                                    .foregroundStyle(Tokens.Color.statusPrunable)
                                    .accessibilityHidden(true)
                            }
                            Text(row.value)
                                .font(row.label == "HEAD" ? Tokens.Font.monoSmall : Tokens.Font.callout)
                                .foregroundStyle(
                                    row.isDimmed
                                        ? Tokens.Color.textTertiary
                                        : (row.isWarning ? Tokens.Color.statusPrunable : Tokens.Color.textPrimary)
                                )
                                .lineLimit(2)
                                .truncationMode(.middle)
                            if row.label == "Path", let path = model.copyablePath {
                                Button {
                                    // Copying to the clipboard is not a repository write (ADR-0011).
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(path, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc").hitTarget()
                                }
                                .buttonStyle(.borderless)
                                .help("Copy Path")
                                .accessibilityLabel("Copy path")
                            }
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }
        }
    }
}

private struct SecurityCard: View {
    let model: WorktreeSecurityModel
    @State private var expanded: Set<String> = []

    var body: some View {
        DetailCard {
            HStack(alignment: .firstTextBaseline) {
                Text("Security").font(Tokens.Font.columnHeader).foregroundStyle(Tokens.Color.textPrimary)
                Spacer()
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    Text(header(now: context.date))
                        .font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Color.textTertiary)
                }
            }
            if let reason = model.blockingReason {
                banner(symbol: "xmark.octagon", tint: Tokens.Color.statusError, title: "Queries stopped", text: reason)
            }
            if let reason = model.failure {
                banner(
                    symbol: "exclamationmark.triangle", tint: Tokens.Color.statusWarning,
                    title: "Configuration not read", text: reason)
            }
            if let reason = model.fetchBlockingReason {
                banner(
                    symbol: "arrow.down.circle", tint: Tokens.Color.statusWarning, title: "Fetch disabled",
                    text: reason)
            }
            if let note = model.limitNote {
                banner(symbol: "list.bullet", tint: Tokens.Color.statusWarning, title: "Report shortened", text: note)
            }
            ForEach(model.rows) { row in
                SecurityRowView(row: row, isExpanded: expanded.contains(row.id)) {
                    if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
                }
            }
            if !model.others.isEmpty {
                Divider()
                Text("Other repository settings").font(Tokens.Font.caption).foregroundStyle(Tokens.Color.textTertiary)
                ForEach(model.others) { finding in
                    HStack(spacing: Tokens.Spacing.xs) {
                        Text(finding.key).font(Tokens.Font.monoSmall).foregroundStyle(Tokens.Color.textPrimary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Tokens.Spacing.xs)
                        Text(finding.handling).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.textSecondary)
                    }
                    .help(finding.threat.map { "Threat \($0) in docs/design/security-review.md" } ?? "")
                    .accessibilityElement(children: .combine)
                }
            }
            Text("Values are never shown. Each setting is overridden where git would use it.")
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Color.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// `Inspected 2 min ago · local and worktree scopes · git 2.50.1` (security-review.md §6).
    private func header(now: Date) -> String {
        var parts = ["Inspected \(StatusBarItem.relative(model.inspectedAt, now: now))", "local and worktree scopes"]
        if let version = model.gitVersion { parts.append(version) }
        return parts.joined(separator: " · ")
    }

    private func banner(symbol: String, tint: Color, title: String, text: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                Text(title).font(Tokens.Font.callout.weight(.semibold)).foregroundStyle(Tokens.Color.textPrimary)
                Text(text).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(tint)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct SecurityRowView: View {
    let row: WorktreeSecurityModel.Row
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
            HStack(spacing: Tokens.Spacing.sm) {
                Image(systemName: symbol).foregroundStyle(tint).accessibilityHidden(true)
                Text(row.title).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textPrimary)
                Spacer(minLength: Tokens.Spacing.xs)
                if !row.details.isEmpty {
                    Button(action: toggle) {
                        HStack(spacing: Tokens.Spacing.xxs) {
                            Text("\(row.details.count)").font(Tokens.Font.pill)
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        }
                        .foregroundStyle(Tokens.Color.textSecondary)
                        .hitTarget()
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel(isExpanded ? "Hide keys" : "Show keys")
                }
            }
            if isExpanded {
                ForEach(row.details, id: \.self) { key in
                    Text(key)
                        .font(Tokens.Font.monoSmall)
                        .foregroundStyle(Tokens.Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .padding(.leading, Tokens.Spacing.xl)
                }
                if let advice = row.advice {
                    Text(advice)
                        .font(Tokens.Font.caption)
                        .foregroundStyle(Tokens.Color.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, Tokens.Spacing.xl)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.title), \(markText)")
    }

    private var symbol: String {
        switch row.mark {
        case .applied: "checkmark.shield"
        case .neutralized: "exclamationmark.shield"
        case .unknown: "xmark.shield"
        }
    }

    private var tint: Color {
        switch row.mark {
        case .applied: Tokens.Color.statusOk
        case .neutralized: Tokens.Color.statusWarning
        case .unknown: Tokens.Color.statusError
        }
    }

    private var markText: String {
        switch row.mark {
        case .applied: "applied"
        case .neutralized: "\(row.details.count) repository settings overridden"
        case .unknown: "could not be confirmed"
        }
    }
}

/// The detail header's `Changes | Worktree` segment (screens.md S-02, S-05). Shown when a worktree is selected.
struct DetailSegmentPicker: View {
    let isWorktree: Bool
    let onChanges: () -> Void
    let onWorktree: () -> Void

    var body: some View {
        Picker(
            "View",
            selection: Binding(
                get: { isWorktree },
                set: { $0 ? onWorktree() : onChanges() })
        ) {
            Text("Changes").tag(false)
            Text("Worktree").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }
}

/// S-05's note on a slow status (#168): why, and `git status` to copy. Overgrove never runs it: refreshing the index is
/// a write, and it could collide with an agent's own git work on `index.lock`.
private struct SlowStatusCard: View {
    let hint: SlowStatusHint

    var body: some View {
        DetailCard {
            Label(hint.short, systemImage: "tortoise")
                .font(Tokens.Font.columnHeader)
                .foregroundStyle(Tokens.Color.statusWarning)
            Text(hint.message)
                .font(Tokens.Font.callout)
                .foregroundStyle(Tokens.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let command = hint.command {
                CopyableCommand(command: command)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
