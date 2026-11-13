import SwiftUI

/// S-09, a file's history in the center (screens.md S-09): `‹ Graph`, the path, Follow renames, then one row per commit
/// in a lazy stack that loads more near the end. A click shows the commit in S-03; ⏎ or a double click opens its diff
/// of the file (S-10); ↑/↓ move the selection; ⎋ goes back to the graph.
struct FileHistoryView: View {
    let store: FileHistoryStore
    let onBack: () -> Void
    let onSelect: (FileHistoryEntry) -> Void
    let onOpen: (FileHistoryEntry) -> Void
    var now = Date()

    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            GeometryReader { proxy in
                let layout = FileHistoryColumns(width: proxy.size.width)
                VStack(spacing: 0) {
                    columns(layout)
                    content(layout).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .background(Tokens.Color.surfaceCanvas)
    }

    /// `History of internal/http/middleware.go`: only the directory shortens, from its start (#614, screens.md S-02).
    private func title(_ parts: FileHistoryText.TitleParts) -> some View {
        HStack(spacing: 0) {
            Text(parts.prefix).fixedSize()
            if !parts.directory.isEmpty {
                Text(parts.directory).truncationMode(.head).layoutPriority(0)
            }
            Text(parts.name).truncationMode(.middle).layoutPriority(1)
            Text(parts.suffix).fixedSize()
        }
        .font(Tokens.Font.headline)
        .foregroundStyle(Tokens.Color.textPrimary)
        .lineLimit(1)
    }

    private var header: some View {
        PanelHeader {
            Button(action: onBack) { Label("Graph", systemImage: "chevron.left") }
                .hoverButtonStyle()
                // `⎋` is handled once, by the window (`AppState.escape`, #633).
                .help("Back to the graph (⎋)")
            if let target = store.target {
                title(FileHistoryText.titleParts(target.path))
                    .help(FileHistoryText.title(target.path))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(FileHistoryText.title(target.path))
                    .accessibilityAddTraits(.isHeader)
            }
            Spacer(minLength: Tokens.Spacing.sm)
            Toggle(
                "Follow renames",
                isOn: Binding(get: { store.target?.follow ?? true }, set: { store.setFollow($0) })
            )
            .toggleStyle(.checkbox)
            .help("Include the file's history under earlier names (git log --follow)")
        }
    }

    /// `Commit | Message | Author | Date | This file` (mockup #176), less what a narrow centre hides (#579).
    private func columns(_ layout: FileHistoryColumns) -> some View {
        HStack(spacing: 0) {
            column("Commit").frame(width: FileHistoryColumns.commitWidth, alignment: .leading)
            column("Message").frame(maxWidth: .infinity, alignment: .leading)
            if layout.shows(.author) {
                column("Author").frame(width: FileHistoryColumns.Column.author.width, alignment: .leading)
            }
            if layout.shows(.date) {
                column("Date").frame(width: FileHistoryColumns.Column.date.width, alignment: .leading)
            }
            if layout.shows(.stat) {
                column("This file").frame(width: FileHistoryColumns.Column.stat.width, alignment: .leading)
            }
        }
        .frame(height: Tokens.Size.columnHeader)
        .background(Tokens.Color.surfacePanelHeader)
        .overlay(alignment: .bottom) { Tokens.Color.borderSeparator.frame(height: 1) }
    }

    @ViewBuilder
    private func content(_ layout: FileHistoryColumns) -> some View {
        switch store.status {
        case .loading:
            ProgressView("Loading history…").controlSize(.small)
        case .failed(let reason):
            PanelEmptyState(
                symbol: "exclamationmark.triangle", title: String(localized: "History unavailable"), message: reason)
        case .loaded where store.entries.isEmpty:
            PanelEmptyState(symbol: "clock", title: FileHistoryText.empty, message: "")
        case .loaded:
            list(layout)
        }
    }

    private func list(_ layout: FileHistoryColumns) -> some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(store.entries.enumerated()), id: \.element.id) { index, entry in
                        FileHistoryRowView(
                            row: FileHistoryRow(entry, now: now), layout: layout,
                            isSelected: entry.id == store.selected,
                            isFirst: index == 0, isLast: index == store.entries.count - 1
                        )
                        .id(entry.id)
                        .onAppear { store.rowAppeared(index) }
                        // The double click first, so a single click does not swallow it.
                        .onTapGesture(count: 2) { onOpen(entry) }
                        .onTapGesture { onSelect(entry) }
                        .accessibilityAction { onSelect(entry) }
                        .accessibilityAction(named: "Show Diff") { onOpen(entry) }
                    }
                    if store.isLoadingMore {
                        ProgressView().controlSize(.small).frame(height: GraphGeometry.standard.rowHeight)
                    } else if let error = store.loadMoreError {
                        HStack(spacing: Tokens.Spacing.sm) {
                            Text("Could not load more: \(error)")
                                .font(Tokens.Font.caption)
                                .foregroundStyle(Tokens.Color.textSecondary)
                                .lineLimit(2)
                            Button("Retry", action: store.retryLoadMore).controlSize(.small)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, Tokens.Spacing.md)
                        .padding(.vertical, Tokens.Spacing.sm)
                    } else if let beginning = FileHistoryText.beginning(
                        store.entries, isComplete: store.isComplete, isCutAtLimit: store.isCutAtLimit)
                    {
                        Text(beginning)
                            .font(Tokens.Font.caption)
                            .foregroundStyle(Tokens.Color.textTertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, Tokens.Spacing.md)
                            .padding(.vertical, Tokens.Spacing.sm)
                    }
                }
            }
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            // ⌘2 focuses the center, which is S-09 while it covers the graph (interaction.md §3.1).
            .focusOnRequest([.center], $isFocused)
            .onKeyPress(.return) { open() }
            .onKeyPress(.downArrow) { move(by: 1, proxy: proxy) }
            .onKeyPress(.upArrow) { move(by: -1, proxy: proxy) }
            .onAppear { isFocused = true }
        }
    }

    private func open() -> KeyPress.Result {
        guard let entry = store.entries.first(where: { $0.id == store.selected }) else { return .ignored }
        onOpen(entry)
        return .handled
    }

    private func move(by step: Int, proxy: ScrollViewProxy) -> KeyPress.Result {
        let entries = store.entries
        guard !entries.isEmpty else { return .ignored }
        let current = entries.firstIndex { $0.id == store.selected }
        let next = current.map { min(max($0 + step, 0), entries.count - 1) } ?? 0
        onSelect(entries[next])
        proxy.scrollTo(entries[next].id)
        return .handled
    }

    private func column(_ text: LocalizedStringKey) -> some View {
        // screens.md: column headers are `text.tertiary`, as in the graph.
        Text(text).font(Tokens.Font.columnHeader).foregroundStyle(Tokens.Color.textTertiary).lineLimit(1)
            .padding(.horizontal, Tokens.Spacing.sm)
    }
}

/// One commit of the history: avatar node on one line (the file has one lane), SHA, subject with `renamed from …`,
/// author, date, and this file's change.
private struct FileHistoryRowView: View {
    let row: FileHistoryRow
    let layout: FileHistoryColumns
    let isSelected: Bool
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: Tokens.Spacing.sm) {
                node
                Text(row.text.shortSHA).font(Tokens.Font.monoSmall).foregroundStyle(Tokens.Color.textSecondary)
            }
            .padding(.horizontal, Tokens.Spacing.sm)
            .frame(width: FileHistoryColumns.commitWidth, alignment: .leading)
            HStack(spacing: Tokens.Spacing.xs) {
                // The subject keeps its room before the pill does (#579).
                Text(row.text.subject).font(Tokens.Font.body).foregroundStyle(Tokens.Color.textPrimary).lineLimit(1)
                    .layoutPriority(1)
                if let renamedFrom = row.renamedFrom {
                    Text("renamed from \(renamedFrom)")
                        .font(Tokens.Font.pill)
                        .foregroundStyle(Tokens.Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .padding(.horizontal, Tokens.Spacing.xs + Tokens.Spacing.xxs)
                        .controlOutline(Capsule())
                        .help("renamed from \(renamedFrom)")
                }
                if row.text.isAIAssisted { AIBadge() }
            }
            .padding(.horizontal, Tokens.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            if layout.shows(.author) {
                cell(row.text.author, width: FileHistoryColumns.Column.author.width, color: Tokens.Color.textSecondary)
            }
            if layout.shows(.date) {
                cell(row.text.date, width: FileHistoryColumns.Column.date.width, color: tertiary)
                    .help(row.text.absoluteDate)
            }
            if layout.shows(.stat) {
                cell(row.stat, width: FileHistoryColumns.Column.stat.width, color: Tokens.Color.textSecondary)
            }
        }
        .frame(height: GraphGeometry.standard.rowHeight)
        .background(isSelected ? Tokens.Color.surfaceSelection : Color.clear)
        .hoverHighlight(isEnabled: !isSelected)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The graph's avatar node (screens.md S-09): the avatar inside a ring of the lane colour, on a vertical line that
    /// joins the rows (the line stops at the newest and the oldest commit). The file has one lane, the first.
    private var node: some View {
        let geometry = GraphGeometry.standard
        return ZStack {
            VStack(spacing: 0) {
                Rectangle().fill(isFirst ? Color.clear : Tokens.Color.borderStrong).frame(width: 2)
                Rectangle().fill(isLast ? Color.clear : Tokens.Color.borderStrong).frame(width: 2)
            }
            Circle().fill(Tokens.Color.graphNodeRing).frame(width: geometry.node + 4, height: geometry.node + 4)
            Circle().fill(Tokens.Color.graphLanes[0]).frame(width: geometry.node, height: geometry.node)
            Text(row.text.initials)
                .font(Tokens.Font.pill)
                .foregroundStyle(Tokens.Color.avatarInitials)
                .frame(width: geometry.node - geometry.nodeRing * 2, height: geometry.node - geometry.nodeRing * 2)
                .background(Circle().fill(Tokens.Color.avatars[row.text.avatarIndex % Tokens.Color.avatars.count]))
        }
        .frame(width: geometry.node + 4, height: geometry.rowHeight)
        .accessibilityHidden(true)
    }

    private var tertiary: Color { isSelected ? Tokens.Color.textSecondary : Tokens.Color.textTertiary }

    private func cell(_ value: String, width: CGFloat, color: Color) -> some View {
        Text(value).font(Tokens.Font.callout).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, Tokens.Spacing.sm)
            .frame(width: width, alignment: .leading)
    }

}
