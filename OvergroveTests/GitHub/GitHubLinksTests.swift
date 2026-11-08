import Foundation
import XCTest

@testable import Overgrove

/// Open on GitHub URLs (#398): only github.com, https, and paths assembled from validated parts.
final class GitHubLinksTests: XCTestCase {
    private let repository = GitHubRepository(owner: "acme", name: "api.v2")!
    private let oid = ObjectID(String(repeating: "a", count: 40))!

    private func path(_ text: String) -> GitPath { GitPath(text) }

    func testCommitAndBranch() throws {
        XCTAssertEqual(
            GitHubLinks.commit(repository, oid)?.absoluteString, "https://github.com/acme/api.v2/commit/" + oid.hex)
        XCTAssertEqual(
            GitHubLinks.branch(repository, remoteRef: "refs/remotes/origin/feat/42-rate-limit", remote: "origin")?
                .absoluteString,
            "https://github.com/acme/api.v2/tree/feat/42-rate-limit")
        XCTAssertNil(
            GitHubLinks.branch(repository, remoteRef: "refs/remotes/fork/main", remote: "origin"), "other remote")
        XCTAssertNil(GitHubLinks.branch(repository, remoteRef: "refs/remotes/origin/HEAD", remote: "origin"))
        XCTAssertNil(
            GitHubLinks.branch(repository, remoteRef: "refs/heads/main", remote: "origin"), "not remote-tracking")
        XCTAssertNil(
            GitHubLinks.branch(repository, remoteRef: "refs/remotes/origin/a..b", remote: "origin"), "invalid ref")
        // A remote name that is a prefix of another must not match it.
        XCTAssertNil(GitHubLinks.branch(repository, remoteRef: "refs/remotes/origin2/main", remote: "origin"))
    }

    /// Repository text cannot change the scheme, the host, add a query or a fragment, or climb out of the repository.
    func testHostilePathsStayInsideTheRepositoryPage() throws {
        let cases = [
            "src/a b.swift": "/acme/api.v2/blob/\(oid.hex)/src/a%20b.swift",
            "q?x=1#frag": "/acme/api.v2/blob/\(oid.hex)/q%3Fx=1%23frag",
            "pct%2e%2e/semi;x": "/acme/api.v2/blob/\(oid.hex)/pct%252e%252e/semi%3Bx",
            "ü/é.md": "/acme/api.v2/blob/\(oid.hex)/%C3%BC/%C3%A9.md",
            "//evil.example/x": "",
        ]
        for (text, expected) in cases {
            let url = GitHubLinks.file(repository, commit: oid, path: path(text))
            if expected.isEmpty {
                XCTAssertNil(url, "empty components are refused: \(text)")
                continue
            }
            let built = try XCTUnwrap(url, text)
            XCTAssertEqual(built.scheme, "https", text)
            XCTAssertEqual(built.host, "github.com", text)
            XCTAssertNil(built.query, text)
            XCTAssertNil(built.fragment, text)
            XCTAssertEqual(
                URLComponents(url: built, resolvingAgainstBaseURL: false)?.percentEncodedPath, expected, text)
            XCTAssertEqual(RowActions.browserTarget(built), .success(built))
        }
        for climbing in ["../x", "a/../../x", "./x"] {
            XCTAssertNil(GitHubLinks.file(repository, commit: oid, path: path(climbing)), climbing)
        }
    }

    func testRemoteRefOfABranchRow() {
        let remote = BranchRow(
            id: "refs/remotes/origin/main", name: "main", fullDisplayName: "origin/main", isCheckedOut: false,
            isDefault: false, ahead: 0, behind: 0, isUpstreamGone: false, date: nil, issueNumber: nil, help: "",
            accessibilityLabel: "")
        XCTAssertEqual(remote.remoteRef, "refs/remotes/origin/main")
        var local = BranchRow(
            id: "refs/heads/feat", name: "feat", fullDisplayName: "feat", isCheckedOut: false, isDefault: false,
            ahead: 0, behind: 0, isUpstreamGone: false, date: nil, issueNumber: nil, help: "", accessibilityLabel: "")
        XCTAssertNil(local.remoteRef, "no upstream")
        local.upstreamRef = "refs/remotes/origin/feat"
        XCTAssertEqual(local.remoteRef, "refs/remotes/origin/feat")
    }

    func testTheGitHubRemoteIsNamed() {
        let match = GitHubRemote.match(remotes: [
            (name: "origin", url: "https://github.com/me/api.git"),
            (name: "upstream", url: "git@github.com:acme/api.git"),
        ])
        XCTAssertEqual(match?.name, "upstream")
        XCTAssertEqual(match?.repository.slug, "acme/api")
    }
}
