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
            columns
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Tokens.Color.surfaceCanvas)
    }

    private var header: some View {
        PanelHeader {
            Button(action: onBack) { Label("Graph", systemImage: "chevron.left") }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Back to the graph (⎋)")
            Text(store.target.map { FileHistoryText.title($0.path) } ?? "")
                .font(Tokens.Font.headline)
                .foregroundStyle(Tokens.Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: Tokens.Spacing.sm)
            Toggle(
                "Follow renames",
                isOn: Binding(get: { store.target?.follow ?? true }, set: { store.setFollow($0) })
            )
            .toggleStyle(.checkbox)
            .help("Include the file's history under earlier names (git log --follow)")
        }
    }

    /// `Commit | Message | Author | Date | This file` (mockup #176).
    private var columns: some View {
        HStack(spacing: 0) {
            column("Commit").frame(width: Self.commitWidth, alignment: .leading)
            column("Message").frame(maxWidth: .infinity, alignment: .leading)
            column("Author").frame(width: Tokens.Size.columnAuthorIdeal, alignment: .leading)
            column("Date").frame(width: Tokens.Size.columnDateIdeal, alignment: .leading)
            column("This file").frame(width: Self.statWidth, alignment: .leading)
        }
        .frame(height: Tokens.Size.columnHeader)
        .background(Tokens.Color.surfacePanelHeader)
    }

    @ViewBuilder
    private var content: some View {
        switch store.status {
        case .loading:
            ProgressView("Loading history…").controlSize(.small)
        case .failed(let reason):
            PanelEmptyState(symbol: "exclamationmark.triangle", title: "History unavailable", message: reason)
        case .loaded where store.entries.isEmpty:
            PanelEmptyState(symbol: "clock", title: FileHistoryText.empty, message: "")
        case .loaded:
            list
        }
    }

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(Array(store.entries.enumerated()), id: \.element.id) { index, entry in
                        FileHistoryRowView(
                            row: FileHistoryRow(entry, now: now), isSelected: entry.id == store.selected,
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
                        ProgressView().controlSize(.small).frame(height: GraphGeometry.rowHeight)
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

    private func column(_ text: String) -> some View {
        Text(text).font(Tokens.Font.columnHeader).foregroundStyle(Tokens.Color.textSecondary)
            .padding(.horizontal, Tokens.Spacing.sm)
    }

    static let commitWidth: CGFloat = 120
    static let statWidth: CGFloat = 96
}

/// One commit of the history: avatar node on one line (the file has one lane), SHA, subject with `renamed from …`,
/// author, date, and this file's change.
private struct FileHistoryRowView: View {
    let row: FileHistoryRow
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
            .frame(width: FileHistoryView.commitWidth, alignment: .leading)
            HStack(spacing: Tokens.Spacing.xs) {
                Text(row.text.subject).font(Tokens.Font.body).foregroundStyle(Tokens.Color.textPrimary).lineLimit(1)
                if let renamedFrom = row.renamedFrom {
                    Text("renamed from \(renamedFrom)")
                        .font(Tokens.Font.pill)
                        .foregroundStyle(Tokens.Color.textSecondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .padding(.horizontal, Tokens.Spacing.xs + Tokens.Spacing.xxs)
                        .overlay(Capsule().strokeBorder(Tokens.Color.borderSeparator))
                        .help("renamed from \(renamedFrom)")
                }
                if row.text.isAIAssisted { AIBadge() }
            }
            .padding(.horizontal, Tokens.Spacing.sm)
            .frame(maxWidth: .infinity, alignment: .leading)
            cell(row.text.author, width: Tokens.Size.columnAuthorIdeal, color: Tokens.Color.textSecondary)
            cell(row.text.date, width: Tokens.Size.columnDateIdeal, color: tertiary).help(row.text.absoluteDate)
            cell(row.stat, width: FileHistoryView.statWidth, color: Tokens.Color.textSecondary)
        }
        .frame(height: GraphGeometry.rowHeight)
        .background(isSelected ? Tokens.Color.surfaceSelection : Color.clear)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(row.accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    /// The avatar on a vertical line that joins the rows (the line stops at the newest and the oldest commit).
    private var node: some View {
        ZStack {
            VStack(spacing: 0) {
                Rectangle().fill(isFirst ? Color.clear : Tokens.Color.borderStrong).frame(width: 2)
                Rectangle().fill(isLast ? Color.clear : Tokens.Color.borderStrong).frame(width: 2)
            }
            Text(row.text.initials)
                .font(Tokens.Font.pill)
                .foregroundStyle(Tokens.Color.avatarInitials)
                .frame(width: Self.avatar, height: Self.avatar)
                .background(Circle().fill(Tokens.Color.avatars[row.text.avatarIndex % Tokens.Color.avatars.count]))
        }
        .frame(width: Self.avatar, height: GraphGeometry.rowHeight)
        .accessibilityHidden(true)
    }

    private var tertiary: Color { isSelected ? Tokens.Color.textSecondary : Tokens.Color.textTertiary }

    private func cell(_ value: String, width: CGFloat, color: Color) -> some View {
        Text(value).font(Tokens.Font.callout).foregroundStyle(color).lineLimit(1)
            .padding(.horizontal, Tokens.Spacing.sm)
            .frame(width: width, alignment: .leading)
    }

    static let avatar: CGFloat = 18
}
