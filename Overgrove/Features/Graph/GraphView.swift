import SwiftUI

/// The commit graph (S-01 center, #68): column header, the WIP row, and one fixed-height row per commit in a lazy
/// stack, so only visible rows are built (PB-4). The next page loads as the end comes into view.
struct GraphView: View {
    let store: GraphStore
    var now = Date()
    /// Tips of the selected issue's linked branches: outlined, not selected (information-architecture.md §3.2, #82).
    var highlighted: Set<ObjectID> = []

    private var graphWidth: CGFloat { GraphGeometry.width(lanes: store.laneCount) }
    private var headIndex: Int? { store.head.flatMap(store.index(of:)) }

    var body: some View {
        VStack(spacing: 0) {
            GraphColumnHeader(graphWidth: graphWidth)
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    if let wip = store.wip {
                        GraphWipRowView(
                            wip: wip, column: headIndex.map { store.rows[$0].column } ?? 0, hasLine: headIndex != nil,
                            graphWidth: graphWidth)
                    }
                    ForEach(store.rows.indices, id: \.self) { index in
                        row(index)
                            .onAppear { store.rowAppeared(index) }
                    }
                    if store.isLoadingMore {
                        ProgressView().controlSize(.small).frame(height: GraphGeometry.rowHeight)
                    }
                }
            }
        }
        .background(Tokens.Color.surfaceCanvas)
    }

    private func row(_ index: Int) -> some View {
        let commit = store.commits[index]
        let graphRow = store.rows[index]
        let outgoing = index + 1 < store.rows.count ? store.rows[index + 1].incoming : store.pendingSegments
        let wipLine: GraphWipLine =
            if store.wip != nil, let head = headIndex {
                index < head ? .through(store.rows[head].column) : (index == head ? .ends : .none)
            } else {
                .none
            }
        return GraphCommitRowView(
            commit: commit, row: graphRow, outgoing: outgoing, pills: store.pills[commit.oid] ?? [],
            isHead: commit.oid == store.head, isSelected: commit.oid == store.selected,
            isHighlighted: highlighted.contains(commit.oid), wipLine: wipLine, graphWidth: graphWidth, now: now
        ) {
            store.select(commit.oid)
        }
    }
}

/// Refs | Graph | Message | Author | Date | SHA (art-direction.md §5.1).
struct GraphColumnHeader: View {
    let graphWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            title("Refs").frame(width: Tokens.Size.columnRefsIdeal, alignment: .leading)
            title("Graph").frame(width: graphWidth, alignment: .leading)
            title("Message").frame(maxWidth: .infinity, alignment: .leading)
            title("Author").frame(width: Tokens.Size.columnAuthorIdeal, alignment: .leading)
            title("Date").frame(width: Tokens.Size.columnDateIdeal, alignment: .leading)
            title("SHA").frame(width: Tokens.Size.columnShaIdeal, alignment: .leading)
        }
        .frame(height: Tokens.Size.columnHeader)
        .background(Tokens.Color.surfacePanelHeader)
    }

    private func title(_ text: String) -> some View {
        Text(text).font(Tokens.Font.columnHeader).foregroundStyle(Tokens.Color.textSecondary)
            .padding(.horizontal, Tokens.Spacing.sm)
    }
}

/// One commit row (art-direction.md §5.2): selection is the commit's lane color at 16% with a 3pt bar.
struct GraphCommitRowView: View {
    let commit: CommitNode
    let row: GraphRow
    let outgoing: [GraphSegment]
    let pills: [GraphRefPill]
    let isHead: Bool
    let isSelected: Bool
    var isHighlighted = false
    let wipLine: GraphWipLine
    let graphWidth: CGFloat
    let now: Date
    let onSelect: () -> Void

    @Environment(\.issueBadges) private var issues

    /// Issue pills after the subject: only numbers in the fetched list (#82). Unknown `#n` stay plain subject text;
    /// most of them are pull request numbers from squash merges (`(#251)`), not issues.
    private func linkedIssues() -> [Int] {
        CommitLink.issueNumbers(in: commit.subject, repository: issues.repository)
            .filter(issues.isKnown).prefix(2).map { $0 }
    }

    private var lane: Color { Tokens.Color.graphLanes[row.colorIndex % Tokens.Color.graphLanes.count] }

    var body: some View {
        let text = GraphCommitText(commit, now: now)
        // Once per body: it scans the subject.
        let linkedIssues = linkedIssues()
        HStack(spacing: 0) {
            GraphRefsCell(pills: pills, laneColor: lane, laneIndex: row.colorIndex)
                .frame(width: Tokens.Size.columnRefsIdeal, alignment: .trailing)
            GraphLaneCell(
                row: row, outgoing: outgoing, isMerge: commit.isMerge, isHead: isHead, hasRefs: !pills.isEmpty,
                initials: text.initials, avatarIndex: text.avatarIndex, wipLine: wipLine, width: graphWidth)
            HStack(spacing: Tokens.Spacing.xs) {
                Text(text.subject).font(Tokens.Font.body).foregroundStyle(Tokens.Color.textPrimary).lineLimit(1)
                ForEach(linkedIssues, id: \.self) { IssueNumberBadge(number: $0) }
                if text.isAIAssisted { AIBadge() }
            }
            .padding(.horizontal, Tokens.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            cell(text.author, width: Tokens.Size.columnAuthorIdeal, color: Tokens.Color.textSecondary)
            cell(text.date, width: Tokens.Size.columnDateIdeal, color: tertiary).help(text.absoluteDate)
            cell(text.shortSHA, width: Tokens.Size.columnShaIdeal, color: tertiary, font: Tokens.Font.monoSmall)
        }
        .frame(height: GraphGeometry.rowHeight)
        .background(isSelected ? lane.opacity(0.16) : (isHighlighted ? lane.opacity(0.06) : Color.clear))
        .overlay(alignment: .leading) {
            if isSelected { Rectangle().fill(lane).frame(width: 3) }
        }
        .overlay {
            if isHighlighted && !isSelected {
                RoundedRectangle(cornerRadius: Tokens.Radius.sm)
                    .strokeBorder(lane, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                    .padding(1)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(text, linkedIssues: linkedIssues))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .issueBadgeAction(linkedIssues.first)
    }

    private func accessibilityText(_ text: GraphCommitText, linkedIssues: [Int]) -> String {
        var parts: [String] = [text.subject]
        if text.isAIAssisted { parts.append("AI-assisted") }
        parts.append("by \(text.author)")
        parts.append(text.absoluteDate)
        if let pill = pills.first { parts.append("ref \(pill.title)") }
        let issueList = linkedIssues.map(String.init).joined(separator: ", ")
        if !issueList.isEmpty { parts.append("issue \(issueList)") }
        if isHighlighted { parts.append("linked to the selected issue") }
        return parts.joined(separator: ", ")
    }

    /// Tertiary text turns secondary on a selected row (screens.md S-01).
    private var tertiary: Color { isSelected ? Tokens.Color.textSecondary : Tokens.Color.textTertiary }

    private func cell(_ value: String, width: CGFloat, color: Color, font: Font = Tokens.Font.callout) -> some View {
        Text(value).font(font).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, Tokens.Spacing.sm)
            .frame(width: width, alignment: .leading)
    }
}

/// The first ref pill and a `+n` chip for the rest, whose tooltip lists them (art-direction.md §5.5).
struct GraphRefsCell: View {
    let pills: [GraphRefPill]
    let laneColor: Color
    let laneIndex: Int

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            if let first = pills.first {
                GraphRefPillView(pill: first, laneColor: laneColor, laneIndex: laneIndex)
            }
            if pills.count > 1 {
                Text("+\(pills.count - 1)").font(Tokens.Font.caption).foregroundStyle(Tokens.Color.textSecondary)
                    .help(pills.dropFirst().map(\.tooltip).joined(separator: "\n"))
            }
        }
        .padding(.horizontal, Tokens.Spacing.xs)
    }
}

/// Hugs its title; the Refs column (`size.column-refs-ideal`) truncates long names in the middle.
struct GraphRefPillView: View {
    let pill: GraphRefPill
    let laneColor: Color
    let laneIndex: Int

    private var symbol: String? {
        switch pill.kind {
        case .focusedBranch, .worktreeBranch, .focusedDetached, .detachedWorktree: "tree"
        case .remoteBranch: "network"
        case .tag: "tag"
        case .localBranch: nil
        }
    }

    private var fill: Color {
        switch pill.kind {
        case .focusedBranch: laneColor
        case .worktreeBranch, .localBranch: laneColor.opacity(0.2)
        case .tag: Tokens.Color.textTertiary.opacity(0.16)
        case .remoteBranch, .focusedDetached, .detachedWorktree: .clear
        }
    }

    private var border: Color? {
        switch pill.kind {
        case .worktreeBranch, .localBranch, .remoteBranch: laneColor.opacity(0.75)
        case .focusedDetached, .detachedWorktree: Tokens.Color.textTertiary
        case .focusedBranch, .tag: nil
        }
    }

    private var foreground: Color {
        switch pill.kind {
        case .focusedBranch: Tokens.Color.graphOnLanes[laneIndex % Tokens.Color.graphOnLanes.count]
        case .worktreeBranch, .localBranch: Tokens.Color.textPrimary
        case .remoteBranch, .tag, .focusedDetached, .detachedWorktree: Tokens.Color.textSecondary
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .semibold)) }
            Text(pill.title).lineLimit(1).truncationMode(.middle)
            if pill.hasMatchingRemote { Image(systemName: "network").font(.system(size: 9, weight: .semibold)) }
        }
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(foreground)
        .padding(.horizontal, 6)
        .frame(height: Tokens.Size.refPillHeight)
        .background(RoundedRectangle(cornerRadius: 5).fill(fill))
        .overlay {
            if let border { RoundedRectangle(cornerRadius: 5).strokeBorder(border, lineWidth: 1) }
        }
        .help(pill.tooltip)
    }
}

/// `sparkles` + `AI` in a tertiary outline (screens.md S-01): no color, the word carries the meaning.
struct AIBadge: View {
    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "sparkles").font(.system(size: 9, weight: .semibold))
            Text("AI").font(.system(size: 10, weight: .semibold))
        }
        .foregroundStyle(Tokens.Color.textTertiary)
        .padding(.horizontal, 4)
        .frame(height: 15)
        .overlay { RoundedRectangle(cornerRadius: 4).strokeBorder(Tokens.Color.textTertiary, lineWidth: 1) }
        .accessibilityLabel("AI-assisted")
    }
}

/// The WIP row (screens.md S-01): `surface.wip-row`, a dashed folder pill, and the change summary.
struct GraphWipRowView: View {
    let wip: GraphWipRow
    let column: Int
    let hasLine: Bool
    let graphWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 3) {
                Image(systemName: "tree").font(.system(size: 9, weight: .semibold))
                Text(wip.folderName).lineLimit(1).truncationMode(.middle)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Tokens.Color.textSecondary)
            .padding(.horizontal, 6)
            .frame(height: Tokens.Size.refPillHeight)
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Tokens.Color.graphWipNode, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            .padding(.horizontal, Tokens.Spacing.xs)
            .frame(width: Tokens.Size.columnRefsIdeal, alignment: .trailing)
            GraphWipCell(column: column, hasLine: hasLine, width: graphWidth)
            Text(wip.summary).font(Tokens.Font.body).foregroundStyle(Tokens.Color.textPrimary).lineLimit(1)
                .padding(.horizontal, Tokens.Spacing.sm)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: GraphGeometry.rowHeight)
        .background(Tokens.Color.surfaceWipRow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Uncommitted changes in \(wip.folderName): \(wip.summary)")
    }
}
