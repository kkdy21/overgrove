import Foundation
import XCTest

@testable import Overgrove

/// `PatchParser` (parsing-spec.md §11.5, PAR-PATCH-*).
final class PatchParserTests: XCTestCase {
    private func parse(_ text: String, truncated: Bool = false) throws -> PatchParser.Listing {
        try PatchParser.parse(Data(text.utf8), truncated: truncated)
    }

    private func text(_ line: PatchLine) -> String { String(decoding: line.content, as: UTF8.self) }

    private func assertFails(_ text: String, _ reason: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try parse(text), reason, file: file, line: line) {
            XCTAssertEqual(($0 as? ParseError)?.parser, "PatchParser", reason, file: file, line: line)
        }
    }

    // MARK: PAR-PATCH-01

    func testPAR_PATCH_01_ModifiedFileWithTwoHunks() throws {
        let listing = try parse(
            """
            diff --git a/src/a.swift b/src/a.swift
            index 1111111..2222222 100644
            --- a/src/a.swift
            +++ b/src/a.swift
            @@ -1,3 +1,4 @@ struct A
             one
            -two
            +TWO
            +2.5
             three
            @@ -10 +11 @@
            -ten
            +TEN

            """)
        XCTAssertFalse(listing.isPartial)
        let file = try XCTUnwrap(listing.files.first)
        XCTAssertEqual(listing.files.count, 1)
        XCTAssertEqual(file.oldPath?.display, "src/a.swift")
        XCTAssertEqual(file.newPath?.display, "src/a.swift")
        XCTAssertEqual(file.oldMode, "100644")
        XCTAssertEqual(file.hunks.count, 2)
        let first = file.hunks[0]
        XCTAssertEqual([first.oldStart, first.oldCount, first.newStart, first.newCount], [1, 3, 1, 4])
        XCTAssertEqual(String(decoding: first.section, as: UTF8.self), "struct A")
        XCTAssertEqual(first.lines.map(\.kind), [.context, .removed, .added, .added, .context])
        XCTAssertEqual(first.lines.map(\.oldNumber), [1, 2, nil, nil, 3])
        XCTAssertEqual(first.lines.map(\.newNumber), [1, nil, 2, 3, 4])
        XCTAssertEqual(first.lines.map(text), ["one", "two", "TWO", "2.5", "three"])
        let second = file.hunks[1]
        XCTAssertEqual([second.oldStart, second.oldCount, second.newStart, second.newCount], [10, 1, 11, 1])
        XCTAssertEqual(second.lines.map(\.oldNumber), [10, nil])
        XCTAssertEqual(second.lines.map(\.newNumber), [nil, 11])
        XCTAssertEqual(listing.lineCount, 7)
    }

    func testPAR_PATCH_01_AddedAndDeletedFiles() throws {
        let added = try XCTUnwrap(
            try parse(
                """
                diff --git a/new.txt b/new.txt
                new file mode 100644
                index 0000000..3333333
                --- /dev/null
                +++ b/new.txt
                @@ -0,0 +1,2 @@
                +a
                +b

                """
            ).files.first)
        XCTAssertTrue(added.isNewFile)
        XCTAssertNil(added.oldPath)
        XCTAssertEqual(added.newMode, "100644")
        XCTAssertEqual(added.hunks[0].lines.map(\.newNumber), [1, 2])

        let deleted = try XCTUnwrap(
            try parse(
                """
                diff --git a/old.txt b/old.txt
                deleted file mode 100755
                index 3333333..0000000
                --- a/old.txt
                +++ /dev/null
                @@ -1 +0,0 @@
                -gone

                """
            ).files.first)
        XCTAssertTrue(deleted.isDeletedFile)
        XCTAssertEqual(deleted.oldMode, "100755")
        XCTAssertNil(deleted.newPath)
        XCTAssertEqual(deleted.hunks[0].lines.map(\.oldNumber), [1])
    }

    // MARK: PAR-PATCH-02

    /// Counts decide where a hunk ends: lines that imitate headers stay content.
    func testPAR_PATCH_02_ContentThatLooksLikeHeaders() throws {
        let file = try XCTUnwrap(
            try parse(
                """
                diff --git a/x b/x
                --- a/x
                +++ b/x
                @@ -1,3 +1,3 @@
                -@@ -1 +1 @@
                +diff --git a/y b/y
                 +++ b/z
                --- a/w
                +rename from q

                """
            ).files.first)
        XCTAssertEqual(file.hunks.count, 1)
        XCTAssertEqual(file.hunks[0].lines.map(\.kind), [.removed, .added, .context, .removed, .added])
        XCTAssertEqual(
            file.hunks[0].lines.map(text), ["@@ -1 +1 @@", "diff --git a/y b/y", "+++ b/z", "-- a/w", "rename from q"])
        XCTAssertNil(file.renameFrom)
    }

    func testPAR_PATCH_02_StructureErrorsFail() {
        let header = "diff --git a/x b/x\n--- a/x\n+++ b/x\n"
        assertFails(header + "@@ -1 +1 @@\n-a\n+b\n+c\n", "more added lines than counted")
        assertFails(header + "@@ -1,2 +1 @@\n-a\n+b\n", "hunk ends early without truncation")
        assertFails(header + "@@ -1 +1 @@\n-a\n+b\njunk\n", "junk after a hunk")
        assertFails(header + "@@ -1 +1 @@\n-a\n?b\n", "unknown line prefix")
        assertFails(header + "@@ -x +1 @@\n", "non-numeric header")
        assertFails(header + "@@ -1 +1\n", "unterminated header")
        assertFails(header + "@@ -1234567890 +1 @@\n", "too many digits")
        assertFails("not a diff\n", "garbage before the first block")
        assertFails("diff --git a/x b/x\nold mode 10064\n", "bad mode")
        assertFails("diff --git a/x b/x\nsimilarity index 101%\n", "bad similarity")
        assertFails("diff --git a/x b/x\nrename from \"unterminated\n", "bad quoting")
    }

    // MARK: PAR-PATCH-03

    func testPAR_PATCH_03_QuotedPaths() throws {
        let file = try XCTUnwrap(
            try parse(
                """
                diff --git "a/tab\\there" "b/new\\nline"
                similarity index 100%
                rename from "tab\\there"
                rename to "\\303\\251t\\303\\251\\377.txt"

                """
            ).files.first)
        XCTAssertEqual(file.similarity, 100)
        XCTAssertEqual(file.renameFrom?.raw, Data("tab\there".utf8))
        XCTAssertEqual(file.renameTo?.raw, Data([0xC3, 0xA9, 0x74, 0xC3, 0xA9, 0xFF]) + Data(".txt".utf8))
        XCTAssertEqual(file.renameTo?.isRepresentable, false, "\\377 is not UTF-8")
        XCTAssertEqual(file.hunks, [])

        XCTAssertEqual(
            try PatchParser.unquote(Data(#""a\"b\\c\a\b\f\v\r""#.utf8), at: 0),
            Data("a\"b\\c\u{7}\u{8}\u{C}\u{B}\r".utf8))
        XCTAssertEqual(try PatchParser.unquote(Data("-dash-leading.txt".utf8), at: 0), Data("-dash-leading.txt".utf8))
        for bad in [#""a\q""#, #""a\1""#, #""a"b""#, #"""#, #""a\""#] {
            XCTAssertThrowsError(try PatchParser.unquote(Data(bad.utf8), at: 0), bad)
        }
    }

    /// git appends a TAB to `---`/`+++` paths that contain a space.
    func testPAR_PATCH_03_PathWithSpaceAndTrailingTab() throws {
        let file = try XCTUnwrap(
            try parse("diff --git a/with space.txt b/with space.txt\n--- a/with space.txt\t\n+++ b/with space.txt\t\n")
                .files.first)
        XCTAssertEqual(file.oldPath?.display, "with space.txt")
        XCTAssertEqual(file.newPath?.display, "with space.txt")
    }

    func testPAR_PATCH_03_CopyWithSimilarity() throws {
        let file = try XCTUnwrap(
            try parse(
                "diff --git a/a.txt b/b.txt\nsimilarity index 90%\ncopy from a.txt\ncopy to b.txt\n--- a/a.txt\n+++ b/b.txt\n@@ -1 +1 @@\n-x\n+y\n"
            ).files.first)
        XCTAssertEqual(file.copyFrom?.display, "a.txt")
        XCTAssertEqual(file.copyTo?.display, "b.txt")
        XCTAssertEqual(file.similarity, 90)
    }

    // MARK: PAR-PATCH-04

    func testPAR_PATCH_04_ModeOnlyChange() throws {
        let file = try XCTUnwrap(
            try parse("diff --git a/run.sh b/run.sh\nold mode 100644\nnew mode 100755\n").files.first)
        XCTAssertEqual([file.oldMode, file.newMode], ["100644", "100755"])
        XCTAssertEqual(file.hunks, [])
    }

    /// A file replaced by a symbolic link: two blocks for one path.
    func testPAR_PATCH_04_TypeChangeIsTwoBlocks() throws {
        let listing = try parse(
            """
            diff --git a/link b/link
            deleted file mode 100644
            index 1111111..0000000
            --- a/link
            +++ /dev/null
            @@ -1 +0,0 @@
            -content
            diff --git a/link b/link
            new file mode 120000
            index 0000000..2222222
            --- /dev/null
            +++ b/link
            @@ -0,0 +1 @@
            +target/path
            \\ No newline at end of file

            """)
        XCTAssertEqual(listing.files.count, 2)
        XCTAssertFalse(listing.files[0].isSymlink)
        XCTAssertTrue(listing.files[1].isSymlink)
        XCTAssertEqual(listing.files[1].hunks[0].lines.map(\.kind), [.added, .noNewline])
    }

    func testPAR_PATCH_04_Binary() throws {
        let file = try XCTUnwrap(
            try parse(
                "diff --git a/i.png b/i.png\nindex 1111111..2222222 100644\nBinary files a/i.png and b/i.png differ\n"
            )
            .files.first)
        XCTAssertTrue(file.isBinary)
        XCTAssertEqual(file.hunks, [])
    }

    func testPAR_PATCH_04_Submodule() throws {
        let old = String(repeating: "a", count: 40)
        let new = String(repeating: "b", count: 40)
        let file = try XCTUnwrap(
            try parse(
                "diff --git a/lib b/lib\nindex aaaaaaa..bbbbbbb 160000\n--- a/lib\n+++ b/lib\n@@ -1 +1 @@\n-Subproject commit \(old)\n+Subproject commit \(new)-dirty\n"
            ).files.first)
        XCTAssertEqual(file.submodule, FilePatch.SubmoduleChange(old: ObjectID(old), new: ObjectID(new)))
        // The same text in an ordinary file is not a submodule.
        let plain = try XCTUnwrap(
            try parse(
                "diff --git a/f b/f\nindex aaaaaaa..bbbbbbb 100644\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-Subproject commit \(old)\n+x\n"
            ).files.first)
        XCTAssertNil(plain.submodule)
    }

    func testPAR_PATCH_04_CombinedDiffIsFlaggedAndSkipped() throws {
        let listing = try parse(
            """
            diff --cc conflict.txt
            index 1111111,2222222..0000000
            --- a/conflict.txt
            +++ b/conflict.txt
            @@@ -1,1 -1,1 +1,5 @@@
            ++<<<<<<< HEAD
             +ours
            ++=======
            + theirs
            ++>>>>>>> branch

            """)
        XCTAssertEqual(listing.files.count, 1)
        XCTAssertTrue(listing.files[0].isCombined)
        XCTAssertEqual(listing.files[0].hunks, [])
    }

    // MARK: PAR-PATCH-05

    func testPAR_PATCH_05_NoNewlineOnBothSides() throws {
        let file = try XCTUnwrap(
            try parse(
                "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-old\n\\ No newline at end of file\n+new\n\\ No newline at end of file\n"
            ).files.first)
        XCTAssertEqual(file.hunks[0].lines.map(\.kind), [.removed, .noNewline, .added, .noNewline])
    }

    func testPAR_PATCH_05_RawContentIsKept() throws {
        var bytes = Data("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,2 +1,2 @@\n-crlf\r\n+bad".utf8)
        bytes.append(contentsOf: [0xFF, 0xFE])
        bytes.append(Data("\n \n".utf8))
        let lines = try XCTUnwrap(try PatchParser.parse(bytes).files.first?.hunks.first?.lines)
        XCTAssertEqual(lines[0].content, Data("crlf\r".utf8), "CR is kept; the view decides how to show it")
        XCTAssertEqual(lines[1].content, Data("bad".utf8) + Data([0xFF, 0xFE]))
        XCTAssertEqual(lines[2].content, Data(), "an empty context line")
    }

    /// `diff.suppressBlankEmpty` prints an empty context line without its space.
    func testPAR_PATCH_05_EmptyLineIsContext() throws {
        let lines = try XCTUnwrap(
            try parse("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,3 +1,3 @@\n a\n\n-b\n+c\n").files.first?.hunks.first?
                .lines)
        XCTAssertEqual(lines.map(\.kind), [.context, .context, .removed, .added])
    }

    func testPAR_PATCH_05_LongLine() throws {
        let long = String(repeating: "x", count: 200_000)
        let lines = try XCTUnwrap(
            try parse("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -0,0 +1 @@\n+\(long)\n").files.first?.hunks.first?.lines
        )
        XCTAssertEqual(lines[0].content.count, 200_000)
    }

    /// Shapes captured from real git (Apple Git 2.50.1) by the parser test design for #232.
    func testPAR_PATCH_04_RealGitShapes() throws {
        // Single-commit diff-tree prints the commit first.
        let oid = String(repeating: "a", count: 40)
        let withOID = try parse("\(oid)\ndiff --git a/f b/f\n--- /dev/null\n+++ b/f\n@@ -0,0 +1 @@\n+x\n")
        XCTAssertEqual(withOID.files.count, 1)
        // An OID anywhere else is not a header.
        assertFails("diff --git a/f b/f\n\(oid)\n@@ -1 +1 @@\n-a\n+b\n\(oid)\n", "stray OID after a hunk")
        // A quoted path with a TAB inside and git's trailing TAB after the closing quote.
        let quoted = try XCTUnwrap(
            try parse("diff --git a/x \"b/r m\\t2.txt\"\n--- a/x\n+++ \"b/r m\\t2.txt\"\t\n").files.first)
        XCTAssertEqual(quoted.newPath?.raw, Data("r m\t2.txt".utf8))
        // `git diff --cached` on an unmerged path.
        let unmerged = try parse("* Unmerged path conflict.txt\n")
        XCTAssertEqual(unmerged.files.count, 1)
        XCTAssertTrue(unmerged.files[0].isUnmerged)
        XCTAssertEqual(unmerged.files[0].newPath?.display, "conflict.txt")
    }

    /// Output reshaped by repository config (color, no prefix, submodule log) fails instead of being misread; #239
    /// pins the arguments that prevent it.
    func testPAR_PATCH_04_ConfigReshapedOutputFails() {
        assertFails("\u{1B}[1mdiff --git a/f b/f\u{1B}[m\n", "ANSI colour")
        assertFails("Submodule sm 664920d..65d38cd (rewind):\n", "diff.submodule=log")
        assertFails(
            "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n\u{1B}[31m-a\u{1B}[m\n+b\n", "coloured hunk line")
    }

    func testPAR_PATCH_05_MisplacedNoNewlineMarkerFails() {
        let header = "diff --git a/f b/f\n--- a/f\n+++ b/f\n"
        assertFails(header + "@@ -1 +1 @@\n\\ No newline at end of file\n-a\n+b\n", "marker first")
        assertFails(header + "@@ -1,2 +1 @@\n-a\n\\ x\n\\ x\n-b\n+c\n", "two markers in a row")
        assertFails(header + "@@ -1 +1 @@\n-a\n+b\n\\ x\n\\ x\n", "two markers after the hunk")
    }

    func testPAR_PATCH_04_HunkInABinaryPatchFails() {
        assertFails("diff --git a/i b/i\nBinary files a/i and b/i differ\n@@ -1 +1 @@\n-a\n+b\n", "binary with hunk")
    }

    /// The parser does not depend on header paths or context size, so `diff.context` and `core.quotePath` (which
    /// #241 leaves alone) cannot break it: a raw non-ASCII header path reads the same as its quoted form, and a hunk
    /// with ten context lines reads like one with three.
    func testPAR_PATCH_03_IndependentOfQuotePathAndContextSize() throws {
        let quoted = try XCTUnwrap(
            try parse("diff --git a/x b/x\nrename from \"\\355\\225\\234.txt\"\nrename to b.txt\n").files.first)
        var raw = Data("diff --git a/x b/x\nrename from ".utf8)
        raw.append(contentsOf: [0xED, 0x95, 0x9C])
        raw.append(Data(".txt\nrename to b.txt\n".utf8))
        let unquoted = try XCTUnwrap(try PatchParser.parse(raw).files.first)
        XCTAssertEqual(quoted.renameFrom, unquoted.renameFrom)
        XCTAssertEqual(unquoted.renameFrom?.display, "한.txt")

        let context = (1...10).map { " c\($0)" }.joined(separator: "\n")
        let wide = try XCTUnwrap(
            try parse("diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,21 +1,21 @@\n\(context)\n-a\n+b\n\(context)\n")
                .files.first?.hunks.first)
        XCTAssertEqual(wide.lines.count, 22)
        XCTAssertEqual(wide.lines.last?.oldNumber, 21)
    }

    // MARK: PAR-PATCH-06

    func testPAR_PATCH_06_Truncation() throws {
        let full = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,3 +1,3 @@\n a\n-b\n+c\n d\n"
        // Cut in the middle of the last line: that partial line is dropped, the hunk keeps what arrived.
        let cut = try parse(String(full.prefix(full.count - 2)), truncated: true)
        XCTAssertTrue(cut.isPartial)
        XCTAssertEqual(cut.files.first?.hunks.first?.lines.map(\.kind), [.context, .removed, .added])
        // Cut in the middle of a hunk header: the header line is dropped.
        let header = "diff --git a/f b/f\n--- a/f\n+++ b/f\n@@ -1,3 +1"
        XCTAssertEqual(try parse(header, truncated: true).files.first?.hunks, [])
        // Missing lines without the truncation flag are an error.
        XCTAssertThrowsError(try parse(String(full.prefix(full.count - 3))))
    }

    /// SEC-T15-08: a hunk header claiming a billion lines over a short (cut) body reserves no more than the input.
    func testSECT15_08_HugeHunkCountOverShortBody() throws {
        let listing = try parse(
            "diff --git a/f b/f\n--- /dev/null\n+++ b/f\n@@ -0,0 +1,999999999 @@\n+a\n+b\n", truncated: true)
        XCTAssertEqual(listing.files.first?.hunks.first?.lines.count, 2)
        XCTAssertLessThan(listing.files.first?.hunks.first?.lines.capacity ?? .max, 1_000)
    }

    func testPAR_PATCH_06_EmptyOutput() throws {
        XCTAssertEqual(try parse(""), PatchParser.Listing(files: [], isPartial: false))
        XCTAssertEqual(try parse("", truncated: true).files, [])
    }
}
