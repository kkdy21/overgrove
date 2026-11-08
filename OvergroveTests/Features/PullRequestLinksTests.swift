import Foundation
import XCTest

@testable import Overgrove

/// SEC-T9-06 (ADR-0023 §4): a pull request is tied to a local branch only when the head owner, head repository, and
/// head branch all match the branch's configured upstream, never by branch name alone.
final class PullRequestLinksTests: XCTestCase {
    static let oid = ObjectID(String(repeating: "ab", count: 20))!

    static func branch(
        _ name: String, remote: String? = "origin", remoteRef: String? = nil, local: Bool = true
    ) -> Branch {
        Branch(
            fullName: local ? "refs/heads/\(name)" : "refs/remotes/origin/\(name)",
            kind: local ? .local : .remote(remote: "origin"), target: oid,
            upstreamStatus: remote == nil ? .none : .tracking(upstream: "refs/remotes/x/\(name)", ahead: 0, behind: 0),
            isHead: false, committerDate: nil, symbolicTarget: nil,
            upstreamRemote: remote, upstreamRemoteRef: remote == nil ? nil : (remoteRef ?? "refs/heads/\(name)"))
    }

    static func pullRequest(
        _ number: Int, owner: String = "team", name: String = "app", branch: String = "feat/42",
        state: PullRequest.State = .open, updated: TimeInterval = 0, hasHead: Bool = true
    ) -> PullRequest {
        PullRequest(
            number: number, title: "PR \(number)", state: state, isDraft: false,
            head: hasHead ? PullRequest.Head(owner: owner, name: name, branch: branch) : nil, baseRefName: "main",
            reviewDecision: .none, updatedAt: Date(timeIntervalSince1970: updated),
            url: URL(string: "https://github.com/team/app/pull/\(number)")!)
    }

    private let team = GitHubRepository(owner: "team", name: "app")!
    private let fork = GitHubRepository(owner: "me", name: "app")!

    private func index(_ pullRequests: [PullRequest], _ branches: [Branch], remotes: [String: GitHubRepository]? = nil)
        -> PullRequestLinkIndex
    {
        PullRequestLinkIndex(pullRequests: pullRequests, branches: branches, remotes: remotes ?? ["origin": team])
    }

    func testSameRepositoryBranchIsLinked() {
        let links = index([Self.pullRequest(5)], [Self.branch("feat/42")])
        XCTAssertEqual(links.pullRequest(forBranch: "refs/heads/feat/42")?.number, 5)
    }

    /// The core rule: a fork PR whose head branch has the same name as mine is not mine.
    func testSECT9_06_SameNameForkPRIsNotLinked() {
        let impostor = Self.pullRequest(9, owner: "attacker", name: "app", branch: "feat/42")
        let renamed = Self.pullRequest(10, owner: "team", name: "app-fork", branch: "feat/42")
        let links = index([impostor, renamed], [Self.branch("feat/42")])
        XCTAssertNil(links.pullRequest(forBranch: "refs/heads/feat/42"))
        XCTAssertTrue(links.isEmpty)
    }

    /// The fork flow: `origin` is my fork, the PR is on `upstream`; the head is my fork.
    func testSECT9_06_ForkFlowMatchesTheForkRemote() {
        let mine = Self.pullRequest(11, owner: "me", name: "app", branch: "feat/42")
        let theirs = Self.pullRequest(12, owner: "team", name: "app", branch: "feat/42")
        let links = index([theirs, mine], [Self.branch("feat/42")], remotes: ["origin": fork, "upstream": team])
        XCTAssertEqual(links.pullRequest(forBranch: "refs/heads/feat/42")?.number, 11)
    }

    func testSECT9_06_OwnerAndNameIgnoreASCIICaseButBranchIsExact() {
        let links = index(
            [Self.pullRequest(1, owner: "TEAM", name: "App", branch: "feat/42")],
            [Self.branch("feat/42"), Self.branch("Feat/42", remoteRef: "refs/heads/FEAT/42")])
        XCTAssertEqual(links.pullRequest(forBranch: "refs/heads/feat/42")?.number, 1)
        XCTAssertNil(links.pullRequest(forBranch: "refs/heads/Feat/42"), "branch case matters")
        // Non-ASCII look-alikes are not folded: `ｔeam` (full-width t) is someone else.
        XCTAssertTrue(index([Self.pullRequest(2, owner: "\u{FF54}eam")], [Self.branch("feat/42")]).isEmpty)
    }

    /// Branch names compare by bytes: NFC and NFD spellings are different branches to git.
    func testSECT9_06_BranchNamesCompareByBytes() {
        let nfc = "feat/\u{E9}t\u{E9}"
        let nfd = "feat/e\u{301}te\u{301}"
        let links = index([Self.pullRequest(3, branch: nfd)], [Self.branch(nfc)])
        XCTAssertNil(links.pullRequest(forBranch: "refs/heads/\(nfc)"))
        XCTAssertEqual(
            index([Self.pullRequest(3, branch: nfd)], [Self.branch(nfd)])
                .pullRequest(forBranch: "refs/heads/\(nfd)")?.number, 3)
    }

    /// The remote ref is matched, not the local name: `local-name` tracking `refs/heads/feat/42` is linked.
    func testSECT9_06_UpstreamRefNotLocalNameIsMatched() {
        let links = index(
            [Self.pullRequest(4)],
            [
                Self.branch("local-name", remoteRef: "refs/heads/feat/42"),
                Self.branch("feat/42", remoteRef: "refs/heads/x"),
            ])
        XCTAssertEqual(links.pullRequest(forBranch: "refs/heads/local-name")?.number, 4)
        XCTAssertNil(links.pullRequest(forBranch: "refs/heads/feat/42"))
    }

    /// A remote name with `/` is looked up whole; the remote-tracking ref is never split.
    func testSECT9_06_RemoteNameWithSlash() {
        let links = index(
            [Self.pullRequest(6, owner: "me")], [Self.branch("feat/42", remote: "my/fork")],
            remotes: ["my": team, "my/fork": fork])
        XCTAssertEqual(links.pullRequest(forBranch: "refs/heads/feat/42")?.number, 6)
    }

    func testSECT9_06_NothingIsLinkedWithoutAMatchingUpstream() {
        let pullRequests = [Self.pullRequest(1)]
        // No upstream, a local upstream (`.`), a remote that is not github.com, a ref outside refs/heads.
        for branch in [
            Self.branch("feat/42", remote: nil), Self.branch("feat/42", remote: "."),
            Self.branch("feat/42", remote: "gitlab"), Self.branch("feat/42", remoteRef: "refs/tags/feat/42"),
            Self.branch("feat/42", remoteRef: "refs/heads/"), Self.branch("feat/42", local: false),
        ] {
            XCTAssertTrue(index(pullRequests, [branch]).isEmpty, "\(branch)")
        }
    }

    /// A PR without a head (a deleted fork) links to nothing and does not hide the others.
    func testSECT9_06_HeadlessPRIsSkipped() {
        let links = index(
            [Self.pullRequest(1, hasHead: false), Self.pullRequest(2, branch: "other")],
            [Self.branch("feat/42"), Self.branch("other")])
        XCTAssertNil(links.pullRequest(forBranch: "refs/heads/feat/42"))
        XCTAssertEqual(links.pullRequest(forBranch: "refs/heads/other")?.number, 2)
    }

    /// Several PRs from the same head: open first, then the latest update, then the higher number.
    func testPreferredPullRequest() {
        let closedNewer = Self.pullRequest(1, state: .merged, updated: 300)
        let openOlder = Self.pullRequest(2, state: .open, updated: 100)
        let openNewer = Self.pullRequest(3, state: .open, updated: 200)
        XCTAssertEqual(
            index([closedNewer, openOlder, openNewer], [Self.branch("feat/42")])
                .pullRequest(forBranch: "refs/heads/feat/42")?.number, 3)
        XCTAssertEqual(
            index(
                [Self.pullRequest(4, state: .merged, updated: 1), Self.pullRequest(5, state: .closed, updated: 2)],
                [Self.branch("feat/42")]
            )
            .pullRequest(forBranch: "refs/heads/feat/42")?.number, 5)
        XCTAssertEqual(
            index([Self.pullRequest(7, updated: 1), Self.pullRequest(8, updated: 1)], [Self.branch("feat/42")])
                .pullRequest(forBranch: "refs/heads/feat/42")?.number, 8)
    }

    func testGitHubRemotesByName() {
        let remotes = GitHubRemote.repositories(remotes: [
            (name: "origin", url: "git@github.com:me/app.git"),
            (name: "upstream", url: "https://github.com/team/app"),
            (name: "gitlab", url: "https://gitlab.com/team/app"),
            (name: "origin", url: "https://github.com/other/x"),
        ])
        XCTAssertEqual(remotes, ["origin": fork, "upstream": team])
    }
}
