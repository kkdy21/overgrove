import SwiftUI

/// What the diff area shows while a file's patch loads (#232).
enum DiffLoadState: Equatable {
    case loading
    case loaded(DiffDocument)
    /// The patch could not be read or shown; the text says why.
    case unavailable(String)
}

/// S-10, one file's diff in the center area (screens.md S-10). Read-only: no staging, no editing (ADR-0011).
///
/// `‹ Graph` or `⎋` goes back; the detail panel's file list stays, so `↑`/`↓` there moves to the next file.
struct DiffViewerView: View {
    let title: String
    let sourceLabel: String
    let state: DiffLoadState
    let onBack: () -> Void
    /// S-11 shows the patch under its own header, which already has `‹ Graph`.
    var showsBackButton = true
    /// The back button's label: `Graph`, or `History` when the diff was opened from S-09.
    var backTitle = "Graph"
    /// `Show History` of the shown file (S-09, #70), in the title's menu.
    var onShowHistory: (() -> Void)?

    /// screens.md S-10: the choice is remembered.
    @AppStorage("diffViewMode") private var isSplit = false
    @State private var showsLargeDiff = false

    /// The large-diff choice belongs to one document (a staged and an unstaged diff of one path are two).
    private var documentID: UUID? {
        if case .loaded(let document) = state { return document.id }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onChange(of: documentID) { _, _ in showsLargeDiff = false }
    }

    private var header: some View {
        PanelHeader {
            if showsBackButton {
                Button(action: onBack) {
                    Label(backTitle, systemImage: "chevron.left")
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.cancelAction)
                .help("Back to the \(backTitle.lowercased()) (⎋)")
            }
            Text(title)
                .font(Tokens.Font.headline)
                .foregroundStyle(Tokens.Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.head)
                .contextMenu {
                    if let onShowHistory { Button("Show History", action: onShowHistory) }
                }
            Text(sourceLabel)
                .font(Tokens.Font.callout)
                .foregroundStyle(Tokens.Color.textSecondary)
                .lineLimit(1)
            Spacer(minLength: Tokens.Spacing.sm)
            Picker("View", selection: $isSplit) {
                Text("Unified").tag(false)
                Text("Split").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView().controlSize(.small)
        case .unavailable(let message):
            PanelEmptyState(symbol: "doc.text", title: "Diff not shown", message: message)
        case .loaded(let document):
            if document.isLarge && !showsLargeDiff {
                VStack(spacing: Tokens.Spacing.sm) {
                    Text("Large diff (\(WipDetailModel.formatted(document.lineCount)) lines)")
                        .font(Tokens.Font.headline)
                        .foregroundStyle(Tokens.Color.textPrimary)
                    Button("Show Diff") { showsLargeDiff = true }
                }
            } else {
                DiffBody(document: document, isSplit: isSplit)
            }
        }
    }
}

/// The rows, built off the main thread once per document and mode (a 10 MB diff takes most of a second), then shown
/// in a lazy stack that scrolls both ways.
private struct DiffBody: View {
    let document: DiffDocument
    let isSplit: Bool

    @State private var unified: [DiffDocument.Row]?
    @State private var split: [DiffDocument.SplitRow]?
    @State private var builtFor: UUID?

    private struct BuildKey: Equatable {
        let document: UUID
        let isSplit: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if document.isTruncated {
                SidebarNotice(symbol: "exclamationmark.triangle", text: "Diff truncated at 10 MB.")
            }
            ForEach(document.facts, id: \.self) { fact in
                Text(fact)
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Color.textSecondary)
                    .padding(.horizontal, Tokens.Spacing.md)
                    .padding(.vertical, Tokens.Spacing.xxs)
            }
            if let rows = isSplit ? split.map(AnyRows.split) : unified.map(AnyRows.unified), builtFor == document.id {
                rowsView(rows)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: BuildKey(document: document.id, isSplit: isSplit)) {
            if builtFor != document.id {
                unified = nil
                split = nil
                builtFor = document.id
            }
            let document = document
            if isSplit, split == nil {
                split = await Task.detached(priority: .userInitiated) { document.splitRows() }.value
            } else if !isSplit, unified == nil {
                unified = await Task.detached(priority: .userInitiated) { document.unifiedRows() }.value
            }
        }
    }

    private enum AnyRows {
        case unified([DiffDocument.Row])
        case split([DiffDocument.SplitRow])
    }

    /// Rows span at least the visible width so their backgrounds reach the edge; longer lines scroll.
    private func rowsView(_ rows: AnyRows) -> some View {
        GeometryReader { proxy in
            ScrollView([.vertical, .horizontal]) {
                Group {
                    switch rows {
                    case .split(let rows):
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows.indices, id: \.self) { index in
                                SplitRowView(row: rows[index]).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    case .unified(let rows):
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(rows.indices, id: \.self) { index in
                                UnifiedRowView(row: rows[index]).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
                .frame(minWidth: proxy.size.width, alignment: .leading)
            }
        }
    }
}

/// Gutter width for line numbers; no token. Fits five digits in `typography.mono-small`.
private let numberWidth: CGFloat = 44

private struct UnifiedRowView: View {
    let row: DiffDocument.Row

    var body: some View {
        switch row {
        case .fileHeader(let title):
            Text(title)
                .font(Tokens.Font.columnHeader)
                .foregroundStyle(Tokens.Color.textPrimary)
                .padding(.horizontal, Tokens.Spacing.md)
                .padding(.vertical, Tokens.Spacing.xs)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .hunkHeader(let title):
            Text(title)
                .font(Tokens.Font.monoSmall)
                .foregroundStyle(Tokens.Color.textSecondary)
                .padding(.horizontal, Tokens.Spacing.md)
                .frame(maxWidth: .infinity, minHeight: Tokens.Size.rowFile, alignment: .leading)
                .background(Tokens.Color.diffHunkHeaderBg)
        case .notice(let text):
            Text(text)
                .font(Tokens.Font.callout)
                .foregroundStyle(Tokens.Color.textSecondary)
                .padding(Tokens.Spacing.md)
        case .line(let kind, let old, let new, let text):
            HStack(spacing: 0) {
                LineNumber(number: old, kind: kind)
                LineNumber(number: new, kind: kind)
                LineText(kind: kind, text: text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(kind.background)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(kind.accessibilityPrefix + text)
        }
    }
}

private struct SplitRowView: View {
    let row: DiffDocument.SplitRow

    var body: some View {
        switch row {
        case .fileHeader(let title):
            UnifiedRowView(row: .fileHeader(title))
        case .hunkHeader(let title):
            UnifiedRowView(row: .hunkHeader(title))
        case .notice(let text):
            UnifiedRowView(row: .notice(text))
        case .pair(let left, let right):
            HStack(spacing: 0) {
                half(left)
                Tokens.Color.borderSeparator.frame(width: 1)
                half(right)
            }
        }
    }

    private func half(_ side: DiffDocument.Side?) -> some View {
        HStack(spacing: 0) {
            LineNumber(number: side?.number, kind: side?.kind ?? .context)
            LineText(kind: side?.kind ?? .context, text: side?.text ?? "")
        }
        .frame(minWidth: Self.halfWidth, alignment: .leading)
        .background(side?.kind.background ?? Tokens.Color.surfacePanel.opacity(0))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(side.map { $0.kind.accessibilityPrefix + $0.text } ?? "empty")
    }

    /// Each side starts at least this wide so the two columns line up; no token.
    static let halfWidth: CGFloat = 520
}

private struct LineNumber: View {
    let number: Int?
    let kind: DiffDocument.LineKind

    var body: some View {
        Text(number.map(String.init) ?? "")
            .font(Tokens.Font.monoSmall)
            .foregroundStyle(Tokens.Color.textTertiary)
            .frame(width: numberWidth, alignment: .trailing)
            .padding(.trailing, Tokens.Spacing.xs)
    }
}

private struct LineText: View {
    let kind: DiffDocument.LineKind
    let text: String

    var body: some View {
        HStack(spacing: 0) {
            // The sign, so additions and deletions do not rely on colour alone.
            Text(kind.sign)
                .font(Tokens.Font.mono)
                .foregroundStyle(kind.gutter)
                .frame(width: Tokens.Spacing.lg)
            Text(text)
                .font(kind == .noNewline ? Tokens.Font.caption : Tokens.Font.mono)
                .foregroundStyle(kind == .noNewline ? Tokens.Color.textTertiary : Tokens.Color.textPrimary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .textSelection(.enabled)
        }
        .padding(.trailing, Tokens.Spacing.md)
        .frame(minHeight: Self.rowHeight, alignment: .leading)
    }

    /// One code line; no token for diff rows.
    static let rowHeight: CGFloat = 20
}

extension DiffDocument.LineKind {
    var sign: String {
        switch self {
        case .added: "+"
        case .removed: "−"
        case .context, .noNewline: " "
        }
    }

    var background: Color {
        switch self {
        case .added: Tokens.Color.diffAddedBg
        case .removed: Tokens.Color.diffRemovedBg
        case .context, .noNewline: Color.clear
        }
    }

    /// The `+`/`−` glyph colour (`diff.gutter-*`): the glyph, not the colour, carries the meaning.
    var gutter: Color {
        switch self {
        case .added: Tokens.Color.diffGutterAdded
        case .removed: Tokens.Color.diffGutterRemoved
        case .context, .noNewline: Tokens.Color.textTertiary
        }
    }

    var accessibilityPrefix: String {
        switch self {
        case .added: "added: "
        case .removed: "removed: "
        case .context: ""
        case .noNewline: ""
        }
    }
}
