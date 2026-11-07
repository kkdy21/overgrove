import XCTest

@testable import Overgrove

/// `LogParser.parseFileHistory` (parsing-spec.md §5.3, #70).
final class FileHistoryParserTests: XCTestCase {
    private let path = GitPath("Status.swift")

    /// PAR-LOG-10: stats, a rename (old and new path), a binary file, and the path each commit had.
    func testPAR_LOG_10_FollowedHistory() throws {
        let page = try LogParser.parseFileHistory(LogParserFixtures.fileHistory, path: path)
        XCTAssertFalse(page.isPartial)
        XCTAssertEqual(
            page.entries.map(\.commit.subject),
            [
                "chore: make it binary", "main: capitalize d", "side: capitalize a", "refactor: rename to Status.swift",
                "feat: add c", "chore: bootstrap",
            ])
        XCTAssertEqual(
            page.entries.map(\.path.display),
            ["Status.swift", "Status.swift", "Status.swift", "Status.swift", "Parser.swift", "Parser.swift"])
        XCTAssertEqual(page.entries.map(\.originalPath?.display), [nil, nil, nil, "Parser.swift", nil, nil])
        XCTAssertEqual(page.entries.map(\.added), [nil, 1, 1, 1, 1, 2])
        XCTAssertEqual(page.entries.map(\.deleted), [nil, 1, 1, 0, 0, 0])
        XCTAssertTrue(page.entries.allSatisfy(\.hasStat))
        XCTAssertEqual(page.entries.last?.commit.parents, [])
    }

    /// A record without a stat (a merge) keeps the followed path and has unknown counts.
    func testRecordWithoutStatKeepsThePath() throws {
        let oid = String(repeating: "a", count: 40)
        let older = String(repeating: "b", count: 40)
        let data = Data(
            "\(oid)\0\(older) \(older)\0t\0t@example.com\01793853652\0Merge\0\0\(older)\0\0t\0t@example.com\01793853652\0add\0\0\n3\t0\told.txt\0"
                .utf8)
        let page = try LogParser.parseFileHistory(data, path: GitPath("old.txt"))
        XCTAssertEqual(page.entries.map(\.path.display), ["old.txt", "old.txt"])
        XCTAssertEqual(page.entries.map(\.hasStat), [false, true])
        XCTAssertNil(page.entries[0].added)
    }

    /// A later page starts from the path before the previous page's oldest commit.
    func testLaterPageStartsFromTheGivenPath() throws {
        let oid = String(repeating: "c", count: 40)
        let data = Data("\(oid)\0\0t\0t@example.com\01793853652\0root\0\0".utf8)
        let page = try LogParser.parseFileHistory(data, path: GitPath("Parser.swift"))
        XCTAssertEqual(page.entries.map(\.path.display), ["Parser.swift"])
        XCTAssertFalse(page.entries[0].hasStat)
    }

    /// PAR-LOG-11: a cut page drops its last record (its stat may be gone); complete output must end with NUL.
    func testPAR_LOG_11_TruncatedAndMalformed() throws {
        let full = LogParserFixtures.fileHistory
        for cut in [full.count - 1, full.count - 20, 250, 60] {
            let page = try LogParser.parseFileHistory(full.prefix(cut), path: path, truncated: true)
            XCTAssertTrue(page.isPartial)
            let complete = try LogParser.parseFileHistory(full, path: path).entries
            XCTAssertEqual(page.entries, Array(complete.prefix(page.entries.count)), "cut at \(cut)")
            XCTAssertLessThan(page.entries.count, complete.count)
        }
        XCTAssertThrowsError(try LogParser.parseFileHistory(full.dropLast(), path: path))
        XCTAssertEqual(try LogParser.parseFileHistory(Data(), path: path).entries, [])
        let oid = String(repeating: "a", count: 40)
        for bad in ["x\t0\tf", "1\t0", "1\t-1\tf", "99999999999999999999\t0\tf"] {
            let data = Data("\(oid)\0\0t\0t@example.com\01793853652\0s\0\0\n\(bad)\0".utf8)
            XCTAssertThrowsError(try LogParser.parseFileHistory(data, path: path), bad)
        }
        // A rename whose paths are missing.
        let rename = Data("\(oid)\0\0t\0t@example.com\01793853652\0s\0\0\n1\t0\t\0old\0".utf8)
        XCTAssertThrowsError(try LogParser.parseFileHistory(rename, path: path))
        XCTAssertEqual(try LogParser.parseFileHistory(rename, path: path, truncated: true).entries, [])
    }

    /// Paths are raw bytes: a non-UTF-8 name survives and is flagged as not representable.
    func testRawPathBytes() throws {
        let oid = String(repeating: "a", count: 40)
        var data = Data("\(oid)\0\0t\0t@example.com\01793853652\0s\0\0\n1\t0\t".utf8)
        data.append(contentsOf: [0x61, 0xFF, 0x00])
        let entry = try XCTUnwrap(try LogParser.parseFileHistory(data, path: path).entries.first)
        XCTAssertEqual(entry.path.raw, Data([0x61, 0xFF]))
        XCTAssertFalse(entry.path.isRepresentable)
    }
}
