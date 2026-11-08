import Foundation
import XCTest

@testable import Overgrove

/// Word-level highlights and whitespace marks in S-10 (#387, screens.md S-10).
final class WordDiffTests: XCTestCase {
    private func changes(_ old: String, _ new: String) -> (old: [Range<Int>], new: [Range<Int>])? {
        var budget = WordDiff.maximumCellsPerFile
        return WordDiff.changes(old: old, new: new, budget: &budget)
    }

    /// Tokens: runs of letters, digits, and `_`; runs of whitespace; any other scalar alone.
    func testOnlyTheChangedWordIsMarked() throws {
        let result = try XCTUnwrap(changes("let lines = split()", "let records = split()"))
        XCTAssertEqual(result.old, [4..<9])
        XCTAssertEqual(result.new, [4..<11])
    }

    func testAdjacentChangedTokensMergeAndPunctuationIsItsOwnToken() throws {
        let result = try XCTUnwrap(changes("call(a, b)", "call(x, y, z)"))
        XCTAssertEqual(result.old, [5..<6, 8..<9])
        XCTAssertEqual(result.new, [5..<6, 8..<12])
    }

    /// A line with nothing in common is left to the line background.
    func testNothingInCommonIsNotMarked() {
        XCTAssertNil(changes("alpha", "beta"))
        XCTAssertNil(changes("", "anything"))
    }

    /// T15: long lines and an exhausted budget are not compared.
    func testLimits() {
        let long = String(repeating: "a ", count: WordDiff.maximumLineScalars)
        XCTAssertNil(changes(long, long + "b"))
        // The shared start and end need no table; what is left (`c` against `x`) needs 4 cells.
        var budget = 3
        XCTAssertNil(WordDiff.changes(old: "a b c d e f", new: "a b x d e f", budget: &budget))
        XCTAssertEqual(budget, 3, "a pair over the budget spends nothing")
        budget = 4
        XCTAssertNotNil(WordDiff.changes(old: "a b c d e f", new: "a b x d e f", budget: &budget))
        XCTAssertEqual(budget, 0)
    }

    /// Escaped or combining text is compared by scalar offsets, the same offsets the view draws.
    func testOffsetsAreUnicodeScalars() throws {
        let result = try XCTUnwrap(changes("na\u{EF}ve x", "nai\u{308}ve x"))
        XCTAssertEqual(result.old, [0..<5])
        XCTAssertEqual(result.new, [0..<6])
    }
}

/// `DiffDocument` rows with marks (`marked: true`), as the viewer asks for them.
final class DiffDocumentMarksTests: XCTestCase {
    private func document(_ patch: String) throws -> DiffDocument {
        DiffDocument(
            listing: try PatchParser.parse(Data(patch.utf8)), path: GitPath("a.txt"),
            source: DiffDocument.Source(label: "Unstaged", kindLetter: "M"))
    }

    private func marks(_ rows: [DiffDocument.Row]) -> [DiffDocument.LineMarks] {
        rows.compactMap { if case .line(_, _, _, _, let marks) = $0 { marks } else { nil } }
    }

    func testRemovedAndAddedRunsArePairedInOrder() throws {
        let patch = """
            diff --git a/a.txt b/a.txt
            --- a/a.txt
            +++ b/a.txt
            @@ -1,3 +1,4 @@
            -one two
            -three four
            +one 2
            +three 4
            +extra
             same

            """
        let lines = marks(try document(patch).unifiedRows(marked: true))
        XCTAssertEqual(lines.map(\.changed), [[4..<7], [6..<10], [4..<5], [6..<7], [], []])
        XCTAssertEqual(try document(patch).unifiedRows().count, try document(patch).unifiedRows(marked: true).count)
        XCTAssertTrue(marks(try document(patch).unifiedRows()).allSatisfy { $0 == .none }, "unmarked by default")

        let split = try document(patch).splitRows(marked: true)
        let pairs = split.compactMap { row -> (DiffDocument.Side?, DiffDocument.Side?)? in
            if case .pair(let left, let right) = row { (left, right) } else { nil }
        }
        XCTAssertEqual(pairs[0].0?.marks.changed, [4..<7])
        XCTAssertEqual(pairs[0].1?.marks.changed, [4..<5])
    }

    /// Whitespace marks: TABs (already expanded), trailing whitespace on changed lines only, and a CR.
    func testWhitespaceMarks() throws {
        let patch =
            "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1,2 +1,2 @@\n"
            + " \tcontext  \n-a\tb  \r\n+a\tb\n"
        let lines = marks(try document(patch).unifiedRows(marked: true))
        XCTAssertEqual(lines[0].tabs, [0..<4])
        XCTAssertNil(lines[0].trailing, "context lines do not mark trailing whitespace")
        XCTAssertEqual(lines[1].tabs, [1..<4])
        XCTAssertEqual(lines[1].trailing, 5..<7)
        XCTAssertTrue(lines[1].hasCarriageReturn)
        XCTAssertFalse(lines[2].hasCarriageReturn)
        XCTAssertNil(lines[2].trailing)
    }

    /// Escaped characters keep their marks aligned: offsets are in the shown text.
    func testMarksFollowEscapedText() throws {
        let patch =
            "diff --git a/a.txt b/a.txt\n--- a/a.txt\n+++ b/a.txt\n@@ -1 +1 @@\n"
            + "-\u{202E}x\told\n+\u{202E}x\tnew\n"
        let rows = try document(patch).unifiedRows(marked: true)
        guard case .line(_, _, _, let text, let marks) = rows[1] else { return XCTFail("no line") }
        let scalars = Array(text.unicodeScalars)
        let tab = try XCTUnwrap(marks.tabs.first)
        XCTAssertTrue(scalars[tab].allSatisfy { $0 == " " }, "the tab range is the expanded spaces")
        let changed = try XCTUnwrap(marks.changed.first)
        XCTAssertEqual(String(String.UnicodeScalarView(scalars[changed])), "old")
    }
}
