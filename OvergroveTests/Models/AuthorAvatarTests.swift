import XCTest

@testable import Overgrove

final class AuthorAvatarTests: XCTestCase {
    /// FNV-1a 32-bit reference values: "" → 0x811c9dc5, "a" → 0xe40c292c (mod 8: 5 and 4).
    func testColorIndexIsFNV1aOfTheNormalizedEmailMod8() {
        XCTAssertEqual(AuthorAvatar.colorIndex(email: ""), Int(0x811c_9dc5 % 8))
        XCTAssertEqual(AuthorAvatar.colorIndex(email: "a"), Int(0xe40c_292c % 8))
        XCTAssertEqual(
            AuthorAvatar.colorIndex(email: "  Alice@Example.COM \n"),
            AuthorAvatar.colorIndex(email: "alice@example.com"),
            "trimmed and lowercased")
        XCTAssertTrue((0..<8).contains(AuthorAvatar.colorIndex(email: "bob@example.com")))
    }

    func testInitials() {
        XCTAssertEqual(AuthorAvatar.initials(name: "Alice Example"), "AE")
        XCTAssertEqual(AuthorAvatar.initials(name: "alice b. example"), "AE", "first and last words")
        XCTAssertEqual(AuthorAvatar.initials(name: "dependabot"), "D")
        XCTAssertEqual(AuthorAvatar.initials(name: "김철수"), "김")
        XCTAssertEqual(AuthorAvatar.initials(name: "  "), "?")
        XCTAssertEqual(AuthorAvatar.initials(name: "O'Brien, Pat"), "OP")
    }
}
