import Foundation
import XCTest

@testable import Overgrove

/// `ProbeParser` for `rev-parse --path-format=absolute --show-toplevel --git-common-dir --is-bare-repository`
/// (parsing-spec.md §11.2).
final class ProbeParserTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testThreeLines() throws {
        let probe = try ProbeParser.parse(data("/tmp/dev/api\n/tmp/dev/api/.git\nfalse\n"))
        XCTAssertEqual(probe.topLevel.path, "/tmp/dev/api")
        XCTAssertEqual(probe.commonDirectory.path, "/tmp/dev/api/.git")
        XCTAssertFalse(probe.isBare)
    }

    func testLinkedWorktreePointsAtTheMainCommonDirectory() throws {
        let probe = try ProbeParser.parse(data("/tmp/dev/api-wt/42\n/tmp/dev/api/.git\nfalse\n"))
        XCTAssertEqual(probe.topLevel.path, "/tmp/dev/api-wt/42")
        XCTAssertEqual(probe.commonDirectory.path, "/tmp/dev/api/.git")
    }

    func testPathsWithSpacesAndUnicode() throws {
        let probe = try ProbeParser.parse(data("/tmp/dev/my repo 🌳\n/tmp/dev/my repo 🌳/.git\ntrue\n"))
        XCTAssertEqual(probe.topLevel.lastPathComponent, "my repo 🌳")
        XCTAssertTrue(probe.isBare)
    }

    func testMalformedOutputFails() {
        let cases: [(String, String)] = [
            ("/tmp/a\n/tmp/a/.git\n", "two lines"),
            ("/tmp/new\nline\n/tmp/new\nline/.git\nfalse\n", "a line feed inside a path shifts the fields"),
            ("tmp/a\n/tmp/a/.git\nfalse\n", "relative top level"),
            ("/tmp/a\n.git\nfalse\n", "relative common directory"),
            ("/tmp/a\n/tmp/a/.git\nmaybe\n", "bad bare flag"),
            ("/tmp/a\n/tmp/a/.git\nfalse", "missing final line feed"),
            ("/tmp/a\t\n/tmp/a/.git\nfalse\n", "control character"),
            ("", "empty"),
        ]
        for (text, reason) in cases {
            XCTAssertThrowsError(try ProbeParser.parse(data(text)), reason) {
                XCTAssertEqual(($0 as? ParseError)?.parser, "ProbeParser", reason)
            }
        }
    }

    func testInvalidUTF8Fails() {
        var bytes = Data("/tmp/a".utf8)
        bytes.append(0xFF)
        bytes.append(Data("\n/tmp/a/.git\nfalse\n".utf8))
        XCTAssertThrowsError(try ProbeParser.parse(bytes))
    }
}
