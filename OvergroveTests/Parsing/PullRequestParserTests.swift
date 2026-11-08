import Foundation
import XCTest

@testable import Overgrove

/// PAR-GH-05/06 (parsing-spec.md §10.3) and the parsing half of SEC-T9-07 (ADR-0023 §3).
final class PullRequestParserTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    /// The shape gh 2.95.0 prints for `GHCommand.prList` (owner `name` and node ids are extra fields we ignore).
    static func entry(
        _ number: Int, state: String = "OPEN", isDraft: Bool = false, owner: String? = "team", name: String? = "app",
        branch: String? = "feat/42-rate-limit", review: String = "", updatedAt: String = "2026-11-08T03:14:08Z",
        title: String = "feat: rate limit", url: String? = nil
    ) -> String {
        let ownerJSON = owner.map { #"{"id":"U_1","login":"\#($0)","name":"Someone"}"# } ?? "null"
        let repositoryJSON = name.map { #"{"id":"R_1","name":"\#($0)","nameWithOwner":"x/\#($0)"}"# } ?? "null"
        let branchJSON = branch.map { #""\#($0)""# } ?? "null"
        let urlText = url ?? "https://github.com/team/app/pull/\(number)"
        return #"{"baseRefName":"main","headRefName":\#(branchJSON),"headRepository":\#(repositoryJSON),"#
            + #""headRepositoryOwner":\#(ownerJSON),"isCrossRepository":false,"isDraft":\#(isDraft),"#
            + #""mergedAt":null,"number":\#(number),"reviewDecision":"\#(review)","state":"\#(state)","#
            + #""title":"\#(title)","updatedAt":"\#(updatedAt)","url":"\#(urlText)"}"#
    }

    func testPARGH05_PullRequestList() throws {
        let json =
            "[" + Self.entry(400, review: "APPROVED") + ","
            + Self.entry(396, state: "MERGED", review: "CHANGES_REQUESTED", updatedAt: "2026-11-08T03:13:41.123Z")
            + "," + Self.entry(395, state: "CLOSED", isDraft: true, review: "REVIEW_REQUIRED") + "]"
        let list = try PullRequestParser.parse(data(json))
        XCTAssertEqual(list.map(\.number), [400, 396, 395])
        XCTAssertEqual(list.map(\.state), [.open, .merged, .closed])
        XCTAssertEqual(list.map(\.reviewDecision), [.approved, .changesRequested, .reviewRequired])
        XCTAssertEqual(list[0].head, PullRequest.Head(owner: "team", name: "app", branch: "feat/42-rate-limit"))
        XCTAssertEqual(list[0].baseRefName, "main")
        XCTAssertEqual(list[0].updatedAt, Date(timeIntervalSince1970: 1_794_107_648))
        XCTAssertNotNil(list[1].updatedAt, "fractional seconds")
        XCTAssertTrue(list[2].isDraft)
        XCTAssertEqual(list[0].url.absoluteString, "https://github.com/team/app/pull/400")
        XCTAssertEqual(try PullRequestParser.parse(data("[]")), [])
    }

    /// Unknown values degrade instead of failing: a new state is `unknown`, a new review decision is none.
    func testPARGH05_UnknownValuesDegrade() throws {
        let list = try PullRequestParser.parse(data("[" + Self.entry(1, state: "QUEUED", review: "SOMETHING") + "]"))
        XCTAssertEqual(list.first?.state, .unknown)
        XCTAssertEqual(list.first?.reviewDecision, PullRequest.ReviewDecision.none)
    }

    func testPARGH06_OnlyANonArrayFailsTheList() {
        for json in [#"{"not":"an array"}"#, "not json", "", "null", #"[{"number":1"#] {
            XCTAssertThrowsError(try PullRequestParser.parse(data(json)), json) { error in
                XCTAssertEqual((error as? ParseError)?.parser, "PullRequestParser")
            }
        }
    }

    /// SEC-T9-07 (parsing): anyone can open a PR on a public repository, so one hostile entry drops only itself. An
    /// entry without a usable number, state, or github.com URL is dropped; a non-object entry too.
    func testSECT9_07_OneBadEntryDropsOnlyItself() throws {
        let good = Self.entry(7)
        let bad = [
            #"{"title":"no number","state":"OPEN","url":"https://github.com/team/app/pull/1"}"#,
            #"{"number":"1","state":"OPEN","url":"https://github.com/team/app/pull/1"}"#,
            #"{"number":1.5,"state":"OPEN","url":"https://github.com/team/app/pull/1"}"#,
            #"{"number":0,"state":"OPEN","url":"https://github.com/team/app/pull/0"}"#,
            #"{"number":-3,"state":"OPEN","url":"https://github.com/team/app/pull/3"}"#,
            #"{"number":1,"url":"https://github.com/team/app/pull/1"}"#,
            #"{"number":1,"state":"OPEN"}"#,
            Self.entry(1, url: "https://evil.example/team/app/pull/1"),
            Self.entry(1, url: "http://github.com/team/app/pull/1"),
            #"{"number":true,"state":"OPEN","url":"https://github.com/team/app/pull/1"}"#,
            "42", "null", #""text""#, "[]",
        ]
        for entry in bad {
            let list = try PullRequestParser.parse(data("[" + entry + "," + good + "]"))
            XCTAssertEqual(list.map(\.number), [7], entry)
        }
    }

    /// SEC-T9-07 (parsing): a missing, null, or empty head repository, owner, or branch (a deleted fork) keeps the PR
    /// listed with no head, so it is linked to nothing; it does not fail the list.
    func testSECT9_07_MissingHeadKeepsThePRWithoutAHead() throws {
        let entries = [
            Self.entry(1, owner: nil), Self.entry(2, name: nil), Self.entry(3, branch: nil),
            Self.entry(4, owner: ""), Self.entry(5, name: ""), Self.entry(6, branch: ""),
            #"{"number":8,"state":"OPEN","url":"https://github.com/team/app/pull/8"}"#,
            #"{"number":9,"state":"OPEN","url":"https://github.com/team/app/pull/9","headRepository":"x","#
                + #""headRepositoryOwner":["y"],"headRefName":12,"title":null,"isDraft":"yes","updatedAt":5}"#,
        ]
        let list = try PullRequestParser.parse(data("[" + entries.joined(separator: ",") + "]"))
        XCTAssertEqual(list.map(\.number), [1, 2, 3, 4, 5, 6, 8, 9])
        XCTAssertTrue(list.allSatisfy { $0.head == nil })
        XCTAssertEqual(list.last?.title, "")
        XCTAssertEqual(list.last?.isDraft, false)
        XCTAssertNil(list.last?.updatedAt)
    }

    /// Titles and names are kept raw here (escaped when shown); control and bidi characters do not break parsing.
    func testHostileTextIsKeptRawForEscapingLater() throws {
        let title = #"evil‮txt.exe\u0007\n"#
        let list = try PullRequestParser.parse(
            data("[" + Self.entry(3, branch: #"feat/‮x"#, title: title) + "]"))
        XCTAssertEqual(list.first?.title, "evil\u{202E}txt.exe\u{7}\n")
        XCTAssertEqual(list.first?.head?.branch, "feat/\u{202E}x")
    }
}
