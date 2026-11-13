import SwiftUI

/// The commit graph (S-01 center, #68): column header, the WIP row, and one fixed-height row per commit in a lazy
/// stack, so only visible rows are built (PB-4). The next page loads as the end comes into view.
///
/// Keyboard (interaction.md §3.1, #73): `↑`/`↓` move the selection, `⌘↑` goes to the WIP row (or the first commit),
/// `⌘↓` to the last loaded commit, `⏎` moves focus to the detail panel, and `⌘J` scrolls to HEAD.
struct GraphView: View {
    let store: GraphStore
    /// A row was clicked (S-03, #69); without one, the row is only highlighted.
    var onSelectCommit: ((ObjectID) -> Void)?
    var now = Date()
    /// Tips of the selected issue's linked branches: outlined, not selected (information-architecture.md §3.2, #82).
    var highlighted: Set<ObjectID> = []
    /// `⌘↑` with a WIP row: the focused worktree's changes.
    var onSelectWip: (() -> Void)?
    /// `⏎`: focus the detail panel.
    var onOpen: () -> Void = {}
    /// The toolbar search (#74): rows that do not match are dimmed, not hidden, so the graph keeps its shape.
    var search: GraphSearchResult?
    var onFindNext: () -> Void = {}
    var onFindPrevious: () -> Void = {}
    /// The author chip's commits (#255): other rows are dimmed like non-matches; `nil` for `All`.
    var authorMatches: Set<ObjectID>?
    /// Column widths and visibility (#255).
    var columns: GraphColumnLayout = .default
    /// A finished column change: saved per repository.
    var onCommitColumns: (GraphColumnLayout) -> Void = { _ in }
    /// Stashes drawn above their base commits (#384); empty when `Show Stashes` is off.
    var stashes: [Stash] = []
    var selectedStash: ObjectID?
    var onSelectStash: (ObjectID) -> Void = { _ in }
    /// The WIP row is the primary selection (`selection == .wip`): it shows the accent bar (#574).
    var isWipSelected = false

    @FocusState private var hasFocus: Bool
    @Environment(\.rowMenu) private var rowMenu
    @Environment(\.graphZoom) private var zoom
    /// The layout while a column divider is dragged; committed on release.
    @State private var dragColumns: GraphColumnLayout?
    @State private var dragBase: GraphColumnLayout?
    @State private var panelWidth: CGFloat = 0
    /// How far the lanes are scrolled sideways (more than `size.graph-max-lanes-visible` lanes).
    @State private var laneOffset: CGFloat = 0

    /// The stored (or dragged) layout fitted to the panel so Message keeps its minimum (#574), and how many lanes the
    /// Graph column shows (#603). Widths are stored at 100 %; the panel and the graph column are measured at the zoom.
    private var fit: (columns: GraphColumnLayout, lanes: Int) {
        let layout = dragColumns ?? columns
        guard panelWidth > 0 else { return (layout, Tokens.Size.graphMaxLanesVisible) }
        let panel = panelWidth / zoom.scale
        let fitted = layout.fitting(panel: panel, lanes: store.laneCount)
        return (fitted, fitted.visibleLanes(panelWidth: panel, lanes: store.laneCount))
    }
    private var geometry: GraphGeometry { zoom.geometry.showing(lanes: fit.lanes) }
    private var graphWidth: CGFloat { geometry.width(lanes: store.laneCount) }
    private var headIndex: Int? { store.head.flatMap(store.index(of:)) }
    private var shownColumns: GraphColumnLayout { fit.columns }
    private var laneScroll: GraphLaneScroll {
        GraphLaneScroll(offset: laneOffset, lanes: store.laneCount, geometry: geometry)
    }
    private var isDimming: Bool { search != nil || authorMatches != nil }

    private func isBright(_ oid: ObjectID) -> Bool {
        (search?.matchSet.contains(oid) ?? true) && (authorMatches?.contains(oid) ?? true)
    }

    var body: some View {
        VStack(spacing: 0) {
            if let search {
                GraphSearchBar(result: search, onPrevious: onFindPrevious, onNext: onFindNext)
            }
            GraphColumnHeader(
                columns: shownColumns, graphWidth: graphWidth, laneScroll: laneScroll, onResize: resize,
                onResizeEnded: endResize, onFit: fit, onStep: { onCommitColumns(columns.resizing($0, by: $1)) },
                onScrollLanes: scrollLanes)
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        if let wip = store.wip {
                            GraphWipRowView(
                                wip: wip, column: headIndex.map { store.rows[$0].column } ?? 0,
                                hasLine: headIndex != nil, isSelected: isWipSelected,
                                graphWidth: graphWidth, refsWidth: shownColumns.width(of: .refs) * zoom.scale,
                                laneOffset: laneScroll.offset
                            )
                            .id(Self.wipRowID)
                            // interaction.md §2: clicking the WIP row selects the worktree's changes (#311).
                            .contentShape(Rectangle())
                            .onTapGesture { onSelectWip?() }
                            .accessibilityAction { onSelectWip?() }
                            .accessibilityAddTraits(.isButton)
                            .contextMenu { wipMenu }
                            .opacity(isDimming ? Tokens.Opacity.disabled : 1)
                        }
                        // Hidden while searching or filtering by author: the dimmed graph shows matches only.
                        let stashRows =
                            isDimming
                            ? [:] : GraphStashPlacement.byBaseRow(stashes, index: { store.index(of: $0) })
                        ForEach(store.rows.indices, id: \.self) { index in
                            if let above = stashRows[index] {
                                ForEach(Array(above.enumerated()), id: \.element.oid) { position, stash in
                                    stashRow(stash, baseIndex: index, hasStashAbove: position > 0)
                                }
                            }
                            row(index, hasStashAbove: stashRows[index] != nil)
                                .onAppear { store.rowAppeared(index) }
                        }
                        if store.isLoadingMore {
                            ProgressView().controlSize(.small).frame(height: geometry.rowHeight)
                        }
                    }
                }
                .onChange(of: store.scrollTarget) { _, target in
                    guard let target, let index = store.index(of: target.oid) else { return }
                    proxy.scrollTo(index, anchor: .center)
                }
                // Zooming keeps the selected commit in view (#121): every row changes height.
                .onChange(of: zoom) {
                    laneOffset = geometry.clampOffset(laneOffset, lanes: store.laneCount)
                    reveal(store.selected)
                    guard let selected = store.selected, let index = store.index(of: selected) else { return }
                    proxy.scrollTo(index, anchor: .center)
                }
                .overlay(alignment: .topLeading) {
                    // Sideways swipes over the Graph column move the lanes (#255); the rest scroll the rows.
                    GraphLaneScrollMonitor(isEnabled: laneScroll.maxOffset > 0, lane: geometry.lane) {
                        scrollLanes(laneScroll.offset + $0)
                    }
                    .frame(width: graphWidth)
                    .frame(maxHeight: .infinity)
                    .padding(.leading, shownColumns.width(of: .refs) * zoom.scale)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
        }
        .onGeometryChange(for: CGFloat.self) {
            $0.size.width
        } action: {
            panelWidth = $0
        }
        // A commit picked in a lane scrolled out of sight comes into view.
        .onAppear { reveal(store.selected) }
        .onChange(of: store.selected) { _, selected in reveal(selected) }
        .background(Tokens.Color.surfaceCanvas)
        .focusable()
        .focused($hasFocus)
        .focusEffectDisabled()
        .focusOnRequest([.center], $hasFocus)
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            move(down: press.key == .downArrow, toEnd: press.modifiers.contains(.command))
        }
        .onKeyPress(.return) {
            onOpen()
            return .handled
        }
    }

    /// The WIP row's id in the scroll view; commit rows use their index.
    private static let wipRowID = -1

    // MARK: Columns and lanes

    /// `delta` is the width change since the drag began.
    private func resize(_ column: GraphColumnLayout.Column, by delta: CGFloat) {
        // From the widths on screen, so the divider follows the pointer at once (#603).
        let base = dragBase ?? columns.adoptingWidths(from: shownColumns)
        dragBase = base
        // Widths are stored at 100 %; the panel and the graph column are measured at the zoom (#121).
        dragColumns = base.resizing(
            column, by: delta, panelWidth: panelWidth / zoom.scale, graphWidth: graphWidth / zoom.scale)
    }

    private func endResize() {
        guard let final = dragColumns else { return }
        dragColumns = nil
        dragBase = nil
        onCommitColumns(final)
    }

    private func fit(_ column: GraphColumnLayout.Column) {
        let widths = GraphColumnFit.contentWidths(column, commits: store.commits[...], pills: store.pills, now: now)
        onCommitColumns(columns.setting(column, to: GraphColumnLayout.fittedWidth(column, contentWidths: widths)))
    }

    private func reveal(_ oid: ObjectID?) {
        guard laneScroll.maxOffset > 0, let oid, let index = store.index(of: oid) else { return }
        laneOffset = geometry.revealing(store.rows[index].column, offset: laneOffset, lanes: store.laneCount)
    }

    private func scrollLanes(_ offset: CGFloat) {
        laneOffset = geometry.clampOffset(offset, lanes: store.laneCount)
    }

    @ViewBuilder
    private var wipMenu: some View {
        if let path = rowMenu.focusedWorktree {
            Button("Show Changes") { rowMenu.showWorktreeChanges(path) }
            Button("Show Worktree Info") { rowMenu.showWorktreeInfo(path) }
        }
    }

    private func select(_ oid: ObjectID) {
        if let onSelectCommit { onSelectCommit(oid) } else { store.select(oid) }
        store.scroll(to: oid)
    }

    private func move(down: Bool, toEnd: Bool) -> KeyPress.Result {
        guard !store.commits.isEmpty else { return .ignored }
        let current = store.selected.flatMap(store.index(of:))
        if toEnd {
            if down {
                select(store.commits[store.commits.count - 1].oid)
            } else if store.wip != nil, let onSelectWip {
                onSelectWip()
            } else {
                select(store.commits[0].oid)
            }
            return .handled
        }
        let next: Int =
            if let current {
                min(max(current + (down ? 1 : -1), 0), store.commits.count - 1)
            } else {
                down ? 0 : store.commits.count - 1
            }
        if next != current { select(store.commits[next].oid) }
        return .handled
    }

    private func wipLine(at index: Int) -> GraphWipLine {
        guard store.wip != nil, let head = headIndex else { return .none }
        return index < head ? .through(store.rows[head].column) : (index == head ? .ends : .none)
    }

    /// A stash above the commit at `baseIndex` (#384): the lanes between that commit and the one above pass through.
    private func stashRow(_ stash: Stash, baseIndex: Int, hasStashAbove: Bool) -> some View {
        let base = store.rows[baseIndex]
        let wipColumn: Int? = wipLine(at: baseIndex) == .none ? nil : headIndex.map { store.rows[$0].column }
        return GraphStashRowView(
            stash: stash, column: base.column, colorIndex: base.colorIndex, through: base.incoming,
            wipColumn: wipColumn, hasStashAbove: hasStashAbove, isSelected: stash.oid == selectedStash,
            graphWidth: graphWidth, now: now, columns: shownColumns, laneOffset: laneScroll.offset
        ) {
            onSelectStash(stash.oid)
        }
    }

    private func row(_ index: Int, hasStashAbove: Bool = false) -> some View {
        let commit = store.commits[index]
        let graphRow = store.rows[index]
        let outgoing = index + 1 < store.rows.count ? store.rows[index + 1].incoming : store.pendingSegments
        let wipLine = wipLine(at: index)
        return GraphCommitRowView(
            commit: commit, row: graphRow, outgoing: outgoing, pills: store.pills[commit.oid] ?? [],
            isHead: commit.oid == store.head, isSelected: commit.oid == store.selected,
            isHighlighted: highlighted.contains(commit.oid), wipLine: wipLine, graphWidth: graphWidth, now: now,
            isListFocused: hasFocus, columns: shownColumns, laneOffset: laneScroll.offset,
            hasStashAbove: hasStashAbove
        ) {
            if let onSelectCommit { onSelectCommit(commit.oid) } else { store.select(commit.oid) }
        }
        .contextMenu { CommitRowMenu(commit: commit, onShowChanges: { select(commit.oid) }) }
        .opacity(isBright(commit.oid) ? 1 : Tokens.Opacity.disabled)
    }
}

/// Under the graph header while searching: how many loaded commits match, a note that only loaded pages are searched,
/// and previous / next (screens.md S-01, #74).
struct GraphSearchBar: View {
    let result: GraphSearchResult
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        HStack(spacing: Tokens.Spacing.sm) {
            Image(systemName: "magnifyingglass").foregroundStyle(Tokens.Color.textTertiary).accessibilityHidden(true)
            Text(result.summary)
                .font(Tokens.Font.callout)
                .foregroundStyle(Tokens.Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(result.summary)
            Spacer(minLength: Tokens.Spacing.sm)
            Button(action: onPrevious) { Image(systemName: "chevron.up") }
                .help("Find Previous (⌘⇧G)")
                .accessibilityLabel("Previous match")
            Button(action: onNext) { Image(systemName: "chevron.down") }
                .help("Find Next (⌘G)")
                .accessibilityLabel("Next match")
        }
        .buttonStyle(.borderless)
        .disabled(result.matches.isEmpty)
        .padding(.horizontal, Tokens.Spacing.md)
        .frame(height: Tokens.Size.columnHeader)
        .background(Tokens.Color.surfacePanelHeader)
        .overlay(alignment: .bottom) { Tokens.Color.borderSeparator.frame(height: 1) }
        .accessibilityElement(children: .contain)
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
    /// The selection is lane colour at 16% while the graph has keyboard focus and 10% when it does not
    /// (interaction.md §1.2: inactive selection is dimmer).
    var isListFocused = true
    var columns: GraphColumnLayout = .default
    var laneOffset: CGFloat = 0
    var hasStashAbove = false
    let onSelect: () -> Void

    @Environment(\.issueBadges) private var issues
    @Environment(\.graphZoom) private var zoom

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
                .frame(width: columns.width(of: .refs) * zoom.scale, alignment: .trailing)
                .clipped()
            GraphLaneCell(
                row: row, outgoing: outgoing, isMerge: commit.isMerge, isHead: isHead, hasRefs: !pills.isEmpty,
                initials: text.initials, avatarIndex: text.avatarIndex, wipLine: wipLine, width: graphWidth,
                offset: laneOffset, hasStashAbove: hasStashAbove)
            HStack(spacing: Tokens.Spacing.xs) {
                Text(text.subject).font(zoom.typography.body).foregroundStyle(Tokens.Color.textPrimary).lineLimit(1)
                ForEach(linkedIssues, id: \.self) { IssueNumberBadge(number: $0) }
                if text.isAIAssisted { AIBadge() }
            }
            .padding(.horizontal, Tokens.Spacing.sm)
            // Message takes what the fixed columns leave: badges never push Author, Date, and SHA out of line (#574).
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            .clipped()
            .layoutPriority(-1)
            if columns.isVisible(.author) {
                cell(text.author, width: columns.width(of: .author) * zoom.scale, color: Tokens.Color.textSecondary)
            }
            if columns.isVisible(.date) {
                cell(text.date, width: columns.width(of: .date) * zoom.scale, color: tertiary).help(text.absoluteDate)
            }
            if columns.isVisible(.sha) {
                cell(
                    text.shortSHA, width: columns.width(of: .sha) * zoom.scale, color: tertiary,
                    font: zoom.typography.monoSmall)
            }
        }
        .frame(height: zoom.geometry.rowHeight)
        // art-direction.md §5.2: `surface.hover` under the pointer; a selected row keeps its tint (#574).
        .hoverHighlight(.fullWidth, isEnabled: !isSelected)
        .background(
            isSelected
                ? lane.opacity(isListFocused ? Tokens.Graph.selectionOpacity : Tokens.Graph.selectionInactiveOpacity)
                : (isHighlighted ? lane.opacity(Tokens.Graph.highlightOpacity) : Color.clear)
        )
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
        .accessibilityLabel(
            GraphRowAccessibility.label(
                commit: commit, text: text, pills: pills, isHead: isHead, linkedIssues: linkedIssues,
                isHighlighted: isHighlighted, now: now)
        )
        .accessibilityHint(GraphRowAccessibility.hint(commit))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .issueBadgeAction(linkedIssues.first)
    }

    /// Tertiary text turns secondary on a selected row (screens.md S-01).
    private var tertiary: Color { isSelected ? Tokens.Color.textSecondary : Tokens.Color.textTertiary }

    private func cell(_ value: String, width: CGFloat, color: Color, font: Font? = nil) -> some View {
        Text(value).font(font ?? zoom.typography.callout).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, Tokens.Spacing.sm)
            .frame(width: width, alignment: .leading)
    }
}

/// The first ref pill and a `+n` chip for the rest, whose tooltip lists them (art-direction.md §5.5).
struct GraphRefsCell: View {
    let pills: [GraphRefPill]
    let laneColor: Color
    let laneIndex: Int

    @Environment(\.graphZoom) private var zoom

    var body: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            if let first = pills.first {
                GraphRefPillView(pill: first, laneColor: laneColor, laneIndex: laneIndex)
            }
            if pills.count > 1 {
                Text("+\(pills.count - 1)").font(zoom.typography.caption).foregroundStyle(Tokens.Color.textSecondary)
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

    @Environment(\.colorSchemeContrast) private var contrast
    @Environment(\.graphZoom) private var zoom

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
        case .worktreeBranch, .localBranch, .remoteBranch:
            laneColor.opacity(Tokens.refMarkOpacity(contrast, normal: Tokens.Graph.refPillBorderOpacity))
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
            if let symbol { Image(systemName: symbol).font(zoom.typography.points(9, weight: .semibold)) }
            Text(pill.title).lineLimit(1).truncationMode(.middle)
            if pill.hasMatchingRemote {
                Image(systemName: "network").font(zoom.typography.points(9, weight: .semibold))
            }
        }
        .font(zoom.typography.points(11, weight: .medium))
        .foregroundStyle(foreground)
        .padding(.horizontal, 6)
        .frame(height: Tokens.Size.refPillHeight * zoom.scale)
        .background(RoundedRectangle(cornerRadius: 5).fill(fill))
        .overlay {
            if let border { RoundedRectangle(cornerRadius: 5).strokeBorder(border, lineWidth: 1) }
        }
        .help(pill.tooltip)
    }
}

/// `sparkles` + `AI` in a tertiary outline (screens.md S-01): no color, the word carries the meaning.
struct AIBadge: View {
    @Environment(\.graphZoom) private var zoom

    var body: some View {
        HStack(spacing: Tokens.Spacing.xxs) {
            Image(systemName: "sparkles").font(zoom.typography.points(9, weight: .semibold))
            Text("AI").font(zoom.typography.points(10, weight: .semibold))
        }
        .foregroundStyle(Tokens.Color.textTertiary)
        .padding(.horizontal, Tokens.Spacing.xs)
        .frame(height: Self.height * zoom.scale)
        .controlOutline(
            RoundedRectangle(cornerRadius: Tokens.Radius.sm), normal: Tokens.Color.textTertiary,
            increased: Tokens.Color.textTertiary
        )
        .accessibilityLabel("AI-assisted")
    }

    /// Shorter than a ref pill so it reads as a tag on the subject; no token.
    static let height: CGFloat = 15
}

/// The WIP row (screens.md S-01): `surface.wip-row`, a dashed folder pill, and the change summary.
struct GraphWipRowView: View {
    let wip: GraphWipRow
    let column: Int
    let hasLine: Bool
    /// `selection == .wip` (art-direction.md §5.2: a 3pt accent bar at the left edge, #574).
    var isSelected = false
    let graphWidth: CGFloat
    var refsWidth = Tokens.Size.columnRefsIdeal
    var laneOffset: CGFloat = 0

    @Environment(\.graphZoom) private var zoom

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 3) {
                Image(systemName: "tree").font(zoom.typography.points(9, weight: .semibold))
                Text(wip.folderName).lineLimit(1).truncationMode(.middle)
            }
            .font(zoom.typography.points(11, weight: .medium))
            .foregroundStyle(Tokens.Color.textSecondary)
            .padding(.horizontal, 6)
            .frame(height: Tokens.Size.refPillHeight * zoom.scale)
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Tokens.Color.graphWipNode, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
            }
            .padding(.horizontal, Tokens.Spacing.xs)
            .frame(width: refsWidth, alignment: .trailing)
            .clipped()
            GraphWipCell(column: column, hasLine: hasLine, width: graphWidth, offset: laneOffset)
            Text(wip.summary).font(zoom.typography.body).foregroundStyle(Tokens.Color.textPrimary).lineLimit(1)
                .padding(.horizontal, Tokens.Spacing.sm)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
                .clipped()
                .layoutPriority(-1)
        }
        .frame(height: zoom.geometry.rowHeight)
        .hoverHighlight(.fullWidth, isEnabled: !isSelected)
        .background(Tokens.Color.surfaceWipRow)
        .overlay(alignment: .leading) {
            if isSelected { Rectangle().fill(Tokens.Color.accent).frame(width: 3) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(wip.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A commit row's menu (interaction.md §5): copy and show only.
struct CommitRowMenu: View {
    let commit: CommitNode
    let onShowChanges: () -> Void

    @Environment(\.rowMenu) private var actions

    var body: some View {
        Button("Show Changes", action: onShowChanges)
        // S-12 (#388): against the commit the detail panel shows.
        Button("Compare with Selected Commit") { actions.compareCommit(commit.oid) }
            .disabled(!actions.canCompareCommit(commit.oid))
        Divider()
        Button("Copy SHA") { actions.copy(commit.oid.hex) }
        Button("Copy Short SHA") { actions.copy(commit.oid.short) }
        Button("Copy Message") { actions.copyMessage(actions.commitMessage(commit)) }
        Divider()
        let url = actions.gitHubCommitURL(commit.oid)
        Button("Open on GitHub") { if let url { actions.openInBrowser(url) } }
            .disabled(url == nil)
    }
}
