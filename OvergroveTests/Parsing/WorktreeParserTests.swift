import Foundation
import XCTest

@testable import Overgrove

/// PAR-WT-01…09 (parsing-spec.md §2). PAR-WT-07 also covers SEC-T15-03 (truncated parser input).
///
/// Inputs mirror real `git worktree list --porcelain -z` output from Apple Git 2.54.0; only the paths are replaced.
final class WorktreeParserTests: XCTestCase {
    private let oid = "31e6c18e7585628677852541d23e59f2314fbeca"
    private let zeroOID = String(repeating: "0", count: 40)

    /// Joins attribute tokens with NUL and ends each record with an empty token, exactly as git does.
    private func output(_ records: [[String]]) -> Data {
        Data(records.map { $0.map { $0 + "\u{0}" }.joined() + "\u{0}" }.joined().utf8)
    }

    private func parse(_ records: [[String]], truncated: Bool = false) throws -> WorktreeParser.Listing {
        try WorktreeParser.parse(output(records), truncated: truncated)
    }

    private func assertFails(
        _ data: Data, reason: String, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try WorktreeParser.parse(data), message, file: file, line: line) { error in
            let parseError = error as? ParseError
            XCTAssertEqual(parseError?.parser, "WorktreeParser", file: file, line: line)
            XCTAssertEqual(parseError?.reason, reason, file: file, line: line)
        }
    }

    func testPARWT01_MainAndTwoLinkedWorktrees() throws {
        let listing = try parse([
            ["worktree /tmp/dev/repo", "HEAD \(oid)", "branch refs/heads/main"],
            ["worktree /tmp/dev/wt-ahead", "HEAD \(oid)", "branch refs/heads/feat/ahead"],
            ["worktree /tmp/dev/wt-behind", "HEAD \(oid)", "branch refs/heads/feat/behind"],
        ])
        XCTAssertFalse(listing.isPartial)
        XCTAssertEqual(
            listing.worktrees.map(\.path.display), ["/tmp/dev/repo", "/tmp/dev/wt-ahead", "/tmp/dev/wt-behind"])
        XCTAssertEqual(listing.worktrees.map(\.isMain), [true, false, false])
        XCTAssertEqual(listing.worktrees.map(\.branchShortName), ["main", "feat/ahead", "feat/behind"])
        let main = listing.worktrees[0]
        XCTAssertEqual(main.head, ObjectID(oid))
        XCTAssertEqual(main.branch, "refs/heads/main")
        XCTAssertFalse(main.isDetached)
        XCTAssertFalse(main.isBare)
        XCTAssertEqual(main.lock, .unlocked)
        XCTAssertFalse(main.isPrunable)
        XCTAssertNil(main.prunableReason)
    }

    func testPARWT02_Detached() throws {
        let worktree = try XCTUnwrap(
            try parse([
                ["worktree /tmp/dev/repo", "HEAD \(oid)", "branch refs/heads/main"],
                ["worktree /tmp/dev/wt-detached", "HEAD \(oid)", "detached"],
            ]).worktrees.last
        )
        XCTAssertTrue(worktree.isDetached)
        XCTAssertNil(worktree.branch)
        XCTAssertEqual(worktree.head, ObjectID(oid))
    }

    func testPARWT02_BranchAndDetachedTogetherFails() {
        assertFails(
            output([["worktree /tmp/dev/repo", "HEAD \(oid)", "branch refs/heads/main", "detached"]]),
            reason: "both branch and detached"
        )
    }

    func testPARWT03_LockedWithAndWithoutReason() throws {
        let worktrees = try parse([
            ["worktree /tmp/dev/repo", "HEAD \(oid)", "branch refs/heads/main"],
            ["worktree /tmp/dev/wt-lock", "HEAD \(oid)", "branch refs/heads/lk", "locked"],
            [
                "worktree /tmp/dev/wt-locked", "HEAD \(oid)", "branch refs/heads/chore/locked",
                "locked fixture: locked on purpose",
            ],
            ["worktree /tmp/dev/wt-lock2", "HEAD \(oid)", "branch refs/heads/lk2", "locked multi\nline"],
        ]).worktrees
        XCTAssertEqual(
            worktrees.map(\.lock),
            [
                .unlocked, .locked(reason: nil), .locked(reason: "fixture: locked on purpose"),
                .locked(reason: "multi\nline"),
            ]
        )
        XCTAssertEqual(worktrees.map(\.isLocked), [false, true, true, true])
    }

    /// The parser keeps lock reasons byte-for-byte; neutralizing control and bidi characters is the display layer's
    /// job. The test pins that nothing is stripped or reordered here.
    func testPARWT03_LockReasonWithControlAndBidiCharactersIsKeptVerbatim() throws {
        let reason = "evil\u{1B}[31m\t\u{07}\u{202E}txt.exe\u{2066}x\u{2069}\u{200F}"
        let worktree = try XCTUnwrap(
            try parse([
                ["worktree /tmp/dev/repo", "HEAD \(oid)", "branch refs/heads/main"],
                ["worktree /tmp/dev/wt", "HEAD \(oid)", "detached", "locked \(reason)"],
            ]).worktrees.last
        )
        XCTAssertEqual(worktree.lock, .locked(reason: reason))
    }

    func testPARWT03_LockedWithEmptyReasonHasNoReason() throws {
        let worktree = try XCTUnwrap(
            try parse([["worktree /tmp/dev/repo", "HEAD \(oid)", "detached", "locked "]]).worktrees.first
        )
        XCTAssertEqual(worktree.lock, .locked(reason: nil), "`locked ` with an empty reason is the same as `locked`")
    }

    func testPARWT04_PrunableWithReason() throws {
        let worktrees = try parse([
            ["worktree /tmp/dev/repo", "HEAD \(oid)", "branch refs/heads/main"],
            [
                "worktree /tmp/dev/wt-prunable", "HEAD \(oid)", "branch refs/heads/spike/prunable",
                "prunable gitdir file points to non-existent location",
            ],
            ["worktree /tmp/dev/wt-bare-prune", "HEAD \(oid)", "branch refs/heads/x", "prunable"],
        ]).worktrees
        XCTAssertEqual(worktrees.map(\.isPrunable), [false, true, true])
        XCTAssertEqual(worktrees.map(\.prunableReason), [nil, "gitdir file points to non-existent location", nil])
    }

    func testPARWT05_BareMainRepository() throws {
        let worktrees = try parse([
            ["worktree /tmp/dev/repo.git", "bare"],
            ["worktree /tmp/dev/wt", "HEAD \(oid)", "branch refs/heads/main"],
        ]).worktrees
        let main = worktrees[0]
        XCTAssertTrue(main.isMain)
        XCTAssertTrue(main.isBare)
        XCTAssertNil(main.head, "a bare main repository has no HEAD attribute")
        XCTAssertNil(main.branch)
        XCTAssertFalse(main.isDetached)
        XCTAssertFalse(worktrees[1].isBare)
        XCTAssertFalse(worktrees[1].isMain)
    }

    func testPARWT05_BareLinkedWorktreeFails() {
        assertFails(
            output([["worktree /tmp/dev/repo.git", "bare"], ["worktree /tmp/dev/wt", "bare"]]),
            reason: "bare linked worktree"
        )
    }

    func testPARWT05_BareWithCheckoutAttributesFails() {
        let reason = "bare with HEAD, branch, or detached"
        let path = "worktree /tmp/dev/repo.git"
        assertFails(output([[path, "bare", "HEAD \(oid)"]]), reason: reason)
        assertFails(output([[path, "bare", "HEAD \(zeroOID)"]]), reason: reason)
        assertFails(output([[path, "bare", "branch refs/heads/main"]]), reason: reason)
        assertFails(output([[path, "bare", "detached"]]), reason: reason)
    }

    func testPARWT06_PathsWithSpaceNewlineNFDAndEmoji() throws {
        let nfd = "/tmp/dev/cafe\u{0301}"
        let nfc = "/tmp/dev/caf\u{00E9}"
        let paths = ["/tmp/dev/my repo", "/tmp/dev/line\nbreak", nfd, nfc, "/tmp/dev/🌳 grove", "/tmp/dev/-dash"]
        let listing = try parse(paths.map { ["worktree \($0)", "HEAD \(oid)", "detached"] })
        XCTAssertEqual(listing.worktrees.map(\.path.display), paths)
        XCTAssertEqual(
            listing.worktrees.map(\.path.raw), paths.map { Data($0.utf8) }, "bytes are kept as git printed them")
        XCTAssertNotEqual(listing.worktrees[2].path, listing.worktrees[3].path, "NFD and NFC are different paths")
        XCTAssertTrue(listing.worktrees.allSatisfy(\.path.isRepresentable))
    }

    func testPARWT06_InvalidUTF8PathIsKeptButNotRepresentable() throws {
        var data = Data("worktree /tmp/dev/bad".utf8)
        data.append(contentsOf: [0xFF, 0xFE])
        data.append(Data("\u{0}HEAD \(oid)\u{0}detached\u{0}\u{0}".utf8))
        let path = try XCTUnwrap(try WorktreeParser.parse(data).worktrees.first?.path)
        XCTAssertFalse(path.isRepresentable)
        XCTAssertEqual(path.raw, Data("/tmp/dev/bad".utf8) + Data([0xFF, 0xFE]))
        XCTAssertNil(path.argument)
    }

    /// PAR-WT-07 / SEC-T15-03: output cut at the size limit drops the incomplete last record.
    func testPARWT07_TruncatedOutputDropsLastRecord() throws {
        var data = output([
            ["worktree /tmp/dev/repo", "HEAD \(oid)", "branch refs/heads/main"],
            ["worktree /tmp/dev/wt-a", "HEAD \(oid)", "branch refs/heads/a"],
        ])
        data.append(Data("worktree /tmp/dev/wt-b\u{0}HEAD 31e6c1".utf8))
        let listing = try WorktreeParser.parse(data, truncated: true)
        XCTAssertTrue(listing.isPartial)
        XCTAssertEqual(listing.worktrees.map(\.path.display), ["/tmp/dev/repo", "/tmp/dev/wt-a"])
        XCTAssertTrue(listing.worktrees[0].isMain)
    }

    func testPARWT07_TruncatedOutputDropsLastRecordEvenIfTerminated() throws {
        let listing = try parse(
            [
                ["worktree /tmp/dev/repo", "HEAD \(oid)", "branch refs/heads/main"],
                ["worktree /tmp/dev/wt-a", "HEAD \(oid)", "branch refs/heads/a"],
            ],
            truncated: true
        )
        XCTAssertTrue(listing.isPartial)
        XCTAssertEqual(listing.worktrees.map(\.path.display), ["/tmp/dev/repo"])
    }

    func testPARWT07_UnterminatedRecordWithoutTruncationFails() {
        assertFails(Data("worktree /tmp/dev/repo\u{0}HEAD \(oid)\u{0}".utf8), reason: "unterminated record")
    }

    func testPARWT08_UnknownAttributesAreIgnored() throws {
        let worktree = try XCTUnwrap(
            try parse([
                [
                    "worktree /tmp/dev/repo", "HEAD \(oid)", "future-attr some value", "branch refs/heads/main",
                    "lockedish", "x",
                ]
            ]).worktrees.first
        )
        XCTAssertEqual(worktree.branch, "refs/heads/main")
        XCTAssertEqual(worktree.lock, .unlocked, "`lockedish` is not `locked`")
    }

    func testPARWT09_UnbornBranchHasZeroOIDAndNoHead() throws {
        let worktrees = try parse([
            ["worktree /tmp/dev/repo", "HEAD \(oid)", "branch refs/heads/main"],
            ["worktree /tmp/dev/wt-unborn", "HEAD \(zeroOID)", "branch refs/heads/newbr"],
        ]).worktrees
        XCTAssertNil(worktrees[1].head)
        XCTAssertEqual(worktrees[1].branch, "refs/heads/newbr")
        XCTAssertFalse(worktrees[1].isDetached)
    }

    func testPARWT09_ZeroSHA256OIDIsUnborn() throws {
        let zero256 = String(repeating: "0", count: 64)
        let worktree = try XCTUnwrap(
            try parse([["worktree /tmp/dev/repo", "HEAD \(zero256)", "branch refs/heads/main"]]).worktrees.first
        )
        XCTAssertNil(worktree.head)
    }

    /// Confirms the unborn format against the installed git instead of assuming it (security-review.md §8).
    func testPARWT09_RealGitUnbornWorktrees() async throws {
        let repository = try await GitTestRepository.make()
        defer { repository.remove() }
        if repository.environment.version >= GitVersion(major: 2, minor: 42, patch: 0) {
            try await repository.git(["worktree", "add", "-q", "--orphan", "-b", "newbr", "wt-unborn"])
        } else {
            // `worktree add --orphan` arrived in git 2.42 (#99). The same state by hand: a worktree on a commit kept
            // outside any branch the main repository has, then its HEAD pointed at a branch that does not exist.
            let tree = try await repository.git(["mktree"])
            let treeID = String(decoding: tree.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let commit = try await repository.git(["commit-tree", "-m", "seed", treeID])
            let commitID = String(decoding: commit.stdout, as: UTF8.self).trimmingCharacters(
                in: .whitespacesAndNewlines)
            try await repository.git(["worktree", "add", "-q", "--detach", "wt-unborn", commitID])
            try await repository.git(["-C", "wt-unborn", "symbolic-ref", "HEAD", "refs/heads/newbr"])
        }
        let result = try await repository.git(["worktree", "list", "--porcelain", "-z"])
        let worktrees = try WorktreeParser.parse(result.stdout).worktrees
        XCTAssertEqual(worktrees.count, 2)
        XCTAssertEqual(worktrees.map(\.isMain), [true, false])
        XCTAssertEqual(worktrees.map(\.head), [nil, nil], "both the empty main repository and the orphan are unborn")
        XCTAssertEqual(worktrees.map(\.branch), ["refs/heads/main", "refs/heads/newbr"])
        XCTAssertEqual(worktrees[1].path.display.hasSuffix("/wt-unborn"), true)
    }

    func testEmptyOutputIsAnEmptyListing() throws {
        let listing = try WorktreeParser.parse(Data())
        XCTAssertEqual(listing.worktrees, [])
        XCTAssertFalse(listing.isPartial)
    }

    func testMalformedRecordsFailWholeParse() {
        assertFails(output([["HEAD \(oid)", "branch refs/heads/main"]]), reason: "record does not start with worktree")
        assertFails(output([["worktree ", "HEAD \(oid)"]]), reason: "empty worktree path")
        assertFails(output([["worktree /tmp/dev/repo", "HEAD 31e6c18"]]), reason: "invalid HEAD object ID")
        assertFails(output([["worktree /tmp/dev/repo", "HEAD \(oid.uppercased())"]]), reason: "invalid HEAD object ID")
        assertFails(output([["worktree /tmp/dev/repo", "branch "]]), reason: "empty branch")
        assertFails(Data("\u{0}".utf8), reason: "empty record")
        assertFails(
            output([["worktree /tmp/dev/repo", "HEAD \(oid)", "worktree /tmp/dev/other"]]),
            reason: "duplicate worktree attribute"
        )
    }

    func testInvalidUTF8BranchFails() {
        var data = Data("worktree /tmp/dev/repo\u{0}HEAD \(oid)\u{0}branch refs/heads/bad".utf8)
        data.append(contentsOf: [0xFF, 0xFE])
        data.append(Data("\u{0}\u{0}".utf8))
        assertFails(data, reason: "invalid UTF-8 branch")
    }

    func testRelativeWorktreePathFails() {
        assertFails(output([["worktree dev/repo", "HEAD \(oid)", "detached"]]), reason: "relative worktree path")
        assertFails(output([["worktree -dash", "HEAD \(oid)", "detached"]]), reason: "relative worktree path")
        assertFails(output([["worktree  /tmp/dev/repo", "HEAD \(oid)", "detached"]]), reason: "relative worktree path")
    }

    func testDuplicateSingleValuedAttributesFail() {
        let path = "worktree /tmp/dev/repo"
        assertFails(output([[path, "HEAD \(oid)", "HEAD \(oid)", "detached"]]), reason: "duplicate HEAD attribute")
        assertFails(
            output([[path, "HEAD \(zeroOID)", "HEAD \(oid)", "branch refs/heads/main"]]),
            reason: "duplicate HEAD attribute",
            "an unborn HEAD still counts as present"
        )
        assertFails(
            output([[path, "HEAD \(oid)", "branch refs/heads/main", "branch refs/heads/other"]]),
            reason: "duplicate branch attribute"
        )
        assertFails(output([[path, "HEAD \(oid)", "detached", "detached"]]), reason: "duplicate detached attribute")
        assertFails(output([[path, "bare", "bare"]]), reason: "duplicate bare attribute")
    }

    func testParseErrorOffsetPointsAtFailingToken() {
        let data = output([["worktree /tmp/dev/repo", "HEAD \(oid)"], ["worktree /tmp/dev/wt", "HEAD bad"]])
        let expected = data.count - "HEAD bad\u{0}\u{0}".utf8.count
        XCTAssertThrowsError(try WorktreeParser.parse(data)) {
            XCTAssertEqual(($0 as? ParseError)?.offset, expected)
        }
    }

    func testParsesDataSlicesWithNonZeroStartIndex() throws {
        let full = Data("xx".utf8) + output([["worktree /tmp/dev/repo", "HEAD \(oid)", "branch refs/heads/main"]])
        let listing = try WorktreeParser.parse(full.dropFirst(2))
        XCTAssertEqual(listing.worktrees.first?.path.raw, Data("/tmp/dev/repo".utf8))
        XCTAssertEqual(listing.worktrees.first?.path.raw.startIndex, 0)
    }
}
