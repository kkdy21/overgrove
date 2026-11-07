import Foundation
import XCTest

@testable import Overgrove

/// `GitDirectoryProbeParser` for `rev-parse --path-format=absolute --git-common-dir --absolute-git-dir
/// --is-bare-repository --is-inside-work-tree` (parsing-spec.md §11.2.1, #222).
final class GitDirectoryProbeParserTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testBareRepository() throws {
        let probe = try GitDirectoryProbeParser.parse(data("/tmp/dev/api.git\n/tmp/dev/api.git\ntrue\nfalse\n"))
        XCTAssertEqual(probe.commonDirectory.path, "/tmp/dev/api.git")
        XCTAssertEqual(probe.gitDirectory.path, "/tmp/dev/api.git")
        XCTAssertTrue(probe.isBare)
        XCTAssertFalse(probe.isInsideWorkTree)
    }

    func testLinkedWorktreeOfABareRepository() throws {
        let probe = try GitDirectoryProbeParser.parse(
            data("/tmp/dev/api.git\n/tmp/dev/api.git/worktrees/main\nfalse\ntrue\n"))
        XCTAssertEqual(probe.gitDirectory.path, "/tmp/dev/api.git/worktrees/main")
        XCTAssertFalse(probe.isBare)
        XCTAssertTrue(probe.isInsideWorkTree)
    }

    func testPathsWithSpacesAndUnicode() throws {
        let probe = try GitDirectoryProbeParser.parse(data("/tmp/my repo 🌳.git\n/tmp/my repo 🌳.git\ntrue\nfalse\n"))
        XCTAssertEqual(probe.commonDirectory.lastPathComponent, "my repo 🌳.git")
    }

    func testMalformedOutputFails() {
        let cases: [(String, String)] = [
            ("/tmp/a.git\n/tmp/a.git\ntrue\n", "three lines"),
            ("/tmp/a.git\n/tmp/a.git\ntrue\nfalse\nextra\n", "five lines"),
            ("/tmp/new\nline.git\n/tmp/new\nline.git\ntrue\nfalse\n", "a line feed inside a path shifts the fields"),
            ("tmp/a.git\n/tmp/a.git\ntrue\nfalse\n", "relative common directory"),
            ("/tmp/a.git\na.git\ntrue\nfalse\n", "relative git directory"),
            ("/tmp/a.git\n/tmp/a.git\nyes\nfalse\n", "bad bare flag"),
            ("/tmp/a.git\n/tmp/a.git\ntrue\n1\n", "bad work tree flag"),
            ("/tmp/a.git\n/tmp/a.git\ntrue\nfalse", "missing final line feed"),
            ("/tmp/a\u{7F}.git\n/tmp/a.git\ntrue\nfalse\n", "control character"),
            ("", "empty"),
        ]
        for (text, reason) in cases {
            XCTAssertThrowsError(try GitDirectoryProbeParser.parse(data(text)), reason) {
                XCTAssertEqual(($0 as? ParseError)?.parser, "GitDirectoryProbeParser", reason)
            }
        }
    }

    func testInvalidUTF8Fails() {
        var bytes = Data("/tmp/a".utf8)
        bytes.append(0xFF)
        bytes.append(contentsOf: Data(".git\n/tmp/a.git\ntrue\nfalse\n".utf8))
        XCTAssertThrowsError(try GitDirectoryProbeParser.parse(bytes)) {
            XCTAssertEqual(($0 as? ParseError)?.reason, "not valid UTF-8")
        }
    }
}
