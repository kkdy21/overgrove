import Foundation
import XCTest

@testable import Overgrove

/// PAR-SUBMOD (parsing-spec.md §11.6, #108): `config --file .gitmodules --no-includes -z --get-regexp …`.
final class SubmoduleListParserTests: XCTestCase {
    private func parse(_ text: String, truncated: Bool = false) throws -> SubmoduleListParser.Listing {
        try SubmoduleListParser.parse(Data(text.utf8), truncated: truncated)
    }

    /// PAR-SUBMOD-01: paths in order; a subsection name with dots and slashes.
    func testPARSUBMOD01_PathsInOrder() throws {
        let listing = try parse("submodule.libs/a.path\nlibs/a\0submodule.v1.2.path\nvendor/b\0")
        XCTAssertEqual(listing.paths, [GitPath("libs/a"), GitPath("vendor/b")])
        XCTAssertFalse(listing.isPartial)
    }

    /// PAR-SUBMOD-02: an empty output (no `.gitmodules` entry; git exits 1) and duplicates.
    func testPARSUBMOD02_EmptyAndDuplicates() throws {
        XCTAssertEqual(try parse("").paths, [])
        XCTAssertEqual(try parse("submodule.a.path\nx\0submodule.b.path\nx\0").paths, [GitPath("x")])
    }

    /// PAR-SUBMOD-03: values are kept as git printed them, hostile ones included (the caller validates them), and
    /// bytes that are not UTF-8 stay unrepresentable.
    func testPARSUBMOD03_UntrustedValuesAreKept() throws {
        let listing = try parse("submodule.a.path\n../out\0submodule.b.path\n/abs\0submodule.c.path\n-x\nline\0")
        XCTAssertEqual(listing.paths, [GitPath("../out"), GitPath("/abs"), GitPath("-x\nline")])
        var bytes = Data("submodule.d.path\n".utf8)
        bytes.append(contentsOf: [0x66, 0xFF, 0x00])
        let lossy = try SubmoduleListParser.parse(bytes)
        XCTAssertEqual(lossy.paths.count, 1)
        XCTAssertFalse(lossy.paths[0].isRepresentable)
    }

    /// PAR-SUBMOD-04: a valueless boolean (`path` written without `=`) and an empty value carry no path.
    func testPARSUBMOD04_EntriesWithoutAPath() throws {
        XCTAssertEqual(try parse("submodule.a.path\0submodule.b.path\n\0submodule.c.path\nc\0").paths, [GitPath("c")])
    }

    /// PAR-SUBMOD-05: cut output drops the last record; uncut output must end with NUL; other keys are refused.
    func testPARSUBMOD05_TruncationAndShape() throws {
        let cut = try parse("submodule.a.path\na\0submodule.b.path\nb-cut", truncated: true)
        XCTAssertEqual(cut.paths, [GitPath("a")])
        XCTAssertTrue(cut.isPartial)
        XCTAssertThrowsError(try parse("submodule.a.path\na"))
        XCTAssertThrowsError(try parse("core.fsmonitor\nx\0"))
        XCTAssertThrowsError(try parse("submodule.a.url\nx\0"))
    }
}
