import Foundation
import XCTest

@testable import Overgrove

/// PAR-GH-01…04 (parsing-spec.md §10).
final class GHParsersTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testPARGH01_LoggedIn() throws {
        let json = """
            {"hosts":{"github.com":[{"active":false,"state":"success","login":"old"},\
            {"active":true,"gitProtocol":"https","host":"github.com","login":"octo-cat","scopes":"repo",\
            "state":"success","tokenSource":"keyring"}]}}
            """
        XCTAssertEqual(try GHAuthParser.parse(data(json)), .loggedIn(login: "octo-cat"))
    }

    func testPARGH02_NotLoggedIn() throws {
        XCTAssertEqual(try GHAuthParser.parse(data(#"{"hosts":{}}"#)), .notLoggedIn)
        let failed = #"{"hosts":{"github.com":[{"active":true,"state":"error","login":"octo-cat"}]}}"#
        XCTAssertEqual(try GHAuthParser.parse(data(failed)), .notLoggedIn)
        let otherHost = #"{"hosts":{"ghe.example":[{"active":true,"state":"success","login":"me"}]}}"#
        XCTAssertEqual(try GHAuthParser.parse(data(otherHost)), .notLoggedIn)
    }

    func testPARGH02_SuspiciousLoginIsRejected() {
        let json = #"{"hosts":{"github.com":[{"active":true,"state":"success","login":"a b;rm"}]}}"#
        XCTAssertThrowsError(try GHAuthParser.parse(data(json)))
    }

    func testPARGH03_IssueList() throws {
        let json = """
            [{"number":12,"title":"feat: worktree list","state":"OPEN",\
            "labels":[{"name":"type:feature","color":"1f6feb","id":"x"}],"assignees":[{"login":"octo-cat","id":"y"}],\
            "updatedAt":"2026-11-05T06:11:06Z","url":"https://github.com/kkdy21/overgrove/issues/12"},\
            {"number":13,"title":"docs: x","state":"CLOSED","updatedAt":"2026-11-05T06:11:06.123Z",\
            "url":"https://github.com/kkdy21/overgrove/issues/13"}]
            """
        let issues = try IssueParser.parse(data(json))
        XCTAssertEqual(issues.map(\.number), [12, 13])
        XCTAssertEqual(issues[0].labels, [Issue.Label(name: "type:feature", color: "1f6feb")])
        XCTAssertEqual(issues[0].assignees, ["octo-cat"])
        XCTAssertEqual(issues[1].state, .closed)
        XCTAssertEqual(issues[1].labels, [], "missing optional fields become empty")
        XCTAssertEqual(try IssueParser.parse(data("[]")), [])
    }

    func testPARGH04_UnexpectedJSONFails() {
        let bad = [
            #"{"not":"an array"}"#,
            #"[{"title":"missing number","state":"OPEN","updatedAt":"2026-11-05T06:11:06Z","url":"https://github.com/a/b/issues/1"}]"#,
            #"[{"number":1,"title":"t","state":"MERGED","updatedAt":"2026-11-05T06:11:06Z","url":"https://github.com/a/b/issues/1"}]"#,
            #"[{"number":1,"title":"t","state":"OPEN","updatedAt":"yesterday","url":"https://github.com/a/b/issues/1"}]"#,
            #"[{"number":1,"title":"t","state":"OPEN","updatedAt":"2026-11-05T06:11:06Z","url":"https://evil.example/x"}]"#,
            "not json",
        ]
        for json in bad {
            XCTAssertThrowsError(try IssueParser.parse(data(json)), json)
        }
        XCTAssertThrowsError(try GHAuthParser.parse(data("[]")))
    }
}
