import Foundation
import XCTest

@testable import Overgrove

/// PAR-CONFIG-01…06 (parsing-spec.md §9).
final class ConfigParserTests: XCTestCase {
    /// Real output of `git config --list --show-scope -z --includes` (Apple Git 2.50.1) for a repository with
    /// a URL subsection, an empty helper reset followed by a helper, an `ext::` insteadOf, a value with a line
    /// feed, a valueless boolean, and a filter driver whose name contains a space.
    private let realOutput = Data(
        base64Encoded:
            "bG9jYWwAY29yZS5yZXBvc2l0b3J5Zm9ybWF0dmVyc2lvbgowAGxvY2FsAGNvcmUuZmlsZW1vZGUKdHJ1ZQBsb2NhbABjb3JlLmJhcmUKZmFsc2UAbG9jYWwAY29yZS5sb2dhbGxyZWZ1cGRhdGVzCnRydWUAbG9jYWwAY29yZS5pZ25vcmVjYXNlCnRydWUAbG9jYWwAY29yZS5wcmVjb21wb3NldW5pY29kZQp0cnVlAGxvY2FsAGNyZWRlbnRpYWwuaHR0cHM6Ly9leGFtcGxlLmNvbS5oZWxwZXIKAGxvY2FsAGNyZWRlbnRpYWwuaHR0cHM6Ly9leGFtcGxlLmNvbS5oZWxwZXIKIWVjaG8geABsb2NhbAB1cmwuZXh0OjpzaCAtYyB4Lmluc3RlYWRvZgpodHRwczovL2V2aWwuZXhhbXBsZS8AbG9jYWwAeC52CmEKYgBsb2NhbAB4LmZsYWcAbG9jYWwAZmlsdGVyLldlaXJkIE5hbWUuY2xlYW4KY2F0AGxvY2FsAGluY2x1ZGUucGF0aAouLi9pbmMuY2ZnAA=="
    )!

    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testPARCONFIG01_AllScopes() throws {
        let input = ["system", "global", "local", "worktree", "command", "unknown"]
            .map { "\($0)\u{0}a.b\nv\u{0}" }.joined()
        let listing = try ConfigParser.parse(data(input))
        XCTAssertEqual(listing.entries.map(\.scope), [.system, .global, .local, .worktree, .command, .unknown])
        XCTAssertFalse(listing.isPartial)
    }

    func testPARCONFIG01_UnknownScopeFailsClosed() {
        XCTAssertThrowsError(try ConfigParser.parse(data("future\u{0}a.b\nv\u{0}"))) {
            XCTAssertEqual(($0 as? ParseError)?.reason, "unknown scope")
        }
    }

    func testPARCONFIG02_SubsectionsWithDots() throws {
        let entries = try ConfigParser.parse(realOutput).entries
        let helpers = entries.filter { $0.section == "credential" }
        XCTAssertEqual(helpers.map(\.subsection), ["https://example.com", "https://example.com"])
        XCTAssertEqual(helpers.map(\.variable), ["helper", "helper"])
        let insteadOf = try XCTUnwrap(entries.first { $0.section == "url" })
        XCTAssertEqual(insteadOf.subsection, "ext::sh -c x")
        XCTAssertEqual(insteadOf.variable, "insteadof")
        XCTAssertEqual(insteadOf.value, "https://evil.example/")
    }

    func testPARCONFIG03_ValueWithLineFeed() throws {
        let entry = try XCTUnwrap(try ConfigParser.parse(realOutput).entries.first { $0.key == "x.v" })
        XCTAssertEqual(entry.value, "a\nb")
    }

    func testPARCONFIG04_ValuelessBooleanIsDistinctFromEmptyValue() throws {
        let entries = try ConfigParser.parse(realOutput).entries
        XCTAssertEqual(entries.first { $0.key == "x.flag" }?.value, .some(nil), "valueless boolean")
        let reset = entries.first { $0.key == "credential.https://example.com.helper" }
        XCTAssertEqual(reset?.value, "", "an empty value resets multi-valued keys and must not become nil")
    }

    func testPARCONFIG05_FilterDriverNameValidation() throws {
        let filter = try XCTUnwrap(try ConfigParser.parse(realOutput).entries.first { $0.section == "filter" })
        XCTAssertEqual(filter.subsection, "Weird Name", "subsection case is preserved, section is lowercased")
        XCTAssertFalse(ConfigParser.isNeutralizableDriverName("Weird Name"))
        XCTAssertTrue(ConfigParser.isNeutralizableDriverName("lfs"))
        XCTAssertTrue(ConfigParser.isNeutralizableDriverName("my-driver_2.x"))
        for bad in ["", "a b", "a=b", "x;rm", "ünï", String(repeating: "a", count: 65), "a\nb"] {
            XCTAssertFalse(ConfigParser.isNeutralizableDriverName(bad), bad)
        }
    }

    func testPARCONFIG06_OrderIsPreserved() throws {
        let entries = try ConfigParser.parse(realOutput).entries
        XCTAssertEqual(
            entries.map(\.key),
            [
                "core.repositoryformatversion", "core.filemode", "core.bare", "core.logallrefupdates",
                "core.ignorecase", "core.precomposeunicode", "credential.https://example.com.helper",
                "credential.https://example.com.helper", "url.ext::sh -c x.insteadof", "x.v", "x.flag",
                "filter.Weird Name.clean", "include.path",
            ]
        )
        let helperValues = entries.filter { $0.section == "credential" }.map(\.value)
        XCTAssertEqual(helperValues, ["", "!echo x"], "reset first, then the helper, exactly as git reads them")
    }

    func testTruncatedOutputDropsTheLastEntry() throws {
        let cut = realOutput.prefix(realOutput.count - 5)  // inside the last value
        let listing = try ConfigParser.parse(cut, truncated: true)
        XCTAssertTrue(listing.isPartial)
        XCTAssertEqual(listing.entries.last?.key, "filter.Weird Name.clean")
    }

    func testMalformedInputFails() {
        XCTAssertThrowsError(try ConfigParser.parse(data("local\u{0}")))  // scope without an entry
        XCTAssertThrowsError(try ConfigParser.parse(data("local\u{0}nodot\nv\u{0}")))
        XCTAssertThrowsError(try ConfigParser.parse(data("local\u{0}.x\nv\u{0}")))
        XCTAssertEqual(try ConfigParser.parse(Data()).entries, [])
    }
}
