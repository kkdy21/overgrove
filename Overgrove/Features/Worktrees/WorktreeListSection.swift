import SwiftUI

/// The sidebar's WORKTREES section (screens.md S-01, information-architecture.md §4, art-direction.md §6).
///
/// Click a row, or move with `↑`/`↓` while the list has keyboard focus, to focus that worktree; its changes open in
/// the detail panel (S-02, #66). `⌘↑`/`⌘↓` jump to the first and last rows.
struct WorktreeListSection: View {
    let status: WorktreeListStatus
    let model: WorktreeListModel?
    let selectedPath: GitPath?
    let onSelect: (GitPath) -> Void
    /// `Compare with Base` in the row's context menu (#158); `nil` for rows that cannot be compared.
    var canCompare: (GitPath) -> Bool = { _ in false }
    var onCompare: (GitPath) -> Void = { _ in }

    @State private var isExpanded = true
    @FocusState private var hasFocus: Bool
    @Namespace private var rotor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarSectionHeader(title: "WORKTREES", count: model?.rows.count, isExpanded: $isExpanded)
            if isExpanded { content }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch status {
        case .idle, .loading:
            HStack(spacing: Tokens.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Loading worktrees…")
            }
            .font(Tokens.Font.callout)
            .foregroundStyle(Tokens.Color.textSecondary)
            .padding(.horizontal, Tokens.Spacing.md)
            .frame(height: Tokens.Size.rowSidebar)
        case .failed(let message):
            SidebarNotice(symbol: "exclamationmark.triangle", text: message)
        case .snapshot(let snapshot):
            snapshotRows(snapshot)
        case .loaded:
            if let model { rows(model) }
        }
    }

    /// The last session's rows while the first load runs (ADR-0018 §5): an `Updating…` line, then the rows without
    /// selection, menus, or actions.
    private func snapshotRows(_ snapshot: WorktreeListModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: Tokens.Spacing.sm) {
                ProgressView().controlSize(.small)
                Text("Updating…")
            }
            .font(Tokens.Font.callout)
            .foregroundStyle(Tokens.Color.textSecondary)
            .padding(.horizontal, Tokens.Spacing.md)
            .frame(height: Tokens.Size.rowSidebar)
            .accessibilityElement(children: .combine)
            ForEach((model ?? snapshot).rows) { row in
                WorktreeRowView(row: row, isSelected: false, isListFocused: false)
                    .opacity(Tokens.Opacity.stale)
            }
        }
        .allowsHitTesting(false)
    }

    private func rows(_ model: WorktreeListModel) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if let warning = model.warning {
                SidebarNotice(symbol: "exclamationmark.triangle", text: warning)
            }
            ForEach(model.rows) { row in
                WorktreeRowView(row: row, isSelected: row.id == selectedPath, isListFocused: hasFocus)
                    .contentShape(Rectangle())
                    .onTapGesture { onSelect(row.id) }
                    .contextMenu {
                        WorktreeRowMenu(
                            row: row, canCompare: canCompare(row.id), onCompare: { onCompare(row.id) })
                    }
                    .accessibilityAction { onSelect(row.id) }
                    .accessibilityRotorEntry(id: row.id, in: rotor)
            }
        }
        // VoiceOver's rotor jumps between worktrees (interaction.md §6.1).
        .accessibilityRotor("Worktrees") {
            ForEach(model.rows) { row in AccessibilityRotorEntry(Text(row.title), id: row.id, in: rotor) }
        }
        .focusable()
        .focused($hasFocus)
        .focusEffectDisabled()
        .focusOnRequest([.sidebar], $hasFocus)
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            move(in: model, press: press)
        }
    }

    private func move(in model: WorktreeListModel, press: KeyPress) -> KeyPress.Result {
        let ids = model.rows.map(\.id)
        guard !ids.isEmpty else { return .ignored }
        let down = press.key == .downArrow
        let target: GitPath
        if press.modifiers.contains(.command) {
            target = down ? ids[ids.count - 1] : ids[0]
        } else if let current = selectedPath, let index = ids.firstIndex(of: current) {
            target = ids[min(max(index + (down ? 1 : -1), 0), ids.count - 1)]
        } else {
            target = ids[0]
        }
        if target != selectedPath { onSelect(target) }
        return .handled
    }
}

/// A collapsible section header: chevron, upper-case title, count chip (art-direction.md §6).
struct SidebarSectionHeader: View {
    let title: String
    let count: Int?
    @Binding var isExpanded: Bool
    /// A small spinner after the title (ISSUES while gh runs, screens.md S-06).
    var isLoading = false

    var body: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: Tokens.Spacing.xs) {
                Image(systemName: "chevron.down")
                    .rotationEffect(.degrees(isExpanded ? 0 : -90))
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Color.textTertiary)
                Text(title)
                    .font(Tokens.Font.sectionHeader)
                    .tracking(Tokens.Font.sectionHeaderTracking)
                    .foregroundStyle(Tokens.Color.textTertiary)
                if isLoading {
                    ProgressView().controlSize(.mini).accessibilityLabel("Loading")
                }
                Spacer()
                if let count {
                    Text(WorktreeListModel.badgeText(count))
                        .font(Tokens.Font.pill)
                        .foregroundStyle(Tokens.Color.textSecondary)
                        .padding(.horizontal, Tokens.Spacing.xs + Tokens.Spacing.xxs)
                        .background(Capsule().fill(Tokens.Color.surfaceRaised))
                }
            }
            .padding(.horizontal, Tokens.Spacing.md)
            .frame(height: Self.height)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title.capitalized), \(count ?? 0) items")
        .accessibilityValue(isExpanded ? "expanded" : "collapsed")
    }

    /// art-direction.md §6: section headers are 30pt high. No size token for them.
    static let height: CGFloat = 30
}

/// A one-line note inside a section: a load failure, or a parser warning that does not block the list.
struct SidebarNotice: View {
    let symbol: String
    let text: String

    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol).foregroundStyle(Tokens.Color.statusPrunable)
        }
        .font(Tokens.Font.caption)
        .foregroundStyle(Tokens.Color.textSecondary)
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, Tokens.Spacing.xs)
        .accessibilityElement(children: .combine)
    }
}

/// One two-line worktree row (art-direction.md §6).
struct WorktreeRowView: View {
    let row: WorktreeRow
    let isSelected: Bool
    let isListFocused: Bool

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.pullRequestBadges) private var pullRequests

    var body: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            tile
            VStack(alignment: .leading, spacing: Tokens.Spacing.xxs) {
                HStack(spacing: Tokens.Spacing.xs) {
                    Text(row.title)
                        .font(row.isFocused ? Tokens.Font.bodyEmphasized : Tokens.Font.body)
                        .foregroundStyle(row.isDimmed ? Tokens.Color.textTertiary : Tokens.Color.textPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: Tokens.Spacing.xs)
                    // Lowest priority (§4.3, 7): leftmost, the first to give way.
                    if let pullRequest { PullRequestPill(badge: pullRequest) }
                    if let number = row.issueNumber { IssueNumberBadge(number: number) }
                    // Highest priority at the trailing edge; the leading (lowest) badges give way first.
                    ForEach(Array(row.badges.reversed().enumerated()), id: \.offset) { _, badge in
                        BadgeView(badge: badge)
                    }
                }
                secondLine
            }
        }
        .padding(.horizontal, Tokens.Spacing.sm)
        .frame(height: Tokens.Size.rowWorktree)
        .background {
            if isSelected {
                let shape = RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                shape
                    .fill(isListFocused ? Tokens.Color.surfaceSelection : Tokens.Color.surfaceSelectionInactive)
                    .overlay {
                        // The branch's lane colour, so the selection reads as the same line in the graph (#300).
                        if let lane = laneColor {
                            shape.strokeBorder(
                                lane.opacity(
                                    Tokens.refMarkOpacity(contrast, normal: Tokens.Graph.worktreeSelectionBorderOpacity)
                                ),
                                lineWidth: Tokens.controlOutlineWidth(contrast))
                        }
                    }
            }
        }
        .padding(.horizontal, Tokens.Spacing.xs + Tokens.Spacing.xxs)
        .help(row.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel + (pullRequest.map { ", " + $0.accessibilityText } ?? ""))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .issueBadgeAction(row.issueNumber)
    }

    private var pullRequest: PullRequestBadge? { pullRequests.badge(forBranch: row.branchRef) }

    @ViewBuilder
    private var secondLine: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            if row.isMain && !row.isSubtitleWarning {
                Text("main worktree")
                    .font(Tokens.Font.pill)
                    .foregroundStyle(Tokens.Color.textSecondary)
                    .padding(.horizontal, Tokens.Spacing.xs)
                    .controlOutline(Capsule())
            }
            if let subtitle = row.subtitle {
                Text(subtitle)
                    .font(Tokens.Font.caption)
                    .foregroundStyle(row.isSubtitleWarning ? Tokens.Color.statusPrunable : Tokens.Color.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
    }

    /// 22pt tile with the `tree` symbol: the branch tip's lane colour at 18% with a lane-coloured `tree`, so the row
    /// and its line in the graph read as one (art-direction.md §6, #255). Detached and missing worktrees, and tips
    /// not loaded yet, stay neutral. The focused worktree gets an accent dot at the top right.
    private var tile: some View {
        let lane = laneColor
        return RoundedRectangle(cornerRadius: Tokens.Radius.sm, style: .continuous)
            .fill(lane.map { $0.opacity(Self.tileLaneOpacity) } ?? Tokens.Color.surfaceRaised)
            .frame(width: Self.tileSize, height: Self.tileSize)
            .overlay {
                Image(systemName: "tree")
                    .font(Tokens.Font.caption)
                    .foregroundStyle(
                        lane ?? (row.hasNeutralTile ? Tokens.Color.textTertiary : Tokens.Color.textSecondary))
            }
            .overlay(alignment: .topTrailing) {
                if row.isFocused {
                    Circle()
                        .fill(Tokens.Color.accent)
                        .frame(width: Self.focusDotSize, height: Self.focusDotSize)
                        .overlay(Circle().strokeBorder(Tokens.Color.surfacePanel, lineWidth: 2))
                        .offset(x: Self.focusDotSize / 3, y: -Self.focusDotSize / 3)
                }
            }
            .accessibilityHidden(true)
    }

    /// The branch tip's lane colour; `nil` for detached and missing worktrees and tips not loaded yet.
    private var laneColor: Color? {
        row.laneIndex.map { Tokens.Color.graphLanes[$0 % Tokens.Color.graphLanes.count] }
    }

    /// art-direction.md §6: 22pt tile, 8pt focus dot. No size tokens for them.
    static let tileSize: CGFloat = 22
    static let focusDotSize: CGFloat = 8
    /// art-direction.md §6: lane colour at 18%. No opacity token for it.
    static let tileLaneOpacity = 0.18
}

/// A row badge (information-architecture.md §4.3): symbol and number together, never colour alone.
struct BadgeView: View {
    let badge: WorktreeRow.Badge

    var body: some View {
        HStack(spacing: Tokens.Spacing.xxs) {
            if let symbol = badge.symbol { Image(systemName: symbol) }
            if let text = badge.text { Text(text) }
        }
        .font(Tokens.Font.pill)
        .foregroundStyle(color)
        .fixedSize()
        .accessibilityHidden(true)
    }

    private var color: Color {
        switch badge {
        case .conflicts: Tokens.Color.statusConflicted
        case .prunable: Tokens.Color.statusPrunable
        case .changed: Tokens.Color.textSecondary
        case .ahead: Tokens.Color.statusAhead
        case .behind: Tokens.Color.statusBehind
        case .locked: Tokens.Color.statusLocked
        }
    }
}

/// A worktree row's menu (interaction.md §5): show, copy, Reveal in Finder, and Open in Terminal. Nothing removes,
/// locks, or prunes a worktree.
private struct WorktreeRowMenu: View {
    let row: WorktreeRow
    let canCompare: Bool
    let onCompare: () -> Void

    @Environment(\.rowMenu) private var actions

    var body: some View {
        Button("Show Changes") { actions.showWorktreeChanges(row.id) }
        Button("Show Info") { actions.showWorktreeInfo(row.id) }
        Button("Compare with Base", action: onCompare).disabled(!canCompare)
        Divider()
        Button("Copy Path") { actions.copy(row.id.display) }
        Button("Copy Branch Name") { if let branch = row.branchName { actions.copy(branch) } }
            .disabled(row.branchName == nil)
        Divider()
        // A missing folder has nothing to show (§4.4); a path that is not valid UTF-8 has no file actions.
        Button("Reveal in Finder") { actions.revealWorktree(row.id) }
            .disabled(row.isDimmed || !row.id.isRepresentable)
        Button("Open in Terminal") { actions.openTerminal(row.id) }
            .disabled(row.isDimmed || !row.id.isRepresentable)
        if actions.hasEditor {
            Button("Open in Editor") { actions.openEditor(row.id) }
                .disabled(row.isDimmed || !row.id.isRepresentable)
        }
    }
}
