import Foundation
import XCTest

@testable import Overgrove

/// PAR-VER-01…02 (parsing-spec.md §11.1).
final class VersionParserTests: XCTestCase {
    private func parse(_ text: String) throws -> GitVersion { try VersionParser.parse(Data(text.utf8)) }

    func testPARVER01_KnownFormats() throws {
        XCTAssertEqual(try parse("git version 2.50.1 (Apple Git-155)\n"), GitVersion(major: 2, minor: 50, patch: 1))
        XCTAssertEqual(try parse("git version 2.54.0\n"), GitVersion(major: 2, minor: 54, patch: 0))
        XCTAssertEqual(try parse("git version 2.47.0.rc1"), GitVersion(major: 2, minor: 47, patch: 0))
        XCTAssertEqual(try parse("git version 2.45"), GitVersion(major: 2, minor: 45, patch: 0))
        XCTAssertEqual(try parse("git version 2.35.1.windows.2"), GitVersion(major: 2, minor: 35, patch: 1))
    }

    func testPARVER02_MinimumVersion() throws {
        XCTAssertTrue(try parse("git version 2.36.0").isSupported)
        XCTAssertTrue(try parse("git version 2.50.1 (Apple Git-155)").isSupported)
        XCTAssertFalse(try parse("git version 2.35.9").isSupported)
        XCTAssertFalse(try parse("git version 1.9.5").isSupported)
        XCTAssertLessThan(GitVersion(major: 2, minor: 9, patch: 0), GitVersion(major: 2, minor: 36, patch: 0))
    }

    func testMalformedOutputFails() {
        for text in ["", "hub version 2.0", "git version", "git version x.y", "git version 2"] {
            XCTAssertThrowsError(try parse(text), text)
        }
    }
}
