import SwiftUI

/// What the diff area shows while a file's patch loads (#232).
enum DiffLoadState: Equatable {
    case loading
    case loaded(DiffDocument)
    /// The patch could not be read or shown; the text says why.
    case unavailable(String)

    var phase: LoadPhase {
        switch self {
        case .loading: .loading
        case .loaded: .loaded
        case .unavailable: .failed
        }
    }
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
    var backTitle = String(localized: "Graph", comment: "Back button to the graph")
    /// `Show History` of the shown file (S-09, #70), in the title's menu.
    var onShowHistory: (() -> Void)?

    /// screens.md S-10: the choice is remembered.
    @AppStorage("diffViewMode") private var isSplit = false
    /// `⋯` › Show Whitespace (#387): TABs, trailing whitespace, and CR drawn as marks.
    @AppStorage("diffShowsWhitespace") private var showsWhitespace = false
    @State private var showsLargeDiff = false

    /// The large-diff choice belongs to one document (a staged and an unstaged diff of one path are two).
    private var documentID: UUID? {
        if case .loaded(let document) = state { return document.id }
        return nil
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            content.frame(maxWidth: .infinity, maxHeight: .infinity).fadeIn(on: state.phase)
        }
        .onChange(of: documentID) { _, _ in showsLargeDiff = false }
    }

    private var header: some View {
        PanelHeader {
            if showsBackButton {
                Button(action: onBack) {
                    Label(backTitle, systemImage: "chevron.left")
                }
                .buttonStyle(.hover)
                // `⎋` is handled once, by the window (`AppState.escape`, #633).
                .help(String(localized: "Back to the \(backTitle.lowercased()) (⎋)"))
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
            Menu {
                Toggle("Show Whitespace", isOn: $showsWhitespace)
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Diff options")
            .accessibilityLabel("Diff options")
        }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView().controlSize(.small)
        case .unavailable(let message):
            PanelEmptyState(symbol: "doc.text", title: String(localized: "Diff not shown"), message: message)
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
                    .environment(\.diffShowsWhitespace, showsWhitespace)
            }
        }
    }
}

/// The rows, built off the main thread once per document and mode (a 10 MB diff takes most of a second), then shown
/// in a lazy stack that scrolls both ways.
private struct DiffBody: View {
    let document: DiffDocument
    let isSplit: Bool

    @State private var rows = DiffRowsState()

    private struct BuildKey: Equatable {
        let document: UUID
        let isSplit: Bool
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if document.isTruncated {
                SidebarNotice(symbol: "exclamationmark.triangle", text: String(localized: "Diff truncated at 10 MB."))
            }
            ForEach(document.facts, id: \.self) { fact in
                Text(fact)
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Color.textSecondary)
                    .padding(.horizontal, Tokens.Spacing.md)
                    .padding(.vertical, Tokens.Spacing.xxs)
            }
            // No fade here (#576): the rows of a large diff are the heaviest view in the app, so they appear at once.
            if let built = isSplit
                ? rows.split(for: document.id).map(AnyRows.split) : rows.unified(for: document.id).map(AnyRows.unified)
            {
                rowsView(built)
            } else {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task(id: BuildKey(document: document.id, isSplit: isSplit)) {
            rows.begin(document.id)
            let document = document
            // `Task.detached` does not inherit cancellation, so a slow build can finish after the user moved on;
            // `accept` drops rows for a document that is no longer shown (#307).
            if isSplit, rows.split(for: document.id) == nil {
                let built = await Task.detached(priority: .userInitiated) { document.splitRows(marked: true) }.value
                guard !Task.isCancelled else { return }
                rows.accept(split: built, for: document.id)
            } else if !isSplit, rows.unified(for: document.id) == nil {
                let built = await Task.detached(priority: .userInitiated) { document.unifiedRows(marked: true) }.value
                guard !Task.isCancelled else { return }
                rows.accept(unified: built, for: document.id)
            }
        }
    }

    private enum AnyRows {
        case unified([DiffDocument.Row])
        case split([DiffDocument.SplitRow])
    }

    /// Unified rows span at least the visible width so their backgrounds reach the edge; longer lines scroll
    /// sideways. Split sides each take half the visible width and wrap a longer line, so both sides stay in view
    /// at the default centre width (#579).
    private func rowsView(_ rows: AnyRows) -> some View {
        GeometryReader { proxy in
            switch rows {
            case .split(let rows):
                let side = max((proxy.size.width - 1) / 2, 0)
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows.indices, id: \.self) { index in
                            SplitRowView(row: rows[index], sideWidth: side)
                        }
                    }
                    .frame(width: proxy.size.width, alignment: .leading)
                }
            case .unified(let rows):
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows.indices, id: \.self) { index in
                            UnifiedRowView(row: rows[index]).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .frame(minWidth: proxy.size.width, alignment: .leading)
                }
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
        case .line(let kind, let old, let new, let text, let marks):
            HStack(spacing: 0) {
                LineNumber(number: old, kind: kind)
                LineNumber(number: new, kind: kind)
                LineText(kind: kind, text: text, marks: marks)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(kind.background)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(kind.accessibilityPrefix + text + DiffLineMarkup.changedSuffix(text, marks))
        }
    }
}

private struct SplitRowView: View {
    let row: DiffDocument.SplitRow
    /// Half the visible width less the separator.
    let sideWidth: CGFloat

    var body: some View {
        switch row {
        case .fileHeader(let title):
            UnifiedRowView(row: .fileHeader(title))
        case .hunkHeader(let title):
            UnifiedRowView(row: .hunkHeader(title))
        case .notice(let text):
            UnifiedRowView(row: .notice(text))
        case .pair(let left, let right):
            // Both sides grow to the taller one's wrapped height so their backgrounds line up.
            HStack(spacing: 0) {
                half(left)
                Tokens.Color.borderSeparator.frame(width: 1)
                half(right)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func half(_ side: DiffDocument.Side?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            LineNumber(number: side?.number, kind: side?.kind ?? .context)
            LineText(
                kind: side?.kind ?? .context, text: side?.text ?? "", marks: side?.marks ?? .none, wraps: true)
        }
        .frame(width: sideWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(side?.kind.background ?? Tokens.Color.surfacePanel.opacity(0))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            side.map { $0.kind.accessibilityPrefix + $0.text + DiffLineMarkup.changedSuffix($0.text, $0.marks) }
                ?? "empty")
    }
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
    let marks: DiffDocument.LineMarks
    /// Split wraps a line longer than its side; Unified keeps it on one line and scrolls sideways.
    var wraps = false

    @Environment(\.diffShowsWhitespace) private var showsWhitespace

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // The sign, so additions and deletions do not rely on colour alone.
            Text(kind.sign)
                .font(Tokens.Font.mono)
                .foregroundStyle(kind.gutter)
                .frame(width: Tokens.Spacing.lg)
            Text(DiffLineMarkup.attributed(text, kind: kind, marks: marks, showsWhitespace: showsWhitespace))
                .font(kind == .noNewline ? Tokens.Font.caption : Tokens.Font.mono)
                .foregroundStyle(kind == .noNewline ? Tokens.Color.textTertiary : Tokens.Color.textPrimary)
                .lineLimit(wraps ? nil : 1)
                .fixedSize(horizontal: !wraps, vertical: wraps)
                .frame(minHeight: Self.rowHeight, alignment: .leading)
                .textSelection(.enabled)
        }
        .padding(.trailing, Tokens.Spacing.md)
        .frame(minHeight: Self.rowHeight, alignment: .topLeading)
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

/// The rows built for the shown diff (#307). Rows are kept only for the document being shown: a build that finishes
/// for an earlier document is dropped instead of replacing the current one.
struct DiffRowsState {
    private var document: UUID?
    private var unified: [DiffDocument.Row]?
    private var split: [DiffDocument.SplitRow]?

    /// `id` is now shown; rows of any other document are cleared.
    mutating func begin(_ id: UUID) {
        guard document != id else { return }
        document = id
        unified = nil
        split = nil
    }

    /// Stores rows built for `id`; returns `false` (and keeps nothing) when another document is shown by now.
    @discardableResult
    mutating func accept(unified rows: [DiffDocument.Row], for id: UUID) -> Bool {
        guard document == id else { return false }
        unified = rows
        return true
    }

    @discardableResult
    mutating func accept(split rows: [DiffDocument.SplitRow], for id: UUID) -> Bool {
        guard document == id else { return false }
        split = rows
        return true
    }

    func unified(for id: UUID) -> [DiffDocument.Row]? { document == id ? unified : nil }
    func split(for id: UUID) -> [DiffDocument.SplitRow]? { document == id ? split : nil }
}

private struct DiffShowsWhitespaceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// S-10's `Show Whitespace` (#387).
    var diffShowsWhitespace: Bool {
        get { self[DiffShowsWhitespaceKey.self] }
        set { self[DiffShowsWhitespaceKey.self] = newValue }
    }
}

/// A line's text with its marks applied (#387, screens.md S-10): changed words on `added-word-bg` / `removed-word-bg`,
/// and with `Show Whitespace`, `→` for a TAB, `·` for trailing spaces, and `␍` for a CR, in `text.quaternary`. The marks
/// replace a space with one scalar each, so every offset stays valid.
enum DiffLineMarkup {
    static func attributed(
        _ text: String, kind: DiffDocument.LineKind, marks: DiffDocument.LineMarks, showsWhitespace: Bool
    ) -> AttributedString {
        guard marks != .none else { return AttributedString(text) }
        var scalars = Array(text.unicodeScalars)
        var symbols: [Range<Int>] = []
        if showsWhitespace {
            for tab in marks.tabs where tab.lowerBound < scalars.count {
                scalars[tab.lowerBound] = "→"
                symbols.append(tab.lowerBound..<(tab.lowerBound + 1))
            }
            if let trailing = marks.trailing {
                for index in trailing where index < scalars.count && scalars[index] == " " {
                    scalars[index] = "·"
                    symbols.append(index..<(index + 1))
                }
            }
            if marks.hasCarriageReturn {
                scalars.append("␍")
                symbols.append((scalars.count - 1)..<scalars.count)
            }
        }
        var attributed = AttributedString(String(String.UnicodeScalarView(scalars)))
        let wordColor = kind == .added ? Tokens.Color.diffAddedWordBg : Tokens.Color.diffRemovedWordBg
        for range in marks.changed {
            if let bounds = bounds(range, in: attributed) { attributed[bounds].backgroundColor = wordColor }
        }
        for range in symbols {
            if let bounds = bounds(range, in: attributed) {
                attributed[bounds].foregroundColor = Tokens.Color.textQuaternary
            }
        }
        return attributed
    }

    /// For VoiceOver (screens.md S-10): `, changed: a, b` with at most five words, then a count.
    static func changedSuffix(_ text: String, _ marks: DiffDocument.LineMarks) -> String {
        guard !marks.changed.isEmpty else { return "" }
        let scalars = Array(text.unicodeScalars)
        let words = marks.changed.compactMap { range -> String? in
            guard range.upperBound <= scalars.count else { return nil }
            let word = String(String.UnicodeScalarView(scalars[range])).trimmingCharacters(in: .whitespaces)
            return word.isEmpty ? nil : word
        }
        guard !words.isEmpty else { return "" }
        let shown = words.prefix(5).joined(separator: ", ")
        return ", changed: " + shown + (words.count > 5 ? " and \(words.count - 5) more" : "")
    }

    private static func bounds(_ range: Range<Int>, in text: AttributedString) -> Range<AttributedString.Index>? {
        let scalars = text.unicodeScalars
        guard range.lowerBound >= 0, range.upperBound <= scalars.count else { return nil }
        let start = scalars.index(scalars.startIndex, offsetBy: range.lowerBound)
        let end = scalars.index(start, offsetBy: range.count)
        return start..<end
    }
}
