import Foundation
import XCTest

@testable import Overgrove

/// `DiffDocument` (#232): screens.md S-10 rows from a parsed patch, without views.
final class DiffDocumentTests: XCTestCase {
    private let source = DiffDocument.Source(label: "Unstaged", kindLetter: "M")

    private func document(_ patch: String, truncated: Bool = false, path: String = "src/a.swift") throws
        -> DiffDocument
    {
        DiffDocument(
            listing: try PatchParser.parse(Data(patch.utf8), truncated: truncated), path: GitPath(path), source: source)
    }

    private let modified = """
        diff --git a/src/a.swift b/src/a.swift
        --- a/src/a.swift
        +++ b/src/a.swift
        @@ -40,4 +40,5 @@ struct StatusParser
             func parse() {
        -        let lines = split()
        +        let records = split()
        +        // records are NUL-terminated
             }
        -old tail
        +new tail

        """

    func testUnifiedRows() throws {
        let rows = try document(modified).unifiedRows()
        XCTAssertEqual(
            rows,
            [
                .hunkHeader("@@ -40,4 +40,5 @@ struct StatusParser"),
                .line(kind: .context, old: 40, new: 40, text: "    func parse() {"),
                .line(kind: .removed, old: 41, new: nil, text: "        let lines = split()"),
                .line(kind: .added, old: nil, new: 41, text: "        let records = split()"),
                .line(kind: .added, old: nil, new: 42, text: "        // records are NUL-terminated"),
                .line(kind: .context, old: 42, new: 43, text: "    }"),
                .line(kind: .removed, old: 43, new: nil, text: "old tail"),
                .line(kind: .added, old: nil, new: 44, text: "new tail"),
            ])
    }

    /// Each run of removed lines pairs with the added lines after it; extra lines leave the other side empty.
    func testSplitRows() throws {
        let rows = try document(modified).splitRows()
        func side(_ kind: DiffDocument.LineKind, _ number: Int, _ text: String) -> DiffDocument.Side {
            DiffDocument.Side(kind: kind, number: number, text: text)
        }
        XCTAssertEqual(
            rows,
            [
                .hunkHeader("@@ -40,4 +40,5 @@ struct StatusParser"),
                .pair(left: side(.context, 40, "    func parse() {"), right: side(.context, 40, "    func parse() {")),
                .pair(
                    left: side(.removed, 41, "        let lines = split()"),
                    right: side(.added, 41, "        let records = split()")),
                .pair(left: nil, right: side(.added, 42, "        // records are NUL-terminated")),
                .pair(left: side(.context, 42, "    }"), right: side(.context, 43, "    }")),
                .pair(left: side(.removed, 43, "old tail"), right: side(.added, 44, "new tail")),
            ])
    }

    func testNoNewlineMarkerStaysWithItsSide() throws {
        let doc = try document(
            "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n")
        let marker = DiffDocument.Side(kind: .noNewline, number: nil, text: "No newline at end of file")
        XCTAssertEqual(
            doc.splitRows().dropFirst(),
            [
                .pair(
                    left: DiffDocument.Side(kind: .removed, number: 1, text: "old"),
                    right: DiffDocument.Side(kind: .added, number: 1, text: "new")),
                .pair(left: marker, right: nil),
            ])
        XCTAssertEqual(
            doc.unifiedRows()[2], .line(kind: .noNewline, old: nil, new: nil, text: "No newline at end of file"))
    }

    /// Content is shown safely: TABs expand, CRLF loses its CR, controls and bidi characters are escaped, invalid
    /// UTF-8 becomes U+FFFD, very long lines are cut.
    func testLinesAreSafeToShow() {
        func show(_ bytes: Data) -> String {
            DiffDocument.display(PatchLine(kind: .added, oldNumber: nil, newNumber: 1, content: bytes), kind: .added)
        }
        XCTAssertEqual(show(Data("a\tb\t\tc".utf8)), "a   b       c")
        XCTAssertEqual(show(Data("crlf\r".utf8)), "crlf")
        XCTAssertEqual(show(Data("x\u{202E}y\u{1B}[31mz\u{2028}".utf8)), "x\\u{202E}y\\u{1B}[31mz\\u{2028}")
        XCTAssertEqual(show(Data([0x61, 0xFF, 0x62])), "a\u{FFFD}b")
        let long = show(Data(String(repeating: "x", count: 5_000).utf8))
        XCTAssertTrue(long.hasPrefix(String(repeating: "x", count: DiffDocument.maximumLineScalars)))
        XCTAssertTrue(long.hasSuffix(" … (3,000 more characters)"), long)
        // One character with thousands of combining marks is cut by scalars too.
        let combining = show(Data(("a" + String(repeating: "\u{301}", count: 10_000)).utf8))
        XCTAssertLessThan(combining.unicodeScalars.count, DiffDocument.maximumLineScalars + 100)
    }

    func testHeaderFactsAndTitle() throws {
        let renamed = try document(
            "diff --git a/old.txt b/new\u{202E}.txt\nsimilarity index 90%\nrename from old.txt\nrename to new.txt\nold mode 100644\nnew mode 100755\n--- a/old.txt\n+++ b/new.txt\n@@ -1 +1 @@\n-a\n+b\n",
            path: "new\u{202E}.txt")
        XCTAssertEqual(renamed.title, "new\\u{202E}.txt")
        XCTAssertEqual(renamed.facts, ["Renamed from old.txt (90%)", "Mode 100644 → 100755"])
    }

    func testNotices() throws {
        XCTAssertEqual(try document("").unifiedRows(), [.notice(DiffDocument.noChanges)])
        XCTAssertEqual(
            try document("diff --git a/i b/i\nindex 1..2 100644\nBinary files a/i and b/i differ\n").unifiedRows(),
            [.notice("Binary file. Its contents are not shown.")])
        let old = String(repeating: "a", count: 40)
        let new = String(repeating: "b", count: 40)
        XCTAssertEqual(
            try document(
                "diff --git a/lib b/lib\nindex a..b 160000\n--- a/lib\n+++ b/lib\n@@ -1 +1 @@\n-Subproject commit \(old)\n+Subproject commit \(new)\n"
            ).unifiedRows(),
            [.notice("Submodule commit aaaaaaa → bbbbbbb")])
        XCTAssertEqual(
            try document("diff --cc f\n@@@ -1 -1 +1 @@@\n++x\n").unifiedRows(),
            [.notice("Conflicted file. The combined diff is not shown yet; resolve it in Terminal.")])
        XCTAssertEqual(
            try document("diff --git a/r b/r\nold mode 100644\nnew mode 100755\n").unifiedRows(),
            [.notice("Only the file mode changed.")])
        XCTAssertEqual(
            try document("diff --git a/a b/b\nsimilarity index 100%\nrename from a\nrename to b\n").unifiedRows(),
            [.notice("Content unchanged.")])
    }

    /// A type change shows both blocks under their own headers.
    func testTypeChangeShowsBothBlocks() throws {
        let doc = try document(
            "diff --git a/l b/l\ndeleted file mode 100644\n--- a/l\n+++ /dev/null\n@@ -1 +0,0 @@\n-text\ndiff --git a/l b/l\nnew file mode 120000\n--- /dev/null\n+++ b/l\n@@ -0,0 +1 @@\n+target\n"
        )
        let headers = doc.unifiedRows().compactMap { if case .fileHeader(let title) = $0 { title } else { nil } }
        XCTAssertEqual(headers, ["Deleted file", "Added symbolic link"])
        XCTAssertTrue(doc.facts.contains("Symbolic link: the link target text is shown"))
    }

    /// screens.md S-10: over 10,000 lines asks first; truncated output is flagged.
    func testLargeAndTruncated() throws {
        let count = DiffDocument.largeLineThreshold + 1
        let body = (1...count).map { "+line \($0)" }.joined(separator: "\n")
        let large = try document("diff --git a/f b/f\n--- /dev/null\n+++ b/f\n@@ -0,0 +1,\(count) @@\n\(body)\n")
        XCTAssertTrue(large.isLarge)
        XCTAssertEqual(large.lineCount, count)
        XCTAssertFalse(try document(modified).isLarge)

        let truncated = try document(String(modified.dropLast(5)), truncated: true)
        XCTAssertTrue(truncated.isTruncated)
    }
}
