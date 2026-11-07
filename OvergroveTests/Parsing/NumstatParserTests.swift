import Foundation
import XCTest

@testable import Overgrove

/// PAR-NUMSTAT-01…05 (parsing-spec.md §8).
final class NumstatParserTests: XCTestCase {
    private typealias Fixtures = NumstatParserFixtures

    private let zeroOID = String(repeating: "0", count: 40)
    private let blobA = String(repeating: "a", count: 40)
    private let blobB = String(repeating: "b", count: 40)

    private func data(_ text: String) -> Data { Data(text.utf8) }

    /// One raw record: `:<srcmode> <dstmode> <srcoid> <dstoid> <status>␀<path>␀[<new path>␀]`.
    private func raw(
        _ status: String,
        _ paths: String...,
        modes: String = "100644 100644",
        oids: String? = nil
    ) -> String {
        let oidPair = oids ?? "\(blobA) \(blobB)"
        return ":\(modes) \(oidPair) \(status)\u{0}" + paths.map { "\($0)\u{0}" }.joined()
    }

    private func numstat(_ added: String, _ deleted: String, _ path: String) -> String {
        "\(added)\t\(deleted)\t\(path)\u{0}"
    }

    private func renameNumstat(_ added: String, _ deleted: String, from old: String, to new: String) -> String {
        "\(added)\t\(deleted)\t\u{0}\(old)\u{0}\(new)\u{0}"
    }

    private func paths(_ files: [FileStat]) -> [String] { files.map(\.path.display) }

    private func file(_ path: String, in files: [FileStat]) throws -> FileStat {
        try XCTUnwrap(files.first { $0.path.display == path }, "missing \(path)")
    }

    private func assertCommitFails(
        _ input: Data,
        reason: String,
        offset: Int? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertFails({ _ = try NumstatParser.parseCommitFiles(input) }, reason, offset, file, line)
    }

    private func assertStashFails(
        _ input: Data,
        reason: String,
        offset: Int? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        assertFails({ _ = try NumstatParser.parseStashFiles(input) }, reason, offset, file, line)
    }

    private func assertFails(
        _ parse: () throws -> Void,
        _ reason: String,
        _ offset: Int?,
        _ file: StaticString,
        _ line: UInt
    ) {
        XCTAssertThrowsError(try parse(), file: file, line: line) { error in
            let parseError = error as? ParseError
            XCTAssertEqual(parseError?.parser, "NumstatParser", file: file, line: line)
            XCTAssertEqual(parseError?.reason, reason, file: file, line: line)
            if let offset { XCTAssertEqual(parseError?.offset, offset, file: file, line: line) }
        }
    }

    // MARK: - PAR-NUMSTAT-01 added, modified, deleted

    func testPARNUMSTAT01_AddModifyDeleteFromRealOutput() throws {
        let result = try NumstatParser.parseCommitFiles(Fixtures.addModifyDelete)
        XCTAssertFalse(result.isPartial)
        XCTAssertEqual(
            result.files,
            [
                FileStat(path: GitPath("keep.txt"), status: .modified, added: 2, deleted: 1),
                FileStat(path: GitPath("new file.txt"), status: .added, added: 2, deleted: 0),
                FileStat(path: GitPath("old.txt"), status: .deleted, added: 0, deleted: 1),
            ]
        )
    }

    func testPARNUMSTAT01_RootCommitListsEveryFileAsAdded() throws {
        let files = try NumstatParser.parseCommitFiles(Fixtures.rootCommit).files
        XCTAssertEqual(paths(files), ["guide.md", "keep.txt", "link-target", "old.txt"])
        XCTAssertTrue(files.allSatisfy { $0.status == .added && $0.deleted == 0 && $0.originalPath == nil })
        XCTAssertEqual(files.map(\.added), [5, 3, 1, 1])
    }

    func testPARNUMSTAT01_EmptyCommitHasNoFiles() throws {
        XCTAssertEqual(try NumstatParser.parseCommitFiles(Data()), NumstatParser.Files(files: [], isPartial: false))
        XCTAssertEqual(try NumstatParser.parseStashFiles(Data()), NumstatParser.Files(files: [], isPartial: false))
    }

    func testPARNUMSTAT01_UnusualPathsKeepTheirRawBytes() throws {
        let files = try NumstatParser.parseCommitFiles(Fixtures.unusualPaths).files
        XCTAssertEqual(files.count, 4)
        // A path starting with `:` is read by position, never mistaken for a raw record.
        XCTAssertEqual(files[0].path, GitPath(":colon.txt"))
        let invalid = files[1].path
        XCTAssertEqual(invalid.raw, Data([0x62, 0x61, 0x64, 0xFF]) + data("name.txt"))
        XCTAssertFalse(invalid.isRepresentable)
        XCTAssertNil(invalid.argument)
        XCTAssertEqual(files[2].path, GitPath("tab\tname.txt"))
        XCTAssertEqual(files[3].path, GitPath("한글.txt"))
        XCTAssertTrue(files.allSatisfy { $0.status == .added && $0.added == 1 && $0.deleted == 0 })
    }

    func testPARNUMSTAT01_NumstatPathMayContainTabs() throws {
        let input = data(raw("M", "a\tb\tc") + numstat("1", "2", "a\tb\tc"))
        let stat = try XCTUnwrap(try NumstatParser.parseCommitFiles(input).files.first)
        XCTAssertEqual(stat.path, GitPath("a\tb\tc"))
        XCTAssertEqual(stat.added, 1)
        XCTAssertEqual(stat.deleted, 2)
    }

    // MARK: - PAR-NUMSTAT-02 renames

    func testPARNUMSTAT02_PureRenameFromRealOutput() throws {
        let files = try NumstatParser.parseCommitFiles(Fixtures.pureRename).files
        XCTAssertEqual(
            files,
            [
                FileStat(
                    path: GitPath("docs/manual.md"),
                    originalPath: GitPath("guide.md"),
                    status: .renamed(score: 100),
                    added: 0,
                    deleted: 0
                )
            ]
        )
    }

    func testPARNUMSTAT02_RenameWithEditKeepsScoreAndCounts() throws {
        let stat = try XCTUnwrap(try NumstatParser.parseCommitFiles(Fixtures.renameWithEdit).files.first)
        XCTAssertEqual(stat.path, GitPath("docs/guide-v2.md"))
        XCTAssertEqual(stat.originalPath, GitPath("docs/manual.md"))
        XCTAssertEqual(stat.status, .renamed(score: 83))
        XCTAssertEqual(stat.added, 1)
        XCTAssertEqual(stat.deleted, 0)
    }

    func testPARNUMSTAT02_SHA256RepositoryRename() throws {
        let stat = try XCTUnwrap(try NumstatParser.parseCommitFiles(Fixtures.sha256Rename).files.first)
        XCTAssertEqual(stat.path, GitPath("b.txt"))
        XCTAssertEqual(stat.originalPath, GitPath("a.txt"))
        XCTAssertEqual(stat.status, .renamed(score: 50))
    }

    func testPARNUMSTAT02_CopyWithAndWithoutScore() throws {
        let input = data(
            raw("C075", "src.txt", "copy.txt") + raw("R", "old.txt", "new.txt")
                + renameNumstat("3", "0", from: "src.txt", to: "copy.txt")
                + renameNumstat("0", "0", from: "old.txt", to: "new.txt")
        )
        let files = try NumstatParser.parseCommitFiles(input).files
        XCTAssertEqual(files.map(\.status), [.copied(score: 75), .renamed(score: nil)])
        XCTAssertEqual(files.map(\.originalPath), [GitPath("src.txt"), GitPath("old.txt")])
    }

    func testPARNUMSTAT02_StashRenameHasPathsButNoStatus() throws {
        let stat = try XCTUnwrap(try NumstatParser.parseStashFiles(Fixtures.stash).files.first)
        XCTAssertEqual(stat.path, GitPath("docs/handbook.md"))
        XCTAssertEqual(stat.originalPath, GitPath("docs/manual.md"))
        XCTAssertNil(stat.status)
        XCTAssertEqual(stat.added, 1)
    }

    func testPARNUMSTAT02_RenameNumstatWithEmptyPathsFails() {
        let missingNew = data(raw("R100", "a", "b") + "0\t0\t\u{0}a\u{0}\u{0}")
        assertCommitFails(missingNew, reason: "empty path")
        let missingOld = data(raw("R100", "a", "b") + "0\t0\t\u{0}\u{0}b\u{0}")
        assertCommitFails(missingOld, reason: "empty path")
    }

    // MARK: - PAR-NUMSTAT-03 binary

    func testPARNUMSTAT03_BinaryFileHasNoLineCounts() throws {
        let stat = try XCTUnwrap(try NumstatParser.parseCommitFiles(Fixtures.binaryAdd).files.first)
        XCTAssertEqual(stat.path, GitPath("assets/binary.bin"))
        XCTAssertEqual(stat.status, .added)
        XCTAssertTrue(stat.isBinary)
        XCTAssertNil(stat.added)
        XCTAssertNil(stat.deleted)
    }

    func testPARNUMSTAT03_BinaryRenameAndUnpairedAddDelete() throws {
        let files = try NumstatParser.parseCommitFiles(Fixtures.binaryRename).files
        XCTAssertEqual(
            files,
            [
                FileStat(
                    path: GitPath("assets/moved.bin"),
                    originalPath: GitPath("assets/binary.bin"),
                    status: .renamed(score: 100),
                    added: nil,
                    deleted: nil
                ),
                FileStat(path: GitPath("renamed\ttab.txt"), status: .added, added: 2, deleted: 0),
                FileStat(path: GitPath("tab\tname.txt"), status: .deleted, added: 0, deleted: 1),
            ]
        )
    }

    func testPARNUMSTAT03_HalfBinaryCountsFail() {
        assertCommitFails(data(raw("M", "f") + numstat("-", "3", "f")), reason: "binary marker in one count only")
        assertStashFails(data(numstat("3", "-", "f")), reason: "binary marker in one count only")
    }

    // MARK: - PAR-NUMSTAT-04 merging raw and numstat

    func testPARNUMSTAT04_StatusComesFromRawAndCountsFromNumstat() throws {
        let stat = try XCTUnwrap(try NumstatParser.parseCommitFiles(Fixtures.typeChange).files.first)
        XCTAssertEqual(stat, FileStat(path: GitPath("link-target"), status: .typeChanged, added: 1, deleted: 1))
    }

    func testPARNUMSTAT04_EveryStatusLetter() throws {
        let input = data(
            raw("A", "a", modes: "000000 100644", oids: "\(zeroOID) \(blobB)")
                + raw("M", "m", modes: "100644 100755")
                + raw("D", "d", modes: "100644 000000", oids: "\(blobA) \(zeroOID)")
                + raw("T", "t", modes: "100644 120000")
                + raw("R090", "r0", "r1") + raw("C100", "c0", "c1", modes: "160000 160000")
                + numstat("1", "0", "a") + numstat("0", "0", "m") + numstat("0", "1", "d") + numstat("1", "1", "t")
                + renameNumstat("1", "1", from: "r0", to: "r1") + renameNumstat("1", "1", from: "c0", to: "c1")
        )
        let files = try NumstatParser.parseCommitFiles(input).files
        XCTAssertEqual(
            files.map(\.status),
            [.added, .modified, .deleted, .typeChanged, .renamed(score: 90), .copied(score: 100)]
        )
        XCTAssertEqual(files.compactMap { $0.status?.code }, ["A", "M", "D", "T", "R", "C"])
    }

    func testPARNUMSTAT04_NumstatWithoutRawRecordFails() {
        let input = data(raw("M", "a") + numstat("1", "0", "a") + numstat("1", "0", "b"))
        let offset = input.count - numstat("1", "0", "b").utf8.count
        assertCommitFails(input, reason: "numstat record without raw record", offset: offset)
    }

    func testPARNUMSTAT04_RawRecordWithoutNumstatFails() {
        let second = raw("M", "b")
        let input = data(raw("M", "a") + second + numstat("1", "0", "a"))
        let offset = raw("M", "a").utf8.count
        assertCommitFails(input, reason: "raw record without numstat record", offset: offset)
    }

    func testPARNUMSTAT04_NumstatForAnotherPathFails() {
        let input = data(raw("M", "a") + numstat("1", "0", "b"))
        assertCommitFails(input, reason: "numstat record does not match raw record", offset: raw("M", "a").utf8.count)
    }

    func testPARNUMSTAT04_RenamePathsMustMatchRawRecord() {
        let wrongOld = data(raw("R100", "a", "b") + renameNumstat("0", "0", from: "x", to: "b"))
        assertCommitFails(wrongOld, reason: "numstat record does not match raw record")
        let notRenamed = data(raw("R100", "a", "b") + numstat("0", "0", "b"))
        assertCommitFails(notRenamed, reason: "numstat record does not match raw record")
        let unexpectedRename = data(raw("M", "b") + renameNumstat("0", "0", from: "a", to: "b"))
        assertCommitFails(unexpectedRename, reason: "numstat record does not match raw record")
    }

    func testPARNUMSTAT04_DuplicatePathFails() {
        let input = data(raw("M", "a") + raw("M", "a") + numstat("1", "0", "a") + numstat("1", "0", "a"))
        assertCommitFails(input, reason: "duplicate path", offset: raw("M", "a").utf8.count)
        assertStashFails(data(numstat("1", "0", "a") + numstat("1", "0", "a")), reason: "duplicate path")
    }

    func testPARNUMSTAT04_RawRecordAfterNumstatFails() {
        let input = data(raw("M", "a") + numstat("1", "0", "a") + raw("M", "b") + numstat("1", "0", "b"))
        assertCommitFails(input, reason: "invalid added count")
    }

    func testPARNUMSTAT04_InvalidModesFail() {
        for modes in ["10064 100644", "100648 100644", "100644 1006444", "100644 10064a", " 100644 100644"] {
            assertCommitFails(data(raw("M", "a", modes: modes) + numstat("1", "0", "a")), reason: "invalid raw record")
        }
    }

    func testPARNUMSTAT04_InvalidObjectIDsFail() {
        let upper = String(repeating: "A", count: 40)
        let short = String(repeating: "a", count: 39)
        let sha256 = String(repeating: "b", count: 64)
        for oids in ["\(upper) \(blobB)", "\(blobA) \(short)", "\(blobA) \(sha256)", "\(blobA)  \(blobB)"] {
            assertCommitFails(data(raw("M", "a", oids: oids) + numstat("1", "0", "a")), reason: "invalid raw record")
        }
    }

    func testPARNUMSTAT04_InvalidStatusFails() {
        for status in ["X", "U", "M100", "R101", "R1000", "R-1", "R+1", "m", "", "RR"] {
            assertCommitFails(
                data(raw(status, "a", "b") + renameNumstat("1", "0", from: "a", to: "b")),
                reason: "invalid status"
            )
        }
    }

    func testPARNUMSTAT04_RawRecordWithEmptyPathFails() {
        let input = data(raw("M", "") + numstat("1", "0", "x"))
        assertCommitFails(input, reason: "empty path", offset: raw("M", "").utf8.count - 1)
    }

    func testPARNUMSTAT04_NumbersAreUnsignedDecimalOnly() {
        let bad = ["+1", "-1", " 1", "1 ", "0x1", "1a", "", "١", "99999999999999999999"]
        for value in bad {
            assertCommitFails(data(raw("M", "a") + numstat(value, "0", "a")), reason: "invalid added count")
            assertStashFails(data(numstat("0", value, "a")), reason: "invalid deleted count")
        }
    }

    func testPARNUMSTAT04_NumstatWithoutTabsFails() {
        assertStashFails(data("1 0 a\u{0}"), reason: "invalid added count")
        assertStashFails(data("1\t0\u{0}"), reason: "invalid deleted count")
    }

    func testPARNUMSTAT04_ParseErrorReportsByteOffset() {
        let prefix = raw("M", "a") + raw("M", "b") + numstat("1", "0", "a")
        let input = data(prefix + "1\tx\tb\u{0}")
        assertCommitFails(input, reason: "invalid deleted count", offset: prefix.utf8.count)
    }

    // MARK: - PAR-NUMSTAT-05 stash untracked part

    func testPARNUMSTAT05_StashMarksFilesFromTheUntrackedPart() throws {
        let untracked = try NumstatParser.parseCommitFiles(Fixtures.stashUntrackedPart)
        XCTAssertEqual(paths(untracked.files), ["stash-untracked.txt", "ud/untracked.bin"])
        let result = try NumstatParser.parseStashFiles(
            Fixtures.stash,
            untrackedPaths: Set(untracked.files.map(\.path))
        )
        XCTAssertFalse(result.isPartial)
        XCTAssertEqual(
            result.files,
            [
                FileStat(
                    path: GitPath("docs/handbook.md"),
                    originalPath: GitPath("docs/manual.md"),
                    added: 1,
                    deleted: 0
                ),
                FileStat(path: GitPath("keep.txt"), added: 1, deleted: 0),
                FileStat(path: GitPath("stash-untracked.txt"), added: 1, deleted: 0, isFromUntracked: true),
                FileStat(path: GitPath("ud/untracked.bin"), added: nil, deleted: nil, isFromUntracked: true),
            ]
        )
    }

    func testPARNUMSTAT05_WithoutUntrackedPathsNothingIsMarked() throws {
        let files = try NumstatParser.parseStashFiles(Fixtures.stash).files
        XCTAssertEqual(paths(files), ["docs/handbook.md", "keep.txt", "stash-untracked.txt", "ud/untracked.bin"])
        XCTAssertFalse(files.contains { $0.isFromUntracked })
        XCTAssertTrue(files.allSatisfy { $0.status == nil })
    }

    func testPARNUMSTAT05_UntrackedMatchIsByRawBytes() throws {
        let nfc = "\u{00E9}.txt"
        let nfd = "e\u{0301}.txt"
        let input = data(numstat("1", "0", nfc) + numstat("1", "0", nfd))
        let files = try NumstatParser.parseStashFiles(input, untrackedPaths: [GitPath(nfd)]).files
        XCTAssertEqual(files.map(\.isFromUntracked), [false, true])
    }

    func testPARNUMSTAT05_StashOutputWithRawRecordFails() {
        assertStashFails(data(raw("M", "a") + numstat("1", "0", "a")), reason: "invalid added count", offset: 0)
    }

    // MARK: - Truncated output

    func testTruncatedNumstatDropsOnlyTheIncompleteRecord() throws {
        let complete = Fixtures.addModifyDelete
        // Cut inside the last numstat record (`0␉1␉old.txt␀`).
        let cut = complete.prefix(complete.count - 4)
        let result = try NumstatParser.parseCommitFiles(Data(cut), truncated: true)
        XCTAssertTrue(result.isPartial)
        XCTAssertEqual(paths(result.files), ["keep.txt", "new file.txt"])
    }

    func testTruncatedAfterACompleteRecordKeepsIt() throws {
        let input = data(raw("M", "a") + raw("M", "b") + numstat("1", "0", "a"))
        let result = try NumstatParser.parseCommitFiles(input, truncated: true)
        XCTAssertTrue(result.isPartial)
        XCTAssertEqual(result.files, [FileStat(path: GitPath("a"), status: .modified, added: 1, deleted: 0)])
    }

    func testTruncatedInsideRenameRecordsDropsThem() throws {
        let prefix = raw("M", "a") + raw("R100", "b", "c") + numstat("1", "0", "a")
        let cutRaw = data(raw("M", "a") + ":100644 100644 \(blobA) \(blobB) R100\u{0}b\u{0}")
        XCTAssertEqual(try NumstatParser.parseCommitFiles(cutRaw, truncated: true).files, [])
        let cutNumstat = data(prefix + "0\t0\t\u{0}b\u{0}")
        XCTAssertEqual(paths(try NumstatParser.parseCommitFiles(cutNumstat, truncated: true).files), ["a"])
        let cutStash = data(numstat("1", "0", "a") + "0\t0\t\u{0}b\u{0}c")
        XCTAssertEqual(paths(try NumstatParser.parseStashFiles(cutStash, truncated: true).files), ["a"])
    }

    func testTruncatedInsideRawSectionKeepsNoFiles() throws {
        let complete = Fixtures.addModifyDelete
        let firstNumstat = try XCTUnwrap(complete.firstRange(of: data("2\t1\tkeep.txt")))
        let cut = complete[..<(firstNumstat.lowerBound - 10)]
        let result = try NumstatParser.parseCommitFiles(Data(cut), truncated: true)
        XCTAssertEqual(result, NumstatParser.Files(files: [], isPartial: true))
    }

    func testTruncatedStashKeepsCompleteRecords() throws {
        let cut = Fixtures.stash.prefix(Fixtures.stash.count - 3)
        let result = try NumstatParser.parseStashFiles(Data(cut), truncated: true)
        XCTAssertTrue(result.isPartial)
        XCTAssertEqual(paths(result.files), ["docs/handbook.md", "keep.txt", "stash-untracked.txt"])
    }

    func testTruncatedOutputStillRejectsMalformedCompleteRecords() {
        let input = data(raw("M", "a") + numstat("x", "0", "a") + "1\t")
        XCTAssertThrowsError(try NumstatParser.parseCommitFiles(input, truncated: true))
    }

    func testUnterminatedOutputFailsWhenNotTruncated() {
        let input = Fixtures.addModifyDelete.dropLast()
        assertCommitFails(Data(input), reason: "incomplete record", offset: input.count)
        assertStashFails(Data(Fixtures.stash.dropLast()), reason: "incomplete record")
        assertCommitFails(data(raw("R100", "a")), reason: "incomplete record")
        assertStashFails(data("0\t0\t\u{0}a\u{0}"), reason: "incomplete record")
    }
}
