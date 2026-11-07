import Foundation
import XCTest

@testable import Overgrove

/// PAR-REF-01…06 (parsing-spec.md §6), plus truncation (SEC-T15-03) and field-format failures (§1.6).
final class RefParserTests: XCTestCase {
    /// Real `for-each-ref` output (Apple Git 2.54.0, `LC_ALL=C`) with the `ReadOnlyGitCommand.refs` format.
    ///
    /// Local branches: `ahead` (ahead 2), `behind` (behind 3), `both` (ahead 1, behind 2), `feat/한글-브랜치` and
    /// `no-upstream` (no upstream), `gone` (upstream deleted), `main` (checked out, in sync). Remote-tracking refs
    /// under `origin`, including the `origin/HEAD` symref. Tags: `light-tag` (lightweight), `v1` (annotated).
    private static let realOutput =
        Data(
            base64Encoded:
                "cmVmcy9oZWFkcy9haGVhZAA3ZjI3NDhlMTQ0N2FhYzg4MjgxZDIwYTJhZDViYTU2NjVkMDgxNjdlAAByZWZzL3JlbW90ZXMvb3JpZ2luL2FoZWFkACAAMTc5Mzg1MzY1MgAAYWhlYWQgMgpyZWZzL2hlYWRzL2JlaGluZAA0ZTY4MjNhNmZiZDIyNDc5ZDdhZTMyMDllY2EzYmRkOTZlOTEwNTllAAByZWZzL3JlbW90ZXMvb3JpZ2luL2JlaGluZAAgADE3OTM4NTM2NTIAAGJlaGluZCAzCnJlZnMvaGVhZHMvYm90aAAyODgwNDA0YzI4OGY1ODE0YmU0ZWY2YmVlNmExMzkxMTllN2I5NjdkAAByZWZzL3JlbW90ZXMvb3JpZ2luL2JvdGgAIAAxNzkzODUzNjUyAABhaGVhZCAxLCBiZWhpbmQgMgpyZWZzL2hlYWRzL2ZlYXQv7ZWc6riALeu4jOuenOy5mAA5NjkyOTQxZDdmYWQzMWYwYjYwMDFkZGRlZmYxN2YwMGUzOTZmN2FkAAAAIAAxNzkzODUzNjUyAAAKcmVmcy9oZWFkcy9nb25lADk2OTI5NDFkN2ZhZDMxZjBiNjAwMWRkZGVmZjE3ZjAwZTM5NmY3YWQAAHJlZnMvcmVtb3Rlcy9vcmlnaW4vZ29uZQAgADE3OTM4NTM2NTIAAGdvbmUKcmVmcy9oZWFkcy9tYWluADk2OTI5NDFkN2ZhZDMxZjBiNjAwMWRkZGVmZjE3ZjAwZTM5NmY3YWQAAHJlZnMvcmVtb3Rlcy9vcmlnaW4vbWFpbgAqADE3OTM4NTM2NTIAAApyZWZzL2hlYWRzL25vLXVwc3RyZWFtADk2OTI5NDFkN2ZhZDMxZjBiNjAwMWRkZGVmZjE3ZjAwZTM5NmY3YWQAAAAgADE3OTM4NTM2NTIAAApyZWZzL3JlbW90ZXMvb3JpZ2luL0hFQUQAOTY5Mjk0MWQ3ZmFkMzFmMGI2MDAxZGRkZWZmMTdmMDBlMzk2ZjdhZAAAACAAMTc5Mzg1MzY1MgByZWZzL3JlbW90ZXMvb3JpZ2luL21haW4ACnJlZnMvcmVtb3Rlcy9vcmlnaW4vYWhlYWQAOTY5Mjk0MWQ3ZmFkMzFmMGI2MDAxZGRkZWZmMTdmMDBlMzk2ZjdhZAAAACAAMTc5Mzg1MzY1MgAACnJlZnMvcmVtb3Rlcy9vcmlnaW4vYmVoaW5kAGIzZjgyNDIyYzMwYzg3MTgyMmIyOTMwMzMzYzllN2JjYWE2NGU1ZGYAAAAgADE3OTM4NTM2NTIAAApyZWZzL3JlbW90ZXMvb3JpZ2luL2JvdGgAYjNmODI0MjJjMzBjODcxODIyYjI5MzAzMzNjOWU3YmNhYTY0ZTVkZgAAACAAMTc5Mzg1MzY1MgAACnJlZnMvcmVtb3Rlcy9vcmlnaW4vbWFpbgA5NjkyOTQxZDdmYWQzMWYwYjYwMDFkZGRlZmYxN2YwMGUzOTZmN2FkAAAAIAAxNzkzODUzNjUyAAAKcmVmcy90YWdzL2xpZ2h0LXRhZwA0ZTY4MjNhNmZiZDIyNDc5ZDdhZTMyMDllY2EzYmRkOTZlOTEwNTllAAAAIAAxNzkzODUzNjUyAAAKcmVmcy90YWdzL3YxADRmYTAyYTE2ZDc5Njk3ZTAxNDFlOTliMjA2NjVmZDZjOWE5ZWE0ZjkAOTY5Mjk0MWQ3ZmFkMzFmMGI2MDAxZGRkZWZmMTdmMDBlMzk2ZjdhZAAAIAAAAAo="
        ) ?? Data()

    private let mainOID = "9692941d7fad31f0b6001dddeff17f00e396f7ad"
    private let oid = String(repeating: "ab", count: 20)
    private let date = Date(timeIntervalSince1970: 1_793_853_652)

    /// One record: eight NUL-separated fields ending with LF, as git prints them.
    private func record(
        _ refname: String, _ objectname: String? = nil, peeled: String = "", upstream: String = "", head: String = " ",
        date: String = "1793853652", symref: String = "", track: String = ""
    ) -> String {
        [refname, objectname ?? oid, peeled, upstream, head, date, symref, track].joined(separator: "\u{0}") + "\n"
    }

    private func parse(_ records: String..., truncated: Bool = false) throws -> RefParser.Listing {
        try RefParser.parse(Data(records.joined().utf8), truncated: truncated)
    }

    private func assertFails(
        _ data: Data, reason: String, offset: Int? = nil, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertThrowsError(try RefParser.parse(data), file: file, line: line) { error in
            let parseError = error as? ParseError
            XCTAssertEqual(parseError?.parser, "RefParser", file: file, line: line)
            XCTAssertEqual(parseError?.reason, reason, file: file, line: line)
            if let offset { XCTAssertEqual(parseError?.offset, offset, file: file, line: line) }
        }
    }

    private func assertFails(
        _ text: String, reason: String, offset: Int? = nil, file: StaticString = #filePath, line: UInt = #line
    ) {
        assertFails(Data(text.utf8), reason: reason, offset: offset, file: file, line: line)
    }

    private func branch(_ name: String, in listing: RefParser.Listing) throws -> Branch {
        try XCTUnwrap(listing.branches.first { $0.fullName == name }, "missing \(name)")
    }

    // MARK: - PAR-REF-01…05

    func testPARREF01_HeadsRemotesTagsAndHeadMarker() throws {
        let listing = try RefParser.parse(Self.realOutput)
        XCTAssertFalse(listing.isPartial)
        XCTAssertEqual(
            listing.branches.map(\.fullName),
            [
                "refs/heads/ahead", "refs/heads/behind", "refs/heads/both", "refs/heads/feat/한글-브랜치",
                "refs/heads/gone", "refs/heads/main", "refs/heads/no-upstream", "refs/remotes/origin/HEAD",
                "refs/remotes/origin/ahead", "refs/remotes/origin/behind", "refs/remotes/origin/both",
                "refs/remotes/origin/main",
            ])
        XCTAssertEqual(listing.tags.map(\.fullName), ["refs/tags/light-tag", "refs/tags/v1"])
        XCTAssertEqual(listing.branches.filter(\.isHead).map(\.fullName), ["refs/heads/main"])

        let main = try branch("refs/heads/main", in: listing)
        XCTAssertEqual(main.kind, .local)
        XCTAssertEqual(main.target, ObjectID(mainOID))
        XCTAssertEqual(main.committerDate, date)
        XCTAssertNil(main.symbolicTarget)

        let remote = try branch("refs/remotes/origin/main", in: listing)
        XCTAssertEqual(remote.kind, .remote(remote: "origin"))
        XCTAssertEqual(remote.shortName, "origin/main")
        XCTAssertEqual(remote.upstreamStatus, UpstreamStatus.none)
        XCTAssertFalse(remote.isHead)

        let light = try XCTUnwrap(listing.tags.first)
        XCTAssertEqual(light.target, ObjectID("4e6823a6fbd22479d7ae3209eca3bdd96e91059e"))
        XCTAssertNil(light.peeledTarget)
        XCTAssertEqual(light.date, date)
    }

    func testPARREF02_AnnotatedTagIsPeeled() throws {
        let tag = try XCTUnwrap(try RefParser.parse(Self.realOutput).tags.last)
        XCTAssertEqual(tag.shortName, "v1")
        XCTAssertEqual(tag.target, ObjectID("4fa02a16d79697e0141e99b20665fd6c9a9ea4f9"))
        XCTAssertEqual(tag.peeledTarget, ObjectID(mainOID))
        XCTAssertEqual(tag.commit, ObjectID(mainOID))
        XCTAssertNil(tag.date, "a tag object has no committer date")
    }

    func testPARREF03_RemoteHeadSymref() throws {
        let head = try branch("refs/remotes/origin/HEAD", in: try RefParser.parse(Self.realOutput))
        XCTAssertEqual(head.kind, .remote(remote: "origin"))
        XCTAssertEqual(head.symbolicTarget, "refs/remotes/origin/main")
        XCTAssertEqual(head.target, ObjectID(mainOID))
    }

    func testPARREF03_InvalidSymrefTargetFails() {
        assertFails(record("refs/remotes/origin/HEAD", symref: "origin/main"), reason: "invalid symref target")
        assertFails(record("refs/remotes/origin/HEAD", symref: "refs/remotes/-x"), reason: "invalid symref target")
    }

    func testPARREF04_SlashAndUnicodeBranchNames() throws {
        let listing = try RefParser.parse(Self.realOutput)
        let unicode = try branch("refs/heads/feat/한글-브랜치", in: listing)
        XCTAssertEqual(unicode.shortName, "feat/한글-브랜치")
        XCTAssertEqual(unicode.kind, .local)

        // NFC and NFD spellings are different refs; bytes are kept as git printed them (parsing-spec.md §1.4).
        let nfd = "refs/heads/e\u{301}"
        let nfc = "refs/heads/\u{e9}"
        let names = try parse(record(nfd), record(nfc)).branches.map(\.fullName)
        XCTAssertEqual(names.map { Array($0.utf8) }, [Array(nfd.utf8), Array(nfc.utf8)])

        let nested = try XCTUnwrap(try parse(record("refs/remotes/up/stream/feat/x")).branches.first)
        XCTAssertEqual(nested.kind, .remote(remote: "up"))
        XCTAssertEqual(nested.shortName, "up/stream/feat/x")
    }

    func testPARREF04_InvalidUTF8RefNameFails() {
        // A ref name goes back to git as an argument, so it must not be decoded lossily.
        var data = Data("refs/heads/bad".utf8)
        data.append(0xFF)
        data.append(Data(record("").utf8))
        assertFails(data, reason: "invalid ref name", offset: 0)
    }

    func testPARREF04_RefNamesThatCannotGoBackToGitFail() {
        for name in ["refs/heads/-x", "refs/heads/a..b", "refs/heads/x.lock", "heads/main", "refs/heads/a b"] {
            assertFails(record(name), reason: "invalid ref name", offset: 0)
        }
    }

    func testPARREF05_NoUpstream() throws {
        let listing = try RefParser.parse(Self.realOutput)
        let branch = try branch("refs/heads/no-upstream", in: listing)
        XCTAssertEqual(branch.upstreamStatus, UpstreamStatus.none)
        XCTAssertNil(branch.upstream)
    }

    func testPARREF05_TrackWithoutUpstreamFails() {
        assertFails(record("refs/heads/x", track: "ahead 1"), reason: "track without upstream")
        assertFails(record("refs/heads/x", track: "gone"), reason: "track without upstream")
    }

    func testPARREF05_InvalidUpstreamFails() {
        let line = record("refs/heads/x", upstream: "origin/x")
        assertFails(line, reason: "invalid upstream", offset: "refs/heads/x".utf8.count + 1 + 40 + 1 + 1)
        assertFails(record("refs/heads/x", upstream: "refs/remotes/origin/-x"), reason: "invalid upstream")
    }

    // MARK: - PAR-REF-06: `%(upstream:track,nobracket)`

    func testPARREF06_TrackFiveCasesFromRealOutput() throws {
        let listing = try RefParser.parse(Self.realOutput)
        let expected: [String: UpstreamStatus] = [
            "refs/heads/main": .tracking(upstream: "refs/remotes/origin/main", ahead: 0, behind: 0),
            "refs/heads/ahead": .tracking(upstream: "refs/remotes/origin/ahead", ahead: 2, behind: 0),
            "refs/heads/behind": .tracking(upstream: "refs/remotes/origin/behind", ahead: 0, behind: 3),
            "refs/heads/both": .tracking(upstream: "refs/remotes/origin/both", ahead: 1, behind: 2),
            "refs/heads/gone": .gone(upstream: "refs/remotes/origin/gone"),
            "refs/heads/no-upstream": UpstreamStatus.none,
        ]
        for (name, status) in expected {
            XCTAssertEqual(try branch(name, in: listing).upstreamStatus, status, name)
        }
        XCTAssertEqual(try branch("refs/heads/main", in: listing).upstream, "refs/remotes/origin/main")
    }

    func testPARREF06_EmptyTrackSeparatesInSyncFromNoUpstream() throws {
        let listing = try parse(
            record("refs/heads/synced", upstream: "refs/remotes/origin/synced"), record("refs/heads/local"))
        XCTAssertEqual(
            listing.branches.map(\.upstreamStatus),
            [.tracking(upstream: "refs/remotes/origin/synced", ahead: 0, behind: 0), .none])
    }

    func testPARREF06_MalformedTrackFails() {
        let upstream = "refs/remotes/origin/x"
        let malformed = [
            "ahead", "ahead ", "ahead -1", "ahead +1", "ahead 0x1", "ahead 1 ", " ahead 1", "ahead 1,behind 2",
            "behind 2, ahead 1", "ahead 1, behind", "ahead 1, behind 2, gone", "AHEAD 1", "[ahead 1]", "gone ",
            "ahead 99999999999999999999", "ahead ١",
        ]
        for track in malformed {
            let line = record("refs/heads/x", upstream: upstream, track: track)
            let trackOffset = line.utf8.count - 1 - track.utf8.count
            assertFails(line, reason: "invalid upstream track", offset: trackOffset)
        }
    }

    // MARK: - Field formats (parsing-spec.md §1.6–§1.8)

    func testWrongFieldCountFails() {
        // The format before #54 had seven fields; reading it would shift every value.
        let seven = ["refs/heads/x", oid, "", "", " ", "1793853652", ""].joined(separator: "\u{0}") + "\n"
        assertFails(seven, reason: "expected 8 fields", offset: 0)
        let second = record("refs/heads/a")
        assertFails(second + record("refs/heads/b") + "\u{0}\n", reason: "expected 8 fields")
        assertFails(second + seven, reason: "expected 8 fields", offset: second.utf8.count)
    }

    func testInvalidObjectIDsFail() {
        assertFails(record("refs/heads/x", String(oid.prefix(39))), reason: "invalid object name", offset: 13)
        assertFails(record("refs/heads/x", oid.uppercased()), reason: "invalid object name")
        assertFails(record("refs/heads/x", ""), reason: "invalid object name")
        assertFails(record("refs/tags/x", peeled: "zz"), reason: "invalid peeled object name")
    }

    func testSHA256ObjectIDsAreAccepted() throws {
        let long = String(repeating: "c", count: 64)
        let tag = try XCTUnwrap(try parse(record("refs/tags/v2", long, peeled: long, date: "")).tags.first)
        XCTAssertEqual(tag.target.hex, long)
        XCTAssertTrue(tag.target.isSHA256)
    }

    func testHeadMarkerMustBeStarOrSpace() {
        for marker in ["", "+", "**", "  "] {
            assertFails(record("refs/heads/x", head: marker), reason: "invalid HEAD marker")
        }
    }

    func testCommitterDateIsUnsignedDecimalOrEmpty() throws {
        let undated = try XCTUnwrap(try parse(record("refs/heads/x", date: "")).branches.first)
        XCTAssertNil(undated.committerDate)
        for value in ["-1", "+1", "1.5", "abc", " 1", "99999999999999999999", "١"] {
            assertFails(record("refs/heads/x", date: value), reason: "invalid committer date")
        }
    }

    func testOtherPrefixesAreIgnored() throws {
        let listing = try parse(record("refs/notes/commits"), record("refs/heads/main"), record("refs/stash"))
        XCTAssertEqual(listing.branches.map(\.fullName), ["refs/heads/main"])
        XCTAssertTrue(listing.tags.isEmpty)
    }

    func testEmptyOutput() throws {
        let listing = try RefParser.parse(Data())
        XCTAssertTrue(listing.branches.isEmpty)
        XCTAssertTrue(listing.tags.isEmpty)
        XCTAssertFalse(listing.isPartial)
    }

    // MARK: - Truncation (parsing-spec.md §1.5)

    func testUnterminatedOutputFails() {
        let full = record("refs/heads/a") + record("refs/heads/b")
        assertFails(String(full.dropLast()), reason: "unterminated record", offset: record("refs/heads/a").utf8.count)
    }

    func testTruncatedOutputDropsOnlyTheIncompleteRecord() throws {
        let complete = record("refs/heads/a") + record("refs/heads/b")
        let cut = complete + String(record("refs/heads/c").prefix(20))
        let listing = try RefParser.parse(Data(cut.utf8), truncated: true)
        XCTAssertTrue(listing.isPartial)
        XCTAssertEqual(listing.branches.map(\.fullName), ["refs/heads/a", "refs/heads/b"])

        // A record cut in the middle of a multi-byte character is still just dropped.
        var real = Self.realOutput
        let cutInsideHangul = real.firstRange(of: Data("한".utf8))!.lowerBound + 1
        real = real.prefix(cutInsideHangul)
        let partial = try RefParser.parse(real, truncated: true)
        XCTAssertEqual(partial.branches.map(\.fullName), ["refs/heads/ahead", "refs/heads/behind", "refs/heads/both"])
    }

    func testTruncatedAtRecordBoundaryKeepsEveryRecord() throws {
        let listing = try parse(record("refs/heads/a"), record("refs/tags/t"), truncated: true)
        XCTAssertTrue(listing.isPartial)
        XCTAssertEqual(listing.branches.count, 1)
        XCTAssertEqual(listing.tags.count, 1)
    }

    func testTruncatedOutputStillValidatesCompleteRecords() {
        let data = Data((record("refs/heads/x", "bad") + "refs/heads/y").utf8)
        XCTAssertThrowsError(try RefParser.parse(data, truncated: true)) { error in
            XCTAssertEqual((error as? ParseError)?.reason, "invalid object name")
        }
    }
}
