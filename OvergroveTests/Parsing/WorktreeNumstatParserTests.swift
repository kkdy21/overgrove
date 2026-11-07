import Foundation
import XCTest

@testable import Overgrove

/// PAR-NUMSTAT-06 (parsing-spec.md §8.3): `diff [--cached] --numstat -z -M` of a worktree (#230).
final class WorktreeNumstatParserTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    private func file(_ path: String, in files: [FileStat]) throws -> FileStat {
        try XCTUnwrap(files.first { $0.path.display == path }, "missing \(path)")
    }

    /// Staged output of the normal fixture's main worktree (git 2.54.0): a path with a line feed, a rename, an add,
    /// the `MM` file, a delete, and a modify.
    private let fixtureStaged =
        "1\t0\tline\nbreak.txt\u{0}0\t0\t\u{0}src/old-name.txt\u{0}src/new-name.txt\u{0}1\t0\tsrc/staged-added.txt\u{0}"
        + "1\t0\tsrc/staged-and-unstaged.txt\u{0}0\t2\tsrc/staged-deleted.txt\u{0}1\t0\tsrc/staged-modified.txt\u{0}"

    /// Unstaged output of the fixture's conflict worktree (git 2.54.0): each unmerged path that still has a stage 2
    /// prints twice, `0 0` and then stage 2 against the worktree.
    private let conflictUnstaged =
        "0\t0\tboth-added.txt\u{0}4\t0\tboth-added.txt\u{0}0\t0\tconflict.txt\u{0}4\t0\tconflict.txt\u{0}"
        + "0\t0\tdeleted-by-us.txt\u{0}"

    func testFixtureStagedOutput() throws {
        let result = try NumstatParser.parseWorktreeFiles(data(fixtureStaged))
        XCTAssertFalse(result.isPartial)
        XCTAssertEqual(result.files.count, 6)
        let lineBreak = try file("line\nbreak.txt", in: result.files)
        XCTAssertEqual(lineBreak.added, 1)
        XCTAssertEqual(lineBreak.deleted, 0)
        let rename = try file("src/new-name.txt", in: result.files)
        XCTAssertEqual(rename.originalPath, GitPath("src/old-name.txt"))
        XCTAssertEqual(rename.added, 0)
        XCTAssertEqual(try file("src/staged-deleted.txt", in: result.files).deleted, 2)
        XCTAssertTrue(result.files.allSatisfy { $0.status == nil && !$0.isFromUntracked })
    }

    func testBinaryFileHasNoCounts() throws {
        let result = try NumstatParser.parseWorktreeFiles(data("-\t-\timage.png\u{0}3\t1\ta.txt\u{0}"))
        XCTAssertTrue(try file("image.png", in: result.files).isBinary)
        XCTAssertFalse(try file("a.txt", in: result.files).isBinary)
    }

    func testConflictedPathsAreDropped() throws {
        let conflicted: Set<GitPath> = [
            GitPath("both-added.txt"), GitPath("conflict.txt"), GitPath("deleted-by-us.txt"),
        ]
        let result = try NumstatParser.parseWorktreeFiles(data(conflictUnstaged), excluding: conflicted)
        XCTAssertEqual(result.files, [])
    }

    func testConflictedPathsAreDroppedButOthersKept() throws {
        let input = conflictUnstaged + "2\t1\tother.txt\u{0}"
        let result = try NumstatParser.parseWorktreeFiles(
            data(input), excluding: [GitPath("both-added.txt"), GitPath("conflict.txt"), GitPath("deleted-by-us.txt")])
        XCTAssertEqual(result.files.map(\.path), [GitPath("other.txt")])
    }

    /// A path repeated without being conflicted would attach one record's numbers to the other: fail the parse.
    func testDuplicateWithoutConflictFails() {
        XCTAssertThrowsError(try NumstatParser.parseWorktreeFiles(data(conflictUnstaged))) { error in
            XCTAssertEqual((error as? ParseError)?.reason, "duplicate path")
        }
    }

    /// The exclusion matches raw bytes: a different path that displays the same is not excluded.
    func testExclusionMatchesRawBytes() throws {
        let latin1 = GitPath(raw: Data([0x63, 0xE9]))  // "c\u{E9}" in Latin-1, not UTF-8
        let input = Data("1\t0\t".utf8) + Data([0x63, 0xC3, 0xA9, 0x00])  // "cé" in UTF-8
        let result = try NumstatParser.parseWorktreeFiles(input, excluding: [latin1])
        XCTAssertEqual(result.files.count, 1)
    }

    func testTruncatedOutputKeepsCompleteRecords() throws {
        let input = data("1\t0\ta.txt\u{0}2\t3\tb.t")
        let result = try NumstatParser.parseWorktreeFiles(input, truncated: true)
        XCTAssertTrue(result.isPartial)
        XCTAssertEqual(result.files.map(\.path), [GitPath("a.txt")])
    }

    func testTruncatedInsideRenameDropsIt() throws {
        let input = data("1\t0\ta.txt\u{0}0\t0\t\u{0}old.txt\u{0}")
        let result = try NumstatParser.parseWorktreeFiles(input, truncated: true)
        XCTAssertEqual(result.files.map(\.path), [GitPath("a.txt")])
    }

    func testEmptyOutput() throws {
        XCTAssertEqual(try NumstatParser.parseWorktreeFiles(Data()).files, [])
    }

    func testMalformedCountsFail() {
        for input in ["x\t0\ta\u{0}", "1\t-\ta\u{0}", "+1\t0\ta\u{0}", "1 0 a\u{0}", "1\t0\ta"] {
            XCTAssertThrowsError(try NumstatParser.parseWorktreeFiles(data(input)), input)
        }
    }
}
