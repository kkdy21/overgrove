import Foundation
import XCTest

@testable import Overgrove

/// PAR-STASH-01…04 (parsing-spec.md §4).
final class StashParserTests: XCTestCase {
    /// Real `log -g -z --format=%gd%x00%H%x00%gs%x00%ct%x00%P refs/stash` output (git 2.54.0), newest first:
    /// `On feat/x: exp: try` (`-u`, three parents), `On main: fix: a: b 한글 🌳 émoji`, `WIP on main: 0f047e0 base2`.
    /// All committed at 1793853652. A fixture that fails to decode becomes empty data, which the tests reject.
    private static let realListing =
        Data(
            base64Encoded:
                "c3Rhc2hAezB9ADlkYjczYzFkYjlhZjcxZTg2OTQ2MTVjYzBmZTE5YTkzZGY3YmViMzkAT24gZmVhdC94OiBleHA6IHRyeQAxNzkzODUzNjUyADBmMDQ3ZTBkZDQ4YWEwYzY5MmQ5YjAzZGJhNmQ3ZTdlYTA5YWQyMzIgNjQ1NzVhYmQyMGY3NDI4N2JkNzFmYWU0NjM1M2QxZGUwMzkxYjM1YSA4ZTQ5ZDQyZWYxYmUzMGE0M2E4MGQ2NDQ1YWUwOTY3ZGE3YzY0MDBhAHN0YXNoQHsxfQA3MTMwZDhlZjkyNGI3ODU1NTE2MmI1YjQyYTk3Y2EwOTA3MDBjZjAzAE9uIG1haW46IGZpeDogYTogYiDtlZzquIAg8J+MsyDDqW1vamkAMTc5Mzg1MzY1MgAwZjA0N2UwZGQ0OGFhMGM2OTJkOWIwM2RiYTZkN2U3ZWEwOWFkMjMyIDUyNGIyOWVjMjY1MWM4MzhlNjQxZWEwOGYwMTAwZjMzYTVmNjc2MzEAc3Rhc2hAezJ9ADYzNWEzZjJhMzkyYjAxZDlmYzY3ZmVkMmMzNWMwOGFkNDkxNzUyMTcAV0lQIG9uIG1haW46IDBmMDQ3ZTAgYmFzZTIAMTc5Mzg1MzY1MgAwZjA0N2UwZGQ0OGFhMGM2OTJkOWIwM2RiYTZkN2U3ZWEwOWFkMjMyIDUyNGIyOWVjMjY1MWM4MzhlNjQxZWEwOGYwMTAwZjMzYTVmNjc2MzEA"
        ) ?? Data()

    private let sha1A = String(repeating: "a", count: 40)
    private let sha256B = String(repeating: "b", count: 64)

    private func data(_ text: String) -> Data { Data(text.utf8) }

    /// One record in the `%gd␀%H␀%gs␀%ct␀%P␀` layout.
    private func record(
        _ selector: String = "stash@{0}",
        oid: String? = nil,
        subject: String = "On main: s",
        time: String = "1793853652",
        parents: String? = nil
    ) -> String {
        "\(selector)\u{0}\(oid ?? sha1A)\u{0}\(subject)\u{0}\(time)\u{0}\(parents ?? sha1A + " " + sha1A)\u{0}"
    }

    private func assertParseFails(
        _ input: Data,
        reason: String,
        offset: Int? = nil,
        truncated: Bool = false,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try StashParser.parse(input, truncated: truncated), file: file, line: line) { error in
            let parseError = error as? ParseError
            XCTAssertEqual(parseError?.parser, "StashParser", file: file, line: line)
            XCTAssertEqual(parseError?.reason, reason, file: file, line: line)
            if let offset {
                XCTAssertEqual(parseError?.offset, offset, file: file, line: line)
            }
        }
    }

    // MARK: - PAR-STASH-01

    func testPARSTASH01_RealListingKeepsOrderAndAddressesByOID() throws {
        let listing = try StashParser.parse(Self.realListing)
        XCTAssertFalse(listing.isPartial)
        XCTAssertEqual(listing.stashes.map(\.index), [0, 1, 2])
        XCTAssertEqual(listing.stashes.map(\.refName), ["stash@{0}", "stash@{1}", "stash@{2}"])
        XCTAssertEqual(
            listing.stashes.map(\.oid.hex),
            [
                "9db73c1db9af71e8694615cc0fe19a93df7beb39",
                "7130d8ef924b78555162b5b42a97ca090700cf03",
                "635a3f2a392b01d9fc67fed2c35c08ad49175217",
            ]
        )
        XCTAssertEqual(listing.stashes.map(\.id), listing.stashes.map(\.oid))
        XCTAssertTrue(listing.stashes.allSatisfy { $0.date == Date(timeIntervalSince1970: 1_793_853_652) })
    }

    func testPARSTASH01_WIPOnAndOnSubjects() throws {
        let stashes = try StashParser.parse(Self.realListing).stashes
        let onSubject = stashes[0]
        XCTAssertEqual(onSubject.subject, "On feat/x: exp: try")
        XCTAssertEqual(onSubject.branch, "feat/x")
        XCTAssertEqual(onSubject.message, "exp: try")
        let wip = stashes[2]
        XCTAssertEqual(wip.subject, "WIP on main: 0f047e0 base2")
        XCTAssertEqual(wip.branch, "main")
        XCTAssertEqual(wip.message, "0f047e0 base2")
    }

    func testPARSTASH01_UnrecognizedSubjectIsShownVerbatim() throws {
        for subject in ["autostash", "On main without colon", "WIP onmain: x", "On : x", "on main: x", ""] {
            let stash = try XCTUnwrap(try StashParser.parse(data(record(subject: subject))).stashes.first)
            XCTAssertEqual(stash.subject, subject)
            XCTAssertNil(stash.branch, subject)
            XCTAssertEqual(stash.message, subject)
        }
    }

    func testPARSTASH01_EmptyMessageAfterBranch() throws {
        let stash = try XCTUnwrap(try StashParser.parse(data(record(subject: "On main: "))).stashes.first)
        XCTAssertEqual(stash.branch, "main")
        XCTAssertEqual(stash.message, "")
    }

    func testPARSTASH01_SHA256OIDIsAccepted() throws {
        let stash = try XCTUnwrap(try StashParser.parse(data(record(oid: sha256B))).stashes.first)
        XCTAssertTrue(stash.oid.isSHA256)
    }

    // MARK: - PAR-STASH-02

    /// `%P`: base commit first; index and untracked commits follow (S-04, #71).
    func testPARSTASH01_ParentsGiveBaseAndIncludes() throws {
        let stashes = try StashParser.parse(Self.realListing).stashes
        let base = "0f047e0dd48aa0c692d9b03dba6d7e7ea09ad232"
        XCTAssertEqual(stashes.map { $0.baseCommit?.hex }, [base, base, base])
        XCTAssertEqual(stashes.map(\.includesIndex), [true, true, true])
        XCTAssertEqual(stashes.map(\.includesUntracked), [true, false, false], "only the -u stash has a third parent")
    }

    func testPARSTASH04_InvalidParentListsFail() {
        for parents in ["", " ", "\(sha1A)  \(sha1A)", "\(sha1A) \(sha1A) \(sha1A) \(sha1A)", "nothex", "\(sha1A) ABC"]
        {
            XCTAssertThrowsError(try StashParser.parse(data(record(parents: parents))), parents.debugDescription)
        }
    }

    func testPARSTASH02_ColonAndUnicodeInSubject() throws {
        let stash = try StashParser.parse(Self.realListing).stashes[1]
        XCTAssertEqual(stash.subject, "On main: fix: a: b 한글 🌳 émoji")
        XCTAssertEqual(stash.branch, "main")
        XCTAssertEqual(stash.message, "fix: a: b 한글 🌳 émoji")
    }

    func testPARSTASH02_BranchEndsAtFirstColonSpace() throws {
        let stash = try XCTUnwrap(
            try StashParser.parse(data(record(subject: "WIP on (no branch): 1234567 detached: work"))).stashes.first
        )
        XCTAssertEqual(stash.branch, "(no branch)")
        XCTAssertEqual(stash.message, "1234567 detached: work")
    }

    func testPARSTASH02_InvalidUTF8SubjectIsDisplayedLossilyWithoutBranch() throws {
        var input = Data("stash@{0}\u{0}\(sha1A)\u{0}On ".utf8)
        input.append(contentsOf: [0x66, 0xFF, 0x6F])
        input.append(Data(": msg\u{0}1793853652\u{0}\(sha1A)\u{0}".utf8))
        let stash = try XCTUnwrap(try StashParser.parse(input).stashes.first)
        XCTAssertEqual(stash.subject, "On f\u{FFFD}o: msg")
        XCTAssertNil(stash.branch)
        XCTAssertEqual(stash.message, stash.subject)
    }

    // MARK: - PAR-STASH-03

    func testPARSTASH03_EmptyListing() throws {
        let listing = try StashParser.parse(Data())
        XCTAssertEqual(listing.stashes, [])
        XCTAssertFalse(listing.isPartial)
    }

    func testPARSTASH03_EmptyTruncatedListingIsPartial() throws {
        let listing = try StashParser.parse(Data(), truncated: true)
        XCTAssertEqual(listing.stashes, [])
        XCTAssertTrue(listing.isPartial)
    }

    // MARK: - PAR-STASH-04

    func testPARSTASH04_FieldCountMismatchFailsWithOffsetOfIncompleteGroup() {
        let first = record()
        let input = data(first + "stash@{1}\u{0}\(sha1A)\u{0}On main: s\u{0}")
        assertParseFails(input, reason: "incomplete record", offset: first.utf8.count)
    }

    func testPARSTASH04_MissingFinalNULFails() {
        let full = record()
        let input = data(String(full.dropLast()))
        assertParseFails(input, reason: "incomplete record", offset: 0)
    }

    func testPARSTASH04_LoneNULFails() {
        assertParseFails(Data([0]), reason: "incomplete record", offset: 0)
    }

    func testPARSTASH04_ExtraFieldShiftsRecordsAndFails() {
        // Six fields then four: the total is a multiple of five, but the shifted first group has text for a time.
        let input = data(
            "stash@{0}\u{0}\(sha1A)\u{0}On main: s\u{0}extra\u{0}1793853652\u{0}\(sha1A)\u{0}"
                + "stash@{1}\u{0}\(sha1A)\u{0}x\u{0}1\u{0}")
        assertParseFails(input, reason: "invalid time")
    }

    func testPARSTASH04_InvalidSelectorsFail() {
        let invalid = [
            "stash@{}", "stash@{-1}", "stash@{+1}", "stash@{1 }", "stash@{１}", "stash@{0x1}", "refs/stash@{0}",
            "stash@{0}x", "stash", "", "stash@{99999999999999999999}",
        ]
        for selector in invalid {
            assertParseFails(data(record(selector)), reason: "invalid stash selector", offset: 0)
        }
    }

    func testPARSTASH04_InvalidOIDsFail() {
        let invalid = [
            "", String(repeating: "A", count: 40), String(repeating: "a", count: 39), String(repeating: "g", count: 40),
            String(repeating: "a", count: 41), " " + String(repeating: "a", count: 40),
        ]
        let selectorLength = "stash@{0}\u{0}".utf8.count
        for oid in invalid {
            assertParseFails(data(record(oid: oid)), reason: "invalid stash OID", offset: selectorLength)
        }
    }

    func testPARSTASH04_InvalidOIDBytesFail() {
        var input = Data("stash@{0}\u{0}".utf8)
        input.append(contentsOf: [UInt8](repeating: 0x61, count: 39) + [0xFF])
        input.append(Data("\u{0}On main: s\u{0}1793853652\u{0}\(sha1A)\u{0}".utf8))
        assertParseFails(input, reason: "invalid stash OID")
    }

    func testPARSTASH04_InvalidTimesFail() {
        let timeOffset = "stash@{0}\u{0}\(sha1A)\u{0}On main: s\u{0}".utf8.count
        for time in ["", "-1", "+1", "1.5", " 1", "１", "99999999999999999999", "0x10"] {
            assertParseFails(data(record(time: time)), reason: "invalid time", offset: timeOffset)
        }
    }

    // MARK: - Truncated output (parsing-spec.md §1.5)

    func testTruncatedOutputDropsOnlyTheIncompleteLastGroup() throws {
        let complete = record("stash@{0}") + record("stash@{1}")
        for cut in ["stash@{2}", "stash@{2}\u{0}\(sha1A)\u{0}On ma", "stash@{2}\u{0}\(sha1A)\u{0}On main: s\u{0}179"] {
            let listing = try StashParser.parse(data(complete + cut), truncated: true)
            XCTAssertEqual(listing.stashes.map(\.index), [0, 1], cut)
            XCTAssertTrue(listing.isPartial)
        }
    }

    func testTruncatedOutputKeepsRecordsEndingAtTheCut() throws {
        let listing = try StashParser.parse(data(record("stash@{0}") + record("stash@{1}")), truncated: true)
        XCTAssertEqual(listing.stashes.map(\.index), [0, 1])
        XCTAssertTrue(listing.isPartial)
    }

    func testTruncatedOutputStillValidatesCompleteGroups() {
        let input = data(record(oid: "bad") + "stash@{1}")
        assertParseFails(input, reason: "invalid stash OID", truncated: true)
    }
}
