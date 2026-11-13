import Foundation
import XCTest

@testable import Overgrove

/// PAR-REF-01…07 (parsing-spec.md §6), plus truncation (SEC-T15-03) and field-format failures (§1.6).
final class RefParserTests: XCTestCase {
    /// Real `for-each-ref` output (Apple Git 2.54.0, `LC_ALL=C`) with the `ReadOnlyGitCommand.refs` format. It was
    /// captured before `%(upstream:remotename)` and `%(upstream:remoteref)` joined the format (#115); those two fields
    /// are appended as git 2.54.0 and 2.36.6 print them for this repository (`origin`, `refs/heads/<name>` for a
    /// branch tracking `origin/<name>`, empty otherwise), and so are `%(objecttype)` and `%(*objecttype)` (#432: `tag`
    /// and `commit` for `v1`, `commit` and empty for the rest).
    ///
    /// Local branches: `ahead` (ahead 2), `behind` (behind 3), `both` (ahead 1, behind 2), `feat/한글-브랜치` and
    /// `no-upstream` (no upstream), `gone` (upstream deleted), `main` (checked out, in sync). Remote-tracking refs
    /// under `origin`, including the `origin/HEAD` symref. Tags: `light-tag` (lightweight), `v1` (annotated).
    private static let realOutput =
        Data(
            base64Encoded:
                "cmVmcy9oZWFkcy9haGVhZAA3ZjI3NDhlMTQ0N2FhYzg4MjgxZDIwYTJhZDViYTU2NjVkMDgxNjdlAAByZWZzL3JlbW90ZXMvb3JpZ2luL2FoZWFkACAAMTc5Mzg1MzY1MgAAYWhlYWQgMgBvcmlnaW4AcmVmcy9oZWFkcy9haGVhZABjb21taXQACnJlZnMvaGVhZHMvYmVoaW5kADRlNjgyM2E2ZmJkMjI0NzlkN2FlMzIwOWVjYTNiZGQ5NmU5MTA1OWUAAHJlZnMvcmVtb3Rlcy9vcmlnaW4vYmVoaW5kACAAMTc5Mzg1MzY1MgAAYmVoaW5kIDMAb3JpZ2luAHJlZnMvaGVhZHMvYmVoaW5kAGNvbW1pdAAKcmVmcy9oZWFkcy9ib3RoADI4ODA0MDRjMjg4ZjU4MTRiZTRlZjZiZWU2YTEzOTExOWU3Yjk2N2QAAHJlZnMvcmVtb3Rlcy9vcmlnaW4vYm90aAAgADE3OTM4NTM2NTIAAGFoZWFkIDEsIGJlaGluZCAyAG9yaWdpbgByZWZzL2hlYWRzL2JvdGgAY29tbWl0AApyZWZzL2hlYWRzL2ZlYXQv7ZWc6riALeu4jOuenOy5mAA5NjkyOTQxZDdmYWQzMWYwYjYwMDFkZGRlZmYxN2YwMGUzOTZmN2FkAAAAIAAxNzkzODUzNjUyAAAAAABjb21taXQACnJlZnMvaGVhZHMvZ29uZQA5NjkyOTQxZDdmYWQzMWYwYjYwMDFkZGRlZmYxN2YwMGUzOTZmN2FkAAByZWZzL3JlbW90ZXMvb3JpZ2luL2dvbmUAIAAxNzkzODUzNjUyAABnb25lAG9yaWdpbgByZWZzL2hlYWRzL2dvbmUAY29tbWl0AApyZWZzL2hlYWRzL21haW4AOTY5Mjk0MWQ3ZmFkMzFmMGI2MDAxZGRkZWZmMTdmMDBlMzk2ZjdhZAAAcmVmcy9yZW1vdGVzL29yaWdpbi9tYWluACoAMTc5Mzg1MzY1MgAAAG9yaWdpbgByZWZzL2hlYWRzL21haW4AY29tbWl0AApyZWZzL2hlYWRzL25vLXVwc3RyZWFtADk2OTI5NDFkN2ZhZDMxZjBiNjAwMWRkZGVmZjE3ZjAwZTM5NmY3YWQAAAAgADE3OTM4NTM2NTIAAAAAAGNvbW1pdAAKcmVmcy9yZW1vdGVzL29yaWdpbi9IRUFEADk2OTI5NDFkN2ZhZDMxZjBiNjAwMWRkZGVmZjE3ZjAwZTM5NmY3YWQAAAAgADE3OTM4NTM2NTIAcmVmcy9yZW1vdGVzL29yaWdpbi9tYWluAAAAAGNvbW1pdAAKcmVmcy9yZW1vdGVzL29yaWdpbi9haGVhZAA5NjkyOTQxZDdmYWQzMWYwYjYwMDFkZGRlZmYxN2YwMGUzOTZmN2FkAAAAIAAxNzkzODUzNjUyAAAAAABjb21taXQACnJlZnMvcmVtb3Rlcy9vcmlnaW4vYmVoaW5kAGIzZjgyNDIyYzMwYzg3MTgyMmIyOTMwMzMzYzllN2JjYWE2NGU1ZGYAAAAgADE3OTM4NTM2NTIAAAAAAGNvbW1pdAAKcmVmcy9yZW1vdGVzL29yaWdpbi9ib3RoAGIzZjgyNDIyYzMwYzg3MTgyMmIyOTMwMzMzYzllN2JjYWE2NGU1ZGYAAAAgADE3OTM4NTM2NTIAAAAAAGNvbW1pdAAKcmVmcy9yZW1vdGVzL29yaWdpbi9tYWluADk2OTI5NDFkN2ZhZDMxZjBiNjAwMWRkZGVmZjE3ZjAwZTM5NmY3YWQAAAAgADE3OTM4NTM2NTIAAAAAAGNvbW1pdAAKcmVmcy90YWdzL2xpZ2h0LXRhZwA0ZTY4MjNhNmZiZDIyNDc5ZDdhZTMyMDllY2EzYmRkOTZlOTEwNTllAAAAIAAxNzkzODUzNjUyAAAAAABjb21taXQACnJlZnMvdGFncy92MQA0ZmEwMmExNmQ3OTY5N2UwMTQxZTk5YjIwNjY1ZmQ2YzlhOWVhNGY5ADk2OTI5NDFkN2ZhZDMxZjBiNjAwMWRkZGVmZjE3ZjAwZTM5NmY3YWQAACAAAAAAAAB0YWcAY29tbWl0Cg=="
        ) ?? Data()

    private let mainOID = "9692941d7fad31f0b6001dddeff17f00e396f7ad"
    private let oid = String(repeating: "ab", count: 20)
    private let date = Date(timeIntervalSince1970: 1_793_853_652)

    /// One record: twelve NUL-separated fields ending with LF, as git prints them.
    private func record(
        _ refname: String, _ objectname: String? = nil, peeled: String = "", upstream: String = "", head: String = " ",
        date: String = "1793853652", symref: String = "", track: String = "", remote: String = "",
        remoteRef: String = "", type: String? = nil, peeledType: String? = nil
    ) -> String {
        [
            refname, objectname ?? oid, peeled, upstream, head, date, symref, track, remote, remoteRef,
            type ?? (peeled.isEmpty ? "commit" : "tag"), peeledType ?? (peeled.isEmpty ? "" : "commit"),
        ]
        .joined(separator: "\u{0}") + "\n"
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
        XCTAssertEqual(listing.skippedRecords, 0)
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

    /// PAR-REF-08 (#432): `%(objecttype)` and `%(*objecttype)`. A tag of a tree or blob, lightweight or annotated,
    /// keeps its type and has no commit; older git's one-level peel of a tag of a tag is `tag`, not a commit.
    func testPARREF08_ObjectTypes() throws {
        let tree = String(repeating: "cd", count: 20)
        let listing = try parse(
            record("refs/tags/light-tree", tree, type: "tree"),
            record("refs/tags/light-blob", tree, type: "blob"),
            record("refs/tags/annotated-tree", oid, peeled: tree, peeledType: "tree"),
            record("refs/tags/nested", oid, peeled: tree, peeledType: "tag"),
            record("refs/tags/v1", oid, peeled: tree))
        let types = Dictionary(uniqueKeysWithValues: listing.tags.map { ($0.shortName, $0.objectType) })
        XCTAssertEqual(
            types, ["light-tree": .tree, "light-blob": .blob, "annotated-tree": .tree, "nested": .tag, "v1": .commit])
        for tag in listing.tags where tag.shortName != "v1" {
            XCTAssertNil(tag.commit, tag.shortName)
            XCTAssertEqual(tag.object, ObjectID(tree), tag.shortName)
        }
        XCTAssertEqual(listing.tags.first { $0.shortName == "v1" }?.commit, ObjectID(tree))
    }

    /// PAR-REF-08: an unknown type, or peeled fields that disagree with the type, shift nothing silently: the parse
    /// fails.
    func testPARREF08_ObjectTypeViolationsFail() {
        assertFails(record("refs/heads/x", type: "Commit"), reason: "invalid object type")
        assertFails(record("refs/heads/x", type: ""), reason: "invalid object type")
        assertFails(record("refs/tags/x", peeled: oid, peeledType: "bogus"), reason: "invalid object type")
        // A tag object without a peeled object, a non-tag with one, and a peeled type without a peeled name.
        assertFails(record("refs/tags/x", type: "tag"), reason: "peeled fields disagree with the object type")
        assertFails(
            record("refs/tags/x", peeled: oid, type: "commit"), reason: "peeled fields disagree with the object type")
        assertFails(record("refs/tags/x", peeledType: "commit"), reason: "peeled fields disagree with the object type")
        assertFails(
            record("refs/tags/x", peeled: oid, peeledType: ""), reason: "peeled fields disagree with the object type")
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

    func testPARREF03_UnrepresentableSymrefTargetBecomesNil() throws {
        var data = Data(record("refs/remotes/origin/HEAD", symref: "origin/main").utf8)
        data.append(Data(record("refs/remotes/up/HEAD", symref: "refs/remotes/-x").utf8))
        var invalidUTF8 = Data(record("refs/remotes/other/HEAD", symref: "refs/remotes/other/m").utf8)
        // Inside the symref, before the three empty fields, the two object types, and LF.
        invalidUTF8.insert(0xFF, at: invalidUTF8.count - "\u{0}\u{0}\u{0}\u{0}commit\u{0}\n".utf8.count - 1)
        data.append(invalidUTF8)
        let listing = try RefParser.parse(data)
        XCTAssertEqual(listing.branches.count, 3)
        XCTAssertEqual(listing.branches.map(\.symbolicTarget), [nil, nil, nil])
        XCTAssertEqual(listing.skippedRecords, 0)
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

    func testPARREF04_InvalidUTF8RefNameIsSkippedAndCounted() throws {
        // git allows such a name, but it must not be decoded lossily: it would name a different ref when passed back.
        var data = Data("refs/heads/bad".utf8)
        data.append(0xFF)
        data.append(Data(record("").utf8))
        data.append(Data(record("refs/heads/main").utf8))
        let listing = try RefParser.parse(data)
        XCTAssertEqual(listing.branches.map(\.fullName), ["refs/heads/main"])
        XCTAssertEqual(listing.skippedRecords, 1)
    }

    func testPARREF04_RefNamesThatCannotGoBackToGitAreSkippedAndCounted() throws {
        let unsafe = ["refs/heads/-x", "refs/heads/a..b", "refs/heads/x.lock", "refs/heads/a b", "refs/tags/-t"]
        let listing = try parse(record("refs/heads/ok"), unsafe.map { record($0) }.joined(), record("refs/tags/v1"))
        XCTAssertEqual(listing.branches.map(\.fullName), ["refs/heads/ok"])
        XCTAssertEqual(listing.tags.map(\.fullName), ["refs/tags/v1"])
        XCTAssertEqual(listing.skippedRecords, unsafe.count)
    }

    func testPARREF04_SkippedRecordsAreStillFormatChecked() {
        assertFails(record("refs/heads/-x", "bad"), reason: "invalid object name")
        assertFails(record("refs/heads/-x", head: "+"), reason: "invalid HEAD marker")
        assertFails(
            record("refs/heads/-x", upstream: "refs/remotes/origin/x", track: "ahead"), reason: "invalid upstream track"
        )
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

    func testPARREF05_UnrepresentableUpstreamSkipsTheRecord() throws {
        // Showing the branch as "no upstream" would be wrong, and its upstream cannot go back to git either.
        var invalidUTF8 = Data(record("refs/heads/c", upstream: "refs/remotes/origin/c", track: "ahead 1").utf8)
        let upstreamEnd = invalidUTF8.firstRange(of: Data("origin/c".utf8))!.upperBound
        invalidUTF8.insert(0xFF, at: upstreamEnd)
        var data = Data(record("refs/heads/a", upstream: "origin/a").utf8)
        data.append(Data(record("refs/heads/b", upstream: "refs/remotes/origin/-b", track: "gone").utf8))
        data.append(invalidUTF8)
        data.append(Data(record("refs/heads/main").utf8))
        let listing = try RefParser.parse(data)
        XCTAssertEqual(listing.branches.map(\.fullName), ["refs/heads/main"])
        XCTAssertEqual(listing.skippedRecords, 3)
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
            // The track is followed by the two empty remote fields, the two object types, and LF.
            let trackOffset = line.utf8.count - "\u{0}\u{0}\u{0}commit\u{0}\n".utf8.count - track.utf8.count
            assertFails(line, reason: "invalid upstream track", offset: trackOffset)
        }
    }

    /// `%(upstream:remotename)` and `%(upstream:remoteref)` (#115, ADR-0023 §4): kept whole for local branches, even
    /// with a `/` in the remote name or `.` for a local upstream; ignored on remote-tracking refs; not valid UTF-8 is
    /// `nil` without skipping the branch.
    func testPARREF07_UpstreamRemoteAndRemoteRef() throws {
        let listing = try parse(
            record(
                "refs/heads/feature", upstream: "refs/remotes/my/fork/topic", remote: "my/fork",
                remoteRef: "refs/heads/topic"),
            record("refs/heads/loc", upstream: "refs/heads/main", remote: ".", remoteRef: "refs/heads/main"),
            record("refs/heads/none"),
            record("refs/remotes/origin/x", remote: "origin", remoteRef: "refs/heads/x"))
        let feature = try branch("refs/heads/feature", in: listing)
        XCTAssertEqual(feature.upstreamRemote, "my/fork")
        XCTAssertEqual(feature.upstreamRemoteRef, "refs/heads/topic")
        XCTAssertEqual(try branch("refs/heads/loc", in: listing).upstreamRemote, ".")
        XCTAssertNil(try branch("refs/heads/none", in: listing).upstreamRemote)
        XCTAssertNil(try branch("refs/heads/none", in: listing).upstreamRemoteRef)
        XCTAssertNil(try branch("refs/remotes/origin/x", in: listing).upstreamRemote)

        let real = try RefParser.parse(Self.realOutput)
        XCTAssertEqual(try branch("refs/heads/ahead", in: real).upstreamRemote, "origin")
        XCTAssertEqual(try branch("refs/heads/gone", in: real).upstreamRemoteRef, "refs/heads/gone")
        XCTAssertNil(try branch("refs/heads/no-upstream", in: real).upstreamRemote)

        var invalid = Data(record("refs/heads/odd", upstream: "refs/remotes/origin/odd", remote: "origin").utf8)
        // At the end of the remote ref field, before the two object types.
        invalid.insert(contentsOf: [0xFF, 0xFE], at: invalid.count - "\u{0}commit\u{0}\n".utf8.count)
        let odd = try XCTUnwrap(RefParser.parse(invalid).branches.first)
        XCTAssertEqual(odd.upstreamRemote, "origin")
        XCTAssertNil(odd.upstreamRemoteRef)
    }

    // MARK: - Field formats (parsing-spec.md §1.6–§1.8)

    func testWrongFieldCountFails() {
        // The format before #54 had seven fields; reading it would shift every value.
        let seven = ["refs/heads/x", oid, "", "", " ", "1793853652", ""].joined(separator: "\u{0}") + "\n"
        assertFails(seven, reason: "expected 12 fields", offset: 0)
        let second = record("refs/heads/a")
        assertFails(second + record("refs/heads/b") + "\u{0}\n", reason: "expected 12 fields")
        assertFails(second + seven, reason: "expected 12 fields", offset: second.utf8.count)
        // The format before #115 had eight.
        let eight = ["refs/heads/x", oid, "", "", " ", "1793853652", "", ""].joined(separator: "\u{0}") + "\n"
        assertFails(eight, reason: "expected 12 fields", offset: 0)
        // The format before #432 had ten.
        let ten =
            record("refs/heads/x").split(separator: "\u{0}", omittingEmptySubsequences: false).prefix(10)
            .joined(separator: "\u{0}") + "\n"
        assertFails(ten, reason: "expected 12 fields", offset: 0)
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
        let listing = try parse(
            record("refs/notes/commits"), record("refs/heads/main"), record("refs/stash"), record("heads/main"),
            record("refs/notes/-x"))
        XCTAssertEqual(listing.branches.map(\.fullName), ["refs/heads/main"])
        XCTAssertTrue(listing.tags.isEmpty)
        XCTAssertEqual(listing.skippedRecords, 0, "ignored prefixes are not warnings")
    }

    func testEmptyOutput() throws {
        let listing = try RefParser.parse(Data())
        XCTAssertTrue(listing.branches.isEmpty)
        XCTAssertTrue(listing.tags.isEmpty)
        XCTAssertFalse(listing.isPartial)
        XCTAssertEqual(listing.skippedRecords, 0)
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

    /// PAR-REF-08 (#559): a branch keeps `%(objecttype)` too. A local or remote branch a hand-edited packed-refs
    /// points at a tree, blob, or tag object has no commit; its target stays the object git listed.
    func testPARREF08_BranchObjectTypes() throws {
        let tree = String(repeating: "cd", count: 20)
        let listing = try parse(
            record("refs/heads/tree", tree, type: "tree"),
            record("refs/remotes/origin/blob", tree, type: "blob"),
            record("refs/heads/tagged", oid, peeled: tree),
            record("refs/heads/main", tree))
        let types = Dictionary(uniqueKeysWithValues: listing.branches.map { ($0.shortName, $0.objectType) })
        XCTAssertEqual(types, ["tree": .tree, "origin/blob": .blob, "tagged": .tag, "main": .commit])
        for branch in listing.branches where branch.shortName != "main" {
            XCTAssertNil(branch.commit, branch.shortName)
        }
        XCTAssertEqual(listing.branches.first { $0.shortName == "tagged" }?.target, ObjectID(oid))
        XCTAssertEqual(listing.branches.first { $0.shortName == "main" }?.commit, ObjectID(tree))
    }
}
