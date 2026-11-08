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

    /// ADR-0025 §1: every host gh lists an account for, lowercased; a key that is not a DNS name is left out.
    func testPARGH01_ReportListsLoggedInHosts() throws {
        let json = """
            {"hosts":{"github.com":[{"active":true,"state":"success","login":"octo-cat"}],\
            "GHE.example":[{"active":true,"state":"success","login":"me"}],\
            "broken.example":[{"active":true,"state":"error","login":"me"}],"empty.example":[],\
            "127.0.0.1":[{"active":true,"state":"success","login":"x"}],"-x.example":[{"active":true}]}}
            """
        let report = try GHAuthParser.parseReport(data(json))
        XCTAssertEqual(report.status, .loggedIn(login: "octo-cat"))
        XCTAssertEqual(Set(report.hosts.map(\.name)), ["github.com", "ghe.example", "broken.example"])
        let gheOnly = try GHAuthParser.parseReport(
            data(#"{"hosts":{"ghe.example":[{"active":true,"state":"success","login":"me"}]}}"#))
        XCTAssertEqual(gheOnly.status, .notLoggedIn)
        XCTAssertEqual(gheOnly.hosts.map(\.name), ["ghe.example"])
    }

    /// SEC-T9-09 (parse): issue and PR URLs must be https on the repository's own host.
    func testSECT9_09_URLsMustBeOnTheRepositorysHost() throws {
        let ghe = try XCTUnwrap(RemoteHost("ghe.example"))
        func issue(_ url: String) -> Data {
            data(#"[{"number":1,"title":"t","state":"OPEN","updatedAt":"2026-11-05T06:11:06Z","url":"\#(url)"}]"#)
        }
        XCTAssertEqual(try IssueParser.parse(issue("https://ghe.example/a/b/issues/1"), host: ghe).count, 1)
        for url in [
            "https://github.com/a/b/issues/1", "http://ghe.example/a/b/issues/1",
            "https://ghe.example.evil/a/b/issues/1",
        ] {
            XCTAssertThrowsError(try IssueParser.parse(issue(url), host: ghe), url)
        }
        XCTAssertThrowsError(try IssueParser.parse(issue("https://ghe.example/a/b/issues/1")))
        func pull(_ url: String) -> Data { data(#"[{"number":1,"state":"OPEN","url":"\#(url)"}]"#) }
        XCTAssertEqual(try PullRequestParser.parse(pull("https://ghe.example/a/b/pull/1"), host: ghe).count, 1)
        XCTAssertEqual(try PullRequestParser.parse(pull("https://github.com/a/b/pull/1"), host: ghe).count, 0)
        XCTAssertEqual(try PullRequestParser.parse(pull("https://ghe.example/a/b/pull/1")).count, 0)
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
