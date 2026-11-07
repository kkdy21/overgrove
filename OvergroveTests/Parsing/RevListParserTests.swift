import Foundation
import XCTest

@testable import Overgrove

/// PAR-REVLIST-01…02 (parsing-spec.md §7).
final class RevListParserTests: XCTestCase {
    /// Real `rev-list --left-right --count --end-of-options refs/remotes/origin/both...refs/heads/both` output
    /// (Apple Git 2.54.0): the upstream is 2 commits ahead of the branch, the branch 1 ahead of the upstream.
    private static let realOutput = Data(base64Encoded: "MgkxCg==") ?? Data()

    private func assertFails(
        _ text: String, offset: Int? = nil, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try RevListParser.parse(Data(text.utf8)), file: file, line: line) { error in
            let parseError = error as? ParseError
            XCTAssertEqual(parseError?.parser, "RevListParser", file: file, line: line)
            if let offset { XCTAssertEqual(parseError?.offset, offset, file: file, line: line) }
        }
    }

    func testPARREVLIST01_LeftIsBehindRightIsAhead() throws {
        XCTAssertEqual(try RevListParser.parse(Self.realOutput), RevListParser.Counts(behind: 2, ahead: 1))
        XCTAssertEqual(try RevListParser.parse(Data("0\t0\n".utf8)), RevListParser.Counts(behind: 0, ahead: 0))
        XCTAssertEqual(
            try RevListParser.parse(Data("123456\t7\n".utf8)), RevListParser.Counts(behind: 123_456, ahead: 7))
    }

    func testPARREVLIST02_MalformedOutputFails() {
        assertFails("", offset: 0)
        assertFails("2\t1", offset: 3)
        assertFails("2 1\n", offset: 0)
        assertFails("2\t\n", offset: 2)
        assertFails("\t1\n", offset: 0)
        assertFails("-1\t1\n", offset: 0)
        assertFails("+1\t1\n", offset: 0)
        assertFails("1\t-1\n", offset: 2)
        assertFails("a\t1\n", offset: 0)
        assertFails("2\t1\t3\n", offset: 2)
        assertFails("2\t1\n3\t4\n", offset: 4)
        assertFails("2\t1\n\n", offset: 4)
        assertFails("2\t1\r\n", offset: 2)
        assertFails("99999999999999999999\t1\n", offset: 0)
        assertFails("١\t1\n", offset: 0)
    }
}
