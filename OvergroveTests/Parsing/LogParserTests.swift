import Foundation
import XCTest

@testable import Overgrove

/// PAR-LOG-01…08 (parsing-spec.md §5).
final class LogParserTests: XCTestCase {
    private typealias Fixtures = LogParserFixtures

    private func data(_ text: String) -> Data { Data(text.utf8) }

    private func oid(_ hex: String) throws -> ObjectID { try XCTUnwrap(ObjectID(hex)) }

    private let sha1A = String(repeating: "a", count: 40)
    private let sha1B = String(repeating: "b", count: 40)

    /// One graph record in the `%H␀%P␀%an␀%ae␀%at␀%s␀<co-authors>␀` layout.
    private func record(
        _ oid: String,
        parents: String = "",
        time: String = "1793853652",
        subject: String = "s",
        coAuthors: String = ""
    ) -> String {
        "\(oid)\u{0}\(parents)\u{0}t\u{0}t@example.com\u{0}\(time)\u{0}\(subject)\u{0}\(coAuthors)\u{0}"
    }

    private func assertParseFails(
        _ input: Data,
        reason: String,
        detail: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try {
                if detail { _ = try LogParser.parseCommitMeta(input) } else { _ = try LogParser.parseGraph(input) }
            }(),
            file: file,
            line: line
        ) { error in
            let parseError = error as? ParseError
            XCTAssertEqual(parseError?.parser, "LogParser", file: file, line: line)
            XCTAssertEqual(parseError?.reason, reason, file: file, line: line)
        }
    }

    // MARK: - Graph (§5.1)

    func testRealSHA1GraphParsesEveryCommitInOrder() throws {
        let page = try LogParser.parseGraph(Fixtures.sha1Graph)
        XCTAssertEqual(
            page.commits.map(\.subject),
            ["feat: subject line", "", "한글 제목 🌳 émoji", "octopus", "c", "Merge branch 'other'", "b", "a", "root"]
        )
        XCTAssertFalse(page.isPartial)
        let first = try XCTUnwrap(page.commits.first)
        XCTAssertEqual(first.oid, try oid("0d297be800a5b49ab9f4cc51e516b71cd0a56504"))
        XCTAssertEqual(first.parents, [try oid("6cb56e94eff0d50311dc91faea509a6d7f2850a9")])
        XCTAssertEqual(first.authorName, "t")
        XCTAssertEqual(first.authorEmail, "t@example.com")
        XCTAssertEqual(first.authorDate, Date(timeIntervalSince1970: 1_793_853_652))
    }

    func testPARLOG01_RootCommitHasNoParents() throws {
        let root = try XCTUnwrap(try LogParser.parseGraph(Fixtures.sha1Graph).commits.last)
        XCTAssertEqual(root.subject, "root")
        XCTAssertEqual(root.parents, [])
        XCTAssertFalse(root.isMerge)
    }

    func testPARLOG02_MergeAndOctopusParents() throws {
        let commits = try LogParser.parseGraph(Fixtures.sha1Graph).commits
        let merge = try XCTUnwrap(commits.first { $0.subject == "Merge branch 'other'" })
        XCTAssertEqual(
            merge.parents,
            [
                try oid("019766a43abf723bb0910840a01942d8b05f2c90"),
                try oid("3f46d12112c47fa1be333a789f80b6b0d2bd85e3"),
            ]
        )
        XCTAssertTrue(merge.isMerge)
        let octopus = try XCTUnwrap(commits.first { $0.subject == "octopus" })
        XCTAssertEqual(
            octopus.parents,
            [
                try oid("fd6753ad2c2de137667e45b521d2de9e2c9f3658"),
                try oid("3f46d12112c47fa1be333a789f80b6b0d2bd85e3"),
                try oid("f7cb0839959621c6f17e2730e005f0a2080ce486"),
            ],
            "parent order is preserved: the first parent drives the graph lane"
        )
        XCTAssertEqual(octopus.parents.first, merge.oid)
    }

    func testPARLOG03_UnicodeEmojiAndEmptySubject() throws {
        let commits = try LogParser.parseGraph(Fixtures.sha1Graph).commits
        let unicode = commits[2]
        XCTAssertEqual(unicode.subject, "한글 제목 🌳 émoji")
        XCTAssertEqual(unicode.authorName, "김개발")
        XCTAssertEqual(unicode.authorEmail, "dev@example.com")
        XCTAssertEqual(unicode.authorDate, Date(timeIntervalSince1970: 1_793_853_700))
        XCTAssertEqual(commits[1].subject, "", "an empty subject is an empty field, not a missing one")
    }

    func testPARLOG03_InvalidUTF8IsDecodedLossily() throws {
        var input = Data(record(sha1A).dropLast(3).utf8)  // drop "s␀␀"
        input.append(contentsOf: [0x66, 0xFF, 0x00, 0x00])
        XCTAssertEqual(try LogParser.parseGraph(input).commits.first?.subject, "f\u{FFFD}")
    }

    func testPARLOG04_SHA256Repository() throws {
        let commits = try LogParser.parseGraph(Fixtures.sha256Graph).commits
        XCTAssertEqual(commits.count, 9)
        XCTAssertTrue(commits.allSatisfy { $0.oid.isSHA256 && $0.parents.allSatisfy(\.isSHA256) })
        XCTAssertEqual(
            commits.first?.oid,
            try oid("3eab2eee7dae76bb8afc118ef9ea07848b28702f3b56931c2d059e68da639688")
        )
        XCTAssertEqual(commits.first { $0.subject == "octopus" }?.parents.count, 3)
        XCTAssertEqual(commits.last?.parents, [])
    }

    func testPARLOG06_InvalidOIDFails() {
        assertParseFails(data(record("XYZ")), reason: "invalid commit OID")
        assertParseFails(data(record(String(repeating: "A", count: 40))), reason: "invalid commit OID")
        assertParseFails(data(record(sha1A, parents: "abc1234")), reason: "invalid parent OID")
        assertParseFails(data(record(sha1A, parents: "\(sha1B)  \(sha1B)")), reason: "invalid parent OID")
        assertParseFails(data(record(sha1A, parents: " \(sha1B)")), reason: "invalid parent OID")
    }

    func testPARLOG06_InvalidOIDReportsTheFieldOffset() {
        let input = data(record(sha1A) + record("bad"))
        XCTAssertThrowsError(try LogParser.parseGraph(input)) {
            XCTAssertEqual(($0 as? ParseError)?.offset, record(sha1A).utf8.count)
        }
    }

    func testMalformedTimestampFails() {
        for bad in ["", "+1", "-1", "1.5", "１２", "12a", "99999999999999999999999"] {
            assertParseFails(data(record(sha1A, time: bad)), reason: "invalid author time")
        }
    }

    func testFieldCountMismatchFails() {
        assertParseFails(data(record(sha1A) + "\(sha1B)\u{0}\u{0}"), reason: "incomplete record")
        assertParseFails(data(String(record(sha1A).dropLast())), reason: "incomplete record")
    }

    func testEmptyOutputIsAnEmptyLog() throws {
        let page = try LogParser.parseGraph(Data())
        XCTAssertEqual(page.commits, [])
        XCTAssertFalse(page.isPartial)
    }

    func testPARLOG07_TruncatedOutputDropsTheLastRecord() throws {
        let full = Fixtures.sha1Graph
        // Cut inside the root record's subject ("ro|ot"): the root commit must not appear with a cut subject.
        let cut = try LogParser.parseGraph(full.prefix(full.count - 3), truncated: true)
        XCTAssertEqual(cut.commits.count, 8)
        XCTAssertEqual(cut.commits.last?.subject, "a")
        XCTAssertTrue(cut.isPartial)

        // Cut inside an OID: the partial OID would fail validation if it were not dropped.
        let midOID = try LogParser.parseGraph(data(record(sha1A) + String(sha1B.prefix(10))), truncated: true)
        XCTAssertEqual(midOID.commits.map(\.oid), [try oid(sha1A)])

        // Cut right before the last field's terminator: the co-author list may be cut, so drop the record.
        let noTerminator = try LogParser.parseGraph(data(String(record(sha1A).dropLast())), truncated: true)
        XCTAssertEqual(noTerminator.commits, [])
        XCTAssertTrue(noTerminator.isPartial)
    }

    func testPARLOG07_TruncatedFlagWithOnlyCompleteRecordsKeepsThem() throws {
        let page = try LogParser.parseGraph(Fixtures.sha1Graph, truncated: true)
        XCTAssertEqual(page.commits.count, 9, "the final NUL proves the last record is complete")
        XCTAssertTrue(page.isPartial)
    }

    func testPARLOG08_NULInMessageDoesNotShiftFields() throws {
        let commits = try LogParser.parseGraph(Fixtures.nulMessageGraph).commits
        XCTAssertEqual(commits.count, 1)
        XCTAssertEqual(commits.first?.subject, "before", "git cuts the message at the NUL")
        XCTAssertEqual(commits.first?.oid, try oid("efd1998cadd78ecf586b19d24b2b3d7ee650acb3"))
    }

    // MARK: - Co-author trailers (§5.1, PAR-LOG-09)

    func testPARLOG09_RealCoAuthorTrailers() throws {
        let commits = try LogParser.parseGraph(Fixtures.coAuthorGraph).commits
        XCTAssertEqual(commits.map(\.subject), ["mid-text mention", "folded", "human and AI", "plain"])
        XCTAssertEqual(commits[0].coAuthors, [], "a Co-authored-by line inside a paragraph is not a trailer")
        XCTAssertEqual(commits[1].coAuthors, ["Bob Continued <bob@example.com>"], "folded lines are unfolded")
        XCTAssertEqual(
            commits[2].coAuthors,
            ["Claude Opus 5.5 <noreply@anthropic.com>", "Alice <alice@example.com>"],
            "keys match case-insensitively, in message order; Signed-off-by is not a co-author"
        )
        XCTAssertEqual(commits[3].coAuthors, [])
        XCTAssertEqual(commits.map(AIAgentRule.builtIn.isAIAssisted), [false, false, true, false])
    }

    func testPARLOG09_CoAuthorFieldEdgeCases() throws {
        let unitSeparator = "\u{1F}"
        let input = data(
            record(sha1A, coAuthors: "A <a@x>\(unitSeparator)\(unitSeparator) \(unitSeparator)B <b@x>")
                + record(sha1B, coAuthors: "")
        )
        let commits = try LogParser.parseGraph(input).commits
        XCTAssertEqual(commits[0].coAuthors, ["A <a@x>", "B <b@x>"], "blank values are dropped")
        XCTAssertEqual(commits[1].coAuthors, [])

        var invalidUTF8 = Data(record(sha1A).dropLast(1).utf8)  // keep the co-author field open
        invalidUTF8.append(contentsOf: [0x41, 0xFF, 0x20, 0x3C, 0x61, 0x40, 0x78, 0x3E, 0x00])  // "A\xFF <a@x>"
        XCTAssertEqual(
            try LogParser.parseGraph(invalidUTF8).commits.first?.coAuthors,
            ["A\u{FFFD} <a@x>"],
            "display only, so decoded leniently"
        )
    }

    func testOldSixFieldGraphOutputFails() {
        let sixFields = "\(sha1A)\u{0}\u{0}t\u{0}t@example.com\u{0}1793853652\u{0}s\u{0}"
        assertParseFails(data(sixFields), reason: "incomplete record")
    }

    // MARK: - Commit detail (§5.2)

    func testDetailParsesAllFields() throws {
        let meta = try LogParser.parseCommitMeta(Fixtures.sha1Detail)
        XCTAssertEqual(meta.oid, try oid("0d297be800a5b49ab9f4cc51e516b71cd0a56504"))
        XCTAssertEqual(meta.parents, [try oid("6cb56e94eff0d50311dc91faea509a6d7f2850a9")])
        XCTAssertEqual(meta.authorName, "t")
        XCTAssertEqual(meta.authorEmail, "t@example.com")
        XCTAssertEqual(meta.authorDate, Date(timeIntervalSince1970: 1_793_853_652))
        XCTAssertEqual(meta.committerName, "t")
        XCTAssertEqual(meta.committerEmail, "t@example.com")
        XCTAssertEqual(meta.committerDate, Date(timeIntervalSince1970: 1_793_853_652))
        XCTAssertFalse(meta.isPartial)
    }

    func testPARLOG05_MultiLineBodyKeepsTrailingNewline() throws {
        let meta = try LogParser.parseCommitMeta(Fixtures.sha1Detail)
        XCTAssertEqual(meta.message, "feat: subject line\n\nBody first line\n  indented\n\nRefs: #53\n")
    }

    func testDetailCombinesWithFilesIntoCommitDetail() throws {
        let meta = try LogParser.parseCommitMeta(Fixtures.sha1Detail)
        let detail = meta.detail(files: [], isPartial: false)
        XCTAssertEqual(detail.oid, meta.oid)
        XCTAssertEqual(detail.message, meta.message)
        XCTAssertEqual(detail.subject, "feat: subject line")
        XCTAssertEqual(detail.committerDate, meta.committerDate)
        XCTAssertTrue(meta.detail(files: [], isPartial: true).isPartial)
    }

    func testDetailOfRootCommitAndEmptyMessage() throws {
        let input = "\(sha1A)\u{0}\u{0}t\u{0}t@example.com\u{0}1\u{0}c\u{0}c@example.com\u{0}2\u{0}\u{0}"
        let meta = try LogParser.parseCommitMeta(data(input))
        XCTAssertEqual(meta.parents, [])
        XCTAssertEqual(meta.message, "")
        XCTAssertEqual(meta.committerName, "c")
        XCTAssertEqual(meta.committerDate, Date(timeIntervalSince1970: 2))
    }

    func testPARLOG08_DetailWithNULInMessage() throws {
        let meta = try LogParser.parseCommitMeta(Fixtures.nulMessageDetail)
        XCTAssertEqual(meta.message, "before")
    }

    func testPARLOG06_DetailInvalidFieldsFail() {
        let tail = "\u{0}t\u{0}t@example.com\u{0}1\u{0}t\u{0}t@example.com\u{0}1\u{0}m\u{0}"
        assertParseFails(data("nope\u{0}" + tail), reason: "invalid commit OID", detail: true)
        assertParseFails(data("\(sha1A)\u{0}zz" + tail), reason: "invalid parent OID", detail: true)
        let badCommitTime = "\(sha1A)\u{0}\u{0}t\u{0}t@example.com\u{0}1\u{0}t\u{0}t@example.com\u{0}x\u{0}m\u{0}"
        assertParseFails(data(badCommitTime), reason: "invalid committer time", detail: true)
    }

    func testDetailFieldCountMismatchFails() {
        assertParseFails(Data(), reason: "incomplete record", detail: true)
        assertParseFails(data("\(sha1A)\u{0}\u{0}t\u{0}"), reason: "incomplete record", detail: true)
        // A message never contains NUL (git cuts it there), so a 10th field means two records or a wrong format.
        let twoRecords = Fixtures.sha1Detail + Fixtures.sha1Detail
        assertParseFails(twoRecords, reason: "more than one record", detail: true)
    }

    func testPARLOG07_TruncatedDetailKeepsTheCutMessage() throws {
        let full = Fixtures.sha1Detail
        let meta = try LogParser.parseCommitMeta(full.prefix(full.count - 10), truncated: true)
        // The last 10 bytes are "efs: #53⏎␀".
        XCTAssertEqual(meta.message, "feat: subject line\n\nBody first line\n  indented\n\nR")
        XCTAssertTrue(meta.isPartial)
        XCTAssertThrowsError(try LogParser.parseCommitMeta(full.prefix(50), truncated: true)) {
            XCTAssertEqual(($0 as? ParseError)?.reason, "incomplete record")
        }
    }
}
