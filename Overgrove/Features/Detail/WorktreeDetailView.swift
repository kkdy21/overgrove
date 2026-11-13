import AppKit
import SwiftUI

/// S-05, the `Worktree` segment: an info card and the SECURITY card (screens.md S-05, security-review.md §6).
///
/// There is no Fetch button here: fetch is per repository and lives in the toolbar. Nothing here changes the
/// repository (ADR-0011).
struct WorktreeDetailView: View {
    let model: WorktreeDetailModel
    /// The Security card's "Treat as untrusted" toggle (#107); `nil` hides it.
    var onSetUntrusted: ((Bool) -> Void)?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Tokens.Spacing.md) {
                InfoCard(model: model)
                if let pullRequest = model.pullRequest { PullRequestCard(model: pullRequest) }
                if let slow = model.slowStatus {
                    SlowStatusCard(hint: slow)
                }
                if let security = model.security {
                    SecurityCard(model: security, report: model.securityReport, onSetUntrusted: onSetUntrusted)
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

extension View {
    /// Draws this item of a `DetailCard` on the card's colour, over the half gaps around it (#638). Items below a
    /// disclosure in the card come later in its stack, so they are drawn over the rows it inserts: opaque, they slide
    /// down over them and uncover them instead of showing both while the card is still growing.
    func cardOpaque() -> some View {
        background(Tokens.Color.surfaceRaised.padding(.vertical, -Tokens.Spacing.sm / 2))
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
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .fill(Tokens.Color.surfaceRaised)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
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
                            Group {
                                if let items = row.items {
                                    // Folds between items, never inside one, and no line starts or ends with `·` (#612).
                                    JoinedText(items: items, separator: row.itemSeparator)
                                } else {
                                    Text(row.value).lineLimit(2).truncationMode(.middle)
                                }
                            }
                            .font(row.kind == .head ? Tokens.Font.monoSmall : Tokens.Font.callout)
                            .foregroundStyle(
                                row.isDimmed
                                    ? Tokens.Color.textTertiary
                                    : (row.isWarning ? Tokens.Color.statusPrunable : Tokens.Color.textPrimary)
                            )
                            .accessibilityLabel(row.value)
                            if row.kind == .path, let path = model.copyablePath {
                                Button {
                                    // Copying to the clipboard is not a repository write (ADR-0011).
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(path, forType: .string)
                                } label: {
                                    Image(systemName: "doc.on.doc").hitTarget()
                                }
                                .hoverButtonStyle()
                                .toolTip(String(localized: "Copy Path"))
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
    /// `Copy Report` (#110); `nil` hides the button.
    var report: SecurityReport.Source?
    /// "Treat as untrusted" (#107); `nil` hides the toggle.
    var onSetUntrusted: ((Bool) -> Void)?
    @State private var expanded: Set<String> = []
    @Environment(\.rowMenu) private var actions
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DetailCard {
            // One line when it fits; in a narrow panel the check time moves under the title instead of folding beside
            // the copy button (#579).
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: Tokens.Spacing.sm) {
                    title
                    Spacer(minLength: 0)
                    checked.fixedSize()
                    copyButton
                }
                VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                    HStack(alignment: .center, spacing: Tokens.Spacing.sm) {
                        title
                        Spacer(minLength: 0)
                        copyButton
                    }
                    checked
                }
            }
            if let reason = model.blockingReason {
                banner(
                    symbol: "xmark.octagon", tint: Tokens.Color.statusError, title: "Queries stopped",
                    text: SafetyReason.display(reason))
            }
            if let reason = model.failure {
                banner(
                    symbol: "exclamationmark.triangle", tint: Tokens.Color.statusWarning,
                    title: "Configuration not read", text: SafetyReason.display(reason))
            }
            if let reason = model.fetchBlockingReason {
                banner(
                    symbol: "arrow.down.circle", tint: Tokens.Color.statusWarning, title: "Fetch disabled",
                    text: SafetyReason.display(reason))
            }
            if let note = model.limitNote {
                banner(symbol: "list.bullet", tint: Tokens.Color.statusWarning, title: "Report shortened", text: note)
            }
            if let warning = model.localRemoteWarning {
                banner(
                    symbol: "externaldrive.badge.exclamationmark", tint: Tokens.Color.statusWarning,
                    title: "Remotes on this Mac", text: warning)
            }
            if let note = model.untrustedNote {
                banner(symbol: "hand.raised", tint: Tokens.Color.statusWarning, title: "Untrusted", text: note)
            }
            if let onSetUntrusted {
                Toggle(
                    "Treat as untrusted",
                    isOn: Binding(get: { model.isUntrusted }, set: { onSetUntrusted($0) })
                )
                .toggleStyle(.switch)
                .controlSize(.small)
                .font(Tokens.Font.callout)
                .help("Do not fetch remotes on this Mac, and ask before Open in Terminal (#107).")
            }
            ForEach(model.rows) { row in
                SecurityRowView(row: row, isExpanded: expanded.contains(row.id)) {
                    // The keys open with the standard disclosure motion, at once under Reduce Motion (#576).
                    withMotion(.standard, reduceMotion: reduceMotion) {
                        if expanded.contains(row.id) { expanded.remove(row.id) } else { expanded.insert(row.id) }
                    }
                }
                .cardOpaque()
            }
            if !model.others.isEmpty {
                Divider().cardOpaque()
                Text("Other repository settings").font(Tokens.Font.caption).foregroundStyle(Tokens.Color.textTertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .cardOpaque()
                ForEach(model.others) { finding in
                    HStack(spacing: Tokens.Spacing.xs) {
                        Text(finding.key).font(Tokens.Font.monoSmall).foregroundStyle(Tokens.Color.textPrimary)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: Tokens.Spacing.xs)
                        Text(finding.handling).font(Tokens.Font.caption).foregroundStyle(Tokens.Color.textSecondary)
                    }
                    .help(
                        finding.threat.map { String(localized: "Threat \($0) in docs/design/security-review.md") } ?? ""
                    )
                    .accessibilityElement(children: .combine)
                    .cardOpaque()
                }
            }
            Text("Values are never shown. Each setting is overridden where git would use it.")
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Color.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardOpaque()
        }
    }

    /// `Inspected 2 min ago · local and worktree scopes · git 2.50.1` (security-review.md §6).
    private var title: some View {
        Text("Security").font(Tokens.Font.columnHeader).foregroundStyle(Tokens.Color.textPrimary)
    }

    private var checked: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            Text(header(now: context.date))
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Color.textTertiary)
        }
    }

    @ViewBuilder
    private var copyButton: some View {
        if let report {
            Button {
                // Line breaks kept; every other control character escaped (`RowActions.clipboardText`).
                actions.copyMessage(SecurityReport.text(report))
            } label: {
                Image(systemName: "doc.on.doc")
            }
            .hoverButtonStyle()
            .hitTarget()
            .toolTip(
                String(localized: "Copy Report: key names and results only, without values, paths, or remote URLs")
            )
            .accessibilityLabel("Copy security report")
        }
    }

    private func header(now: Date) -> String {
        var parts = [
            String(localized: "Inspected \(StatusBarItem.relative(model.inspectedAt, now: now))"),
            String(localized: "local and worktree scopes"),
        ]
        if let version = model.gitVersion { parts.append(version) }
        return parts.joined(separator: " · ")
    }

    private func banner(symbol: String, tint: Color, title: LocalizedStringKey, text: String) -> some View {
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
                Text(row.displayTitle).font(Tokens.Font.callout).foregroundStyle(Tokens.Color.textPrimary)
                Spacer(minLength: Tokens.Spacing.xs)
                if !row.details.isEmpty {
                    Button(action: toggle) {
                        HStack(spacing: Tokens.Spacing.xxs) {
                            Text("\(row.details.count)").font(Tokens.Font.pill)
                            Image(systemName: "chevron.down")
                                .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        }
                        .foregroundStyle(Tokens.Color.textSecondary)
                        .hitTarget()
                    }
                    .hoverButtonStyle()
                    .accessibilityLabel(isExpanded ? "Hide keys" : "Show keys" as LocalizedStringKey)
                }
            }
            if isExpanded {
                keys.transition(.opacity)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(row.displayTitle), \(markText)")
    }

    private var keys: some View {
        VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
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
        case .applied: String(localized: "applied")
        case .neutralized: String(localized: "\(row.details.count) repository settings overridden")
        case .unknown: String(localized: "could not be confirmed")
        }
    }
}

/// The detail header's `Changes | Worktree` segment (screens.md S-02, S-05). Shown when a worktree is selected.
struct DetailSegmentPicker: View {
    let isWorktree: Bool
    let onChanges: () -> Void
    let onWorktree: () -> Void
    /// Icons only (`list.bullet` / `info.circle`), for a detail panel narrower than `DetailPanel.compactWidth`, so the
    /// header title keeps its room (#618). VoiceOver and the tooltips still say `Changes` and `Worktree`.
    var iconsOnly = false

    var body: some View {
        // Two different controls, so switching widths builds the other one afresh: a segmented control reused across
        // the switch kept the icons in its text segments (#635).
        if iconsOnly {
            DetailIconSegments(isWorktree: isWorktree, onChanges: onChanges, onWorktree: onWorktree)
        } else {
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
            // The panel theme's outline under Increase Contrast (#304); AppKit draws the rest of the control.
            .controlOutline(RoundedRectangle(cornerRadius: Tokens.Radius.sm), normal: nil)
        }
    }
}

/// The icons-only `Changes | Worktree` segment (#618): two icon buttons drawn like a small segmented control. The
/// real segmented control drew each segment's accessibility name as text beside its icon, whether it came from an
/// `Image`'s label or a `Label` drawn `.iconOnly` (#635), and offscreen renders never showed it. Plain buttons draw
/// only the icon, and still give VoiceOver and the tooltip the segment's name.
struct DetailIconSegments: View {
    let isWorktree: Bool
    let onChanges: () -> Void
    let onWorktree: () -> Void
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
        HStack(spacing: 0) {
            segment(String(localized: "Changes"), symbol: "list.bullet", isSelected: !isWorktree, action: onChanges)
            segment(String(localized: "Worktree"), symbol: "info.circle", isSelected: isWorktree, action: onWorktree)
        }
        .padding(1)
        .background(shape.fill(Tokens.Color.surfaceControl))
        // `surface.control` takes a `border.separator` outline in light mode, and `border.strong` under Increase
        // Contrast (#304).
        .controlOutline(shape, normal: colorScheme == .light ? Tokens.Color.borderSeparator : nil)
        .fixedSize()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("View"))
    }

    func segment(
        _ title: String, symbol: String, isSelected: Bool, action: @escaping () -> Void
    ) -> some View {
        Button {
            if !isSelected { action() }
        } label: {
            Image(systemName: symbol)
                .font(Tokens.Font.callout)
                .foregroundStyle(isSelected ? Tokens.Color.textPrimary : Tokens.Color.textSecondary)
                .padding(.horizontal, Tokens.Spacing.xs)
                // With the 1 pt inset on both sides, the control is `size.hit-target-min` tall.
                .frame(minWidth: Tokens.Size.hitTargetMin, minHeight: Tokens.Size.hitTargetMin - 2)
                .background {
                    RoundedRectangle(cornerRadius: Tokens.Radius.sm - 1, style: .continuous)
                        .fill(isSelected ? Tokens.Color.surfaceSelection : Color.clear)
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // The other segment answers the pointer like the panels' icon buttons (#571).
        .hoverHighlight(.rounded(radius: Tokens.Radius.sm - 1), isEnabled: !isSelected)
        // An AppKit tooltip: `.help` here stayed up or stopped appearing (#658, `toolTip(_:)`).
        .toolTip(title)
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
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
