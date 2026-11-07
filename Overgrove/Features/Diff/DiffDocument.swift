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

    /// One unified row.
    enum Row: Equatable, Sendable {
        case fileHeader(String)
        case hunkHeader(String)
        case line(kind: LineKind, old: Int?, new: Int?, text: String)
        case notice(String)
    }

    /// One side of a split row.
    struct Side: Equatable, Sendable {
        let kind: LineKind
        let number: Int?
        let text: String
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
    func unifiedRows() -> [Row] {
        if listing.files.isEmpty { return [.notice(Self.noChanges)] }
        var rows: [Row] = []
        for file in listing.files {
            if listing.files.count > 1 { rows.append(.fileHeader(Self.blockTitle(file))) }
            if let notice = Self.notice(file) {
                rows.append(.notice(notice))
                continue
            }
            for hunk in file.hunks {
                rows.append(.hunkHeader(Self.hunkTitle(hunk)))
                for line in hunk.lines {
                    let kind = Self.kind(line.kind)
                    rows.append(
                        .line(
                            kind: kind, old: line.oldNumber, new: line.newNumber, text: Self.display(line, kind: kind)))
                }
            }
        }
        return rows
    }

    /// Split rows: within a hunk, each run of removed lines is paired with the added lines that follow it.
    func splitRows() -> [SplitRow] {
        if listing.files.isEmpty { return [.notice(Self.noChanges)] }
        var rows: [SplitRow] = []
        for file in listing.files {
            if listing.files.count > 1 { rows.append(.fileHeader(Self.blockTitle(file))) }
            if let notice = Self.notice(file) {
                rows.append(.notice(notice))
                continue
            }
            for hunk in file.hunks {
                rows.append(.hunkHeader(Self.hunkTitle(hunk)))
                rows += Self.pairs(hunk.lines)
            }
        }
        return rows
    }

    private static func pairs(_ lines: [PatchLine]) -> [SplitRow] {
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
        for line in lines {
            let kind = kind(line.kind)
            let side = Side(kind: kind, number: line.oldNumber ?? line.newNumber, text: display(line, kind: kind))
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
                        left: Side(kind: .context, number: line.oldNumber, text: side.text),
                        right: Side(kind: .context, number: line.newNumber, text: side.text)))
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
        if kind == .noNewline { return "No newline at end of file" }
        var content = line.content
        if content.last == 0x0D { content = content.dropLast() }
        let decoded = String(decoding: content, as: UTF8.self)
        var expanded = ""
        expanded.reserveCapacity(decoded.utf8.count)
        var column = 0
        for character in decoded {
            if character == "\t" {
                let spaces = tabWidth - column % tabWidth
                expanded += String(repeating: " ", count: spaces)
                column += spaces
            } else {
                expanded.append(character)
                column += 1
            }
        }
        let safe = PathValidator.displayable(expanded)
        let scalars = safe.unicodeScalars
        guard scalars.count > maximumLineScalars else { return safe }
        var cut = String.UnicodeScalarView()
        cut.append(contentsOf: scalars.prefix(maximumLineScalars))
        return String(cut) + " … (\(WipDetailModel.formatted(scalars.count - maximumLineScalars)) more characters)"
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
            if file.renameFrom != nil || file.copyFrom != nil { return "Content unchanged." }
            if file.oldMode != file.newMode, file.oldMode != nil, file.newMode != nil {
                return "Only the file mode changed."
            }
            return isEmptyFile(file) ? "Empty file." : "No content changes."
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
