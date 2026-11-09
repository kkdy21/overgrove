import Foundation

/// What the diff viewer (S-10) shows for one file: built from a parsed patch, with every line made safe to display.
/// Pure, so it is unit tested without views. Rows are built only when asked for, so a large diff costs nothing until
/// the user chooses to show it.
struct DiffDocument: Equatable, Sendable {
    /// Where the patch came from, for the header (`Staged · M`).
    struct Source: Equatable, Sendable {
        let label: String
        let kindLetter: String
    }

    enum LineKind: Equatable, Sendable {
        case context
        case added
        case removed
        case noNewline
    }

    /// What the viewer draws over a line's text (#387), in Unicode scalar offsets into that text.
    struct LineMarks: Equatable, Sendable {
        /// Words changed against the paired line (`added-word-bg` / `removed-word-bg`).
        var changed: [Range<Int>] = []
        /// The spaces each TAB was expanded to (`Show Whitespace` draws `→`).
        var tabs: [Range<Int>] = []
        /// Whitespace at the end of an added or removed line (`·`).
        var trailing: Range<Int>?
        /// The line ended with CR, which the text drops (`␍`).
        var hasCarriageReturn = false

        static let none = LineMarks()
    }

    /// One unified row.
    enum Row: Equatable, Sendable {
        case fileHeader(String)
        case hunkHeader(String)
        case line(kind: LineKind, old: Int?, new: Int?, text: String, marks: LineMarks = .none)
        case notice(String)
    }

    /// One side of a split row.
    struct Side: Equatable, Sendable {
        let kind: LineKind
        let number: Int?
        let text: String
        var marks: LineMarks = .none
    }

    /// One split row: the old side on the left, the new side on the right; either may be empty.
    enum SplitRow: Equatable, Sendable {
        case fileHeader(String)
        case hunkHeader(String)
        case pair(left: Side?, right: Side?)
        case notice(String)
    }

    /// Identity for views: comparing it is O(1), unlike comparing a 10 MB patch.
    let id = UUID()
    /// Escaped path of the file.
    let title: String
    let source: Source
    /// Header facts: `Renamed from old.txt (90%)`, `Mode 100644 → 100755`, `New file`. Escaped.
    let facts: [String]
    /// Output was cut at the size limit (ADR-0008): show `Diff truncated at 10 MB`.
    let isTruncated: Bool
    /// More lines than `largeLineThreshold`: rows are built only after `Show Diff`.
    let lineCount: Int
    private let listing: PatchParser.Listing

    /// screens.md S-10: diffs over this many lines ask before rendering.
    static let largeLineThreshold = 10_000
    /// Unicode scalars shown per line; the rest is summarized so one huge line cannot stall layout. Counted in scalars,
    /// not characters: one character can carry thousands of combining marks (security review of #232).
    static let maximumLineScalars = 2_000
    /// Spaces a TAB expands to.
    static let tabWidth = 4

    var isLarge: Bool { lineCount > Self.largeLineThreshold }

    init(listing: PatchParser.Listing, path: GitPath, source: Source) {
        self.listing = listing
        title = PathValidator.displayable(path.display)
        self.source = source
        isTruncated = listing.isPartial
        lineCount = listing.lineCount
        facts = listing.files.flatMap(Self.facts)
    }

    /// The same load: views and states compare documents often, so this must stay cheap.
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }

    // MARK: Rows

    /// Unified rows: file headers only when a patch has more than one block (a type change).
    /// - Parameter marked: Adds word changes and whitespace marks (#387); the viewer asks for them.
    func unifiedRows(marked: Bool = false) -> [Row] {
        if listing.files.isEmpty { return [.notice(Self.noChanges)] }
        var rows: [Row] = []
        for file in listing.files {
            if listing.files.count > 1 { rows.append(.fileHeader(Self.blockTitle(file))) }
            if let notice = Self.notice(file) {
                rows.append(.notice(notice))
                continue
            }
            var budget = WordBudget()
            for hunk in file.hunks {
                rows.append(.hunkHeader(Self.hunkTitle(hunk)))
                let shown = marked ? Self.marks(hunk.lines, budget: &budget) : nil
                for (index, line) in hunk.lines.enumerated() {
                    let kind = Self.kind(line.kind)
                    rows.append(
                        .line(
                            kind: kind, old: line.oldNumber, new: line.newNumber,
                            text: shown?[index].text ?? Self.display(line, kind: kind),
                            marks: shown?[index].marks ?? .none))
                }
            }
        }
        return rows
    }

    /// Split rows: within a hunk, each run of removed lines is paired with the added lines that follow it.
    func splitRows(marked: Bool = false) -> [SplitRow] {
        if listing.files.isEmpty { return [.notice(Self.noChanges)] }
        var rows: [SplitRow] = []
        for file in listing.files {
            if listing.files.count > 1 { rows.append(.fileHeader(Self.blockTitle(file))) }
            if let notice = Self.notice(file) {
                rows.append(.notice(notice))
                continue
            }
            var budget = WordBudget()
            for hunk in file.hunks {
                rows.append(.hunkHeader(Self.hunkTitle(hunk)))
                rows += Self.pairs(hunk.lines, marks: marked ? Self.marks(hunk.lines, budget: &budget) : nil)
            }
        }
        return rows
    }

    // MARK: Marks (#387)

    /// What is left of one file's word-diff allowance (`WordDiff` limits, T15).
    private struct WordBudget {
        var cells = WordDiff.maximumCellsPerFile
        var pairedLines = 0
    }

    /// Marks for each line of a hunk: whitespace from the shown text, and word changes for each removed line paired
    /// with the added line in the same place of the run that follows it.
    private static func marks(_ lines: [PatchLine], budget: inout WordBudget) -> [(text: String, marks: LineMarks)] {
        let shown = lines.map { shownLine($0, kind: kind($0.kind)) }
        var marks = shown.map { $0.marks }
        var index = 0
        while index < lines.count {
            guard lines[index].kind == .removed else {
                index += 1
                continue
            }
            var removed: [Int] = []
            var end = index
            while end < lines.count, lines[end].kind == .removed || lines[end].kind == .noNewline {
                if lines[end].kind == .removed { removed.append(end) }
                end += 1
            }
            var added: [Int] = []
            while end < lines.count, lines[end].kind == .added || lines[end].kind == .noNewline {
                if lines[end].kind == .added { added.append(end) }
                end += 1
            }
            if removed.count <= WordDiff.maximumRunLines, added.count <= WordDiff.maximumRunLines {
                for (old, new) in zip(removed, added) where budget.pairedLines < WordDiff.maximumPairedLinesPerFile {
                    budget.pairedLines += 1
                    if let changes = WordDiff.changes(old: shown[old].text, new: shown[new].text, budget: &budget.cells)
                    {
                        marks[old].changed = changes.old
                        marks[new].changed = changes.new
                    }
                }
            }
            index = end
        }
        return zip(shown, marks).map { ($0.text, $1) }
    }

    private static func pairs(_ lines: [PatchLine], marks: [(text: String, marks: LineMarks)]? = nil) -> [SplitRow] {
        var rows: [SplitRow] = []
        var removed: [Side] = []
        var added: [Side] = []
        func flush() {
            for index in 0..<max(removed.count, added.count) {
                rows.append(
                    .pair(
                        left: index < removed.count ? removed[index] : nil,
                        right: index < added.count ? added[index] : nil))
            }
            removed = []
            added = []
        }
        var previous: PatchLine.Kind?
        for (index, line) in lines.enumerated() {
            let kind = kind(line.kind)
            let side = Side(
                kind: kind, number: line.oldNumber ?? line.newNumber,
                text: marks?[index].text ?? display(line, kind: kind),
                marks: marks?[index].marks ?? .none)
            switch line.kind {
            case .removed:
                if !added.isEmpty { flush() }
                removed.append(side)
            case .added:
                added.append(side)
            case .context:
                flush()
                rows.append(
                    .pair(
                        left: Side(kind: .context, number: line.oldNumber, text: side.text, marks: side.marks),
                        right: Side(kind: .context, number: line.newNumber, text: side.text, marks: side.marks)))
            case .noNewline:
                // Belongs to the line before it: the same side, or both for context.
                switch previous {
                case .removed: removed.append(side)
                case .added: added.append(side)
                default:
                    flush()
                    rows.append(.pair(left: side, right: side))
                }
            }
            previous = line.kind == .noNewline ? previous : line.kind
        }
        flush()
        return rows
    }

    // MARK: Text

    static let noChanges = "No changes. The file matches the other side."

    /// One line, safe to show: lossy UTF-8, a trailing CR (CRLF files) dropped, TABs expanded, control, format
    /// (bidi), and separator characters escaped, and very long lines cut.
    static func display(_ line: PatchLine, kind: LineKind) -> String {
        shownLine(line, kind: kind).text
    }

    /// `display` with where its whitespace went (#387). Each character is escaped on its own, so TAB columns and the
    /// marks' offsets follow the text as shown.
    /// The common case, printable ASCII and TABs only, built as bytes: no escaping can be needed (PERF-09). `nil` for
    /// any other byte, which takes the general path.
    private static func asciiLine(_ content: some Collection<UInt8>, kind: LineKind, marks: inout LineMarks)
        -> (text: String, marks: LineMarks)?
    {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(content.count + 8)
        var tabs: [Range<Int>] = []
        for byte in content {
            if byte == 0x09 {
                let spaces = tabWidth - bytes.count % tabWidth
                tabs.append(bytes.count..<(bytes.count + spaces))
                bytes.append(contentsOf: repeatElement(0x20, count: spaces))
            } else if (0x20..<0x7F).contains(byte) {
                bytes.append(byte)
            } else {
                return nil
            }
            if bytes.count > maximumLineScalars { return nil }
        }
        marks.tabs = tabs
        if kind == .added || kind == .removed {
            let start = bytes.count - bytes.reversed().prefix { $0 == 0x20 }.count
            if start < bytes.count { marks.trailing = start..<bytes.count }
        }
        return (String(decoding: bytes, as: UTF8.self), marks)
    }

    private static func shownLine(_ line: PatchLine, kind: LineKind) -> (text: String, marks: LineMarks) {
        if kind == .noNewline { return (String(localized: "No newline at end of file"), .none) }
        var marks = LineMarks.none
        var content = line.content
        if content.last == 0x0D {
            content = content.dropLast()
            marks.hasCarriageReturn = true
        }
        if let ascii = asciiLine(content, kind: kind, marks: &marks) { return ascii }
        let decoded = String(decoding: content, as: UTF8.self)
        var shown = String.UnicodeScalarView()
        var column = 0
        for character in decoded {
            if character == "\t" {
                let spaces = tabWidth - column % tabWidth
                marks.tabs.append(shown.count..<(shown.count + spaces))
                shown.append(contentsOf: String(repeating: " ", count: spaces).unicodeScalars)
                column += spaces
            } else if let ascii = character.asciiValue, (0x20..<0x7F).contains(ascii) {
                // Printable ASCII needs no escaping; most code is only this.
                shown.append(Unicode.Scalar(ascii))
                column += 1
            } else {
                let safe = PathValidator.displayable(String(character))
                shown.append(contentsOf: safe.unicodeScalars)
                column += safe.count
            }
        }
        if kind == .added || kind == .removed {
            let end = shown.count
            let start = end - shown.reversed().prefix { $0 == " " }.count
            if start < end { marks.trailing = start..<end }
        }
        guard shown.count > maximumLineScalars else { return (String(shown), marks) }
        marks.tabs = marks.tabs.filter { $0.upperBound <= maximumLineScalars }
        marks.trailing = nil
        let more = shown.count - maximumLineScalars
        var cut = String.UnicodeScalarView()
        cut.append(contentsOf: shown.prefix(maximumLineScalars))
        return (String(cut) + " … (\(WipDetailModel.formatted(more)) more characters)", marks)
    }

    private static func kind(_ kind: PatchLine.Kind) -> LineKind {
        switch kind {
        case .context: .context
        case .added: .added
        case .removed: .removed
        case .noNewline: .noNewline
        }
    }

    private static func hunkTitle(_ hunk: PatchHunk) -> String {
        var title = "@@ -\(hunk.oldStart),\(hunk.oldCount) +\(hunk.newStart),\(hunk.newCount) @@"
        let section = PathValidator.displayable(String(decoding: hunk.section, as: UTF8.self))
        if !section.isEmpty { title += " " + String(section.prefix(200)) }
        return title
    }

    private static func blockTitle(_ file: FilePatch) -> String {
        if file.isDeletedFile { return "Deleted \(file.isSymlink ? "symbolic link" : "file")" }
        if file.isNewFile { return "Added \(file.isSymlink ? "symbolic link" : "file")" }
        return "Changed"
    }

    /// A block shown as one line instead of hunks.
    private static func notice(_ file: FilePatch) -> String? {
        if file.isCombined || file.isUnmerged {
            return "Conflicted file. The combined diff is not shown yet; resolve it in Terminal."
        }
        if file.isBinary { return "Binary file. Its contents are not shown." }
        if let submodule = file.submodule {
            let old = submodule.old?.short ?? "none"
            let new = submodule.new?.short ?? "none"
            return "Submodule commit \(old) → \(new)"
        }
        if file.hunks.isEmpty {
            if file.renameFrom != nil || file.copyFrom != nil { return String(localized: "Content unchanged.") }
            if file.oldMode != file.newMode, file.oldMode != nil, file.newMode != nil {
                return String(localized: "Only the file mode changed.")
            }
            return isEmptyFile(file) ? String(localized: "Empty file.") : String(localized: "No content changes.")
        }
        return nil
    }

    private static func isEmptyFile(_ file: FilePatch) -> Bool { file.isNewFile || file.isDeletedFile }

    private static func facts(_ file: FilePatch) -> [String] {
        var facts: [String] = []
        if let from = file.renameFrom {
            facts.append(
                "Renamed from \(PathValidator.displayable(from.display))" + (file.similarity.map { " (\($0)%)" } ?? ""))
        }
        if let from = file.copyFrom {
            facts.append(
                "Copied from \(PathValidator.displayable(from.display))" + (file.similarity.map { " (\($0)%)" } ?? ""))
        }
        if let old = file.oldMode, let new = file.newMode, old != new, !file.isNewFile, !file.isDeletedFile {
            facts.append("Mode \(old) → \(new)")
        }
        if file.isSymlink { facts.append("Symbolic link: the link target text is shown") }
        return facts
    }
}
