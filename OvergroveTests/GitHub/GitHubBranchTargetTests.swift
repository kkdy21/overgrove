import Foundation
import XCTest

@testable import Overgrove

/// #406: a branch opens on GitHub in the repository of the remote it tracks, found without splitting refs on `/`.
final class GitHubBranchTargetTests: XCTestCase {
    private let fork = GitHubRepository(owner: "me", name: "app")!
    private let original = GitHubRepository(owner: "team", name: "app")!
    private let oid = ObjectID(String(repeating: "ab", count: 20))!

    private func local(_ name: String, remote: String?, merge: String?) -> Branch {
        Branch(
            fullName: "refs/heads/\(name)", kind: .local, target: oid,
            upstreamStatus: remote == nil ? .none : .tracking(upstream: "refs/remotes/x/\(name)", ahead: 0, behind: 0),
            isHead: false, committerDate: nil, symbolicTarget: nil, upstreamRemote: remote, upstreamRemoteRef: merge)
    }

    /// The fork flow: `origin` is my fork and the issue panel uses `upstream`; a branch tracking `origin` opens my fork.
    func testForkFlowOpensTheTrackedRemotesRepository() {
        let remotes = ["origin": fork, "upstream": original]
        XCTAssertEqual(
            GitHubBranchTarget.forLocal(
                local("feat/x", remote: "origin", merge: "refs/heads/feat/x"), remotes: remotes),
            GitHubBranchTarget(repository: fork, branch: "feat/x"))
        XCTAssertEqual(
            GitHubBranchTarget.forLocal(local("main", remote: "upstream", merge: "refs/heads/main"), remotes: remotes),
            GitHubBranchTarget(repository: original, branch: "main"))
        XCTAssertEqual(
            GitHubBranchTarget.forRemoteRef("refs/remotes/origin/feat/x", remotes: remotes),
            GitHubBranchTarget(repository: fork, branch: "feat/x"))
        XCTAssertEqual(
            GitHubBranchTarget.forRemoteRef("refs/remotes/upstream/main", remotes: remotes),
            GitHubBranchTarget(repository: original, branch: "main"))
    }

    /// The merge ref names the branch on GitHub, even when the local name differs.
    func testLocalBranchUsesTheMergeRef() {
        let target = GitHubBranchTarget.forLocal(
            local("my-work", remote: "origin", merge: "refs/heads/feat/42"), remotes: ["origin": fork])
        XCTAssertEqual(target?.branch, "feat/42")
    }

    func testNothingWithoutAGitHubUpstream() {
        let remotes = ["origin": fork]
        for branch in [
            local("a", remote: nil, merge: nil), local("a", remote: ".", merge: "refs/heads/main"),
            local("a", remote: "gitlab", merge: "refs/heads/a"), local("a", remote: "origin", merge: "refs/tags/v1"),
            local("a", remote: "origin", merge: "refs/heads/"), local("a", remote: "origin", merge: nil),
            local("a", remote: "origin", merge: "refs/heads/-x"),
            local("a", remote: "origin", merge: "refs/heads/a..b"),
        ] {
            XCTAssertNil(GitHubBranchTarget.forLocal(branch, remotes: remotes), "\(branch)")
        }
        var remoteKind = local("a", remote: "origin", merge: "refs/heads/a")
        remoteKind = Branch(
            fullName: "refs/remotes/origin/a", kind: .remote(remote: "origin"), target: oid, upstreamStatus: .none,
            isHead: false, committerDate: nil, symbolicTarget: nil, upstreamRemote: "origin",
            upstreamRemoteRef: "refs/heads/a")
        XCTAssertNil(GitHubBranchTarget.forLocal(remoteKind, remotes: remotes), "only local branches")
    }

    /// Remote names may contain `/`: the longest known remote name wins, and `HEAD` is not a branch.
    func testRemoteRefsMatchTheLongestRemoteName() {
        let remotes = ["my": original, "my/fork": fork]
        XCTAssertEqual(
            GitHubBranchTarget.forRemoteRef("refs/remotes/my/fork/topic", remotes: remotes),
            GitHubBranchTarget(repository: fork, branch: "topic"))
        XCTAssertEqual(
            GitHubBranchTarget.forRemoteRef("refs/remotes/my/topic", remotes: remotes),
            GitHubBranchTarget(repository: original, branch: "topic"))
        XCTAssertNil(GitHubBranchTarget.forRemoteRef("refs/remotes/my/fork/HEAD", remotes: remotes))
        XCTAssertNil(GitHubBranchTarget.forRemoteRef("refs/remotes/gitlab/main", remotes: remotes))
        XCTAssertNil(GitHubBranchTarget.forRemoteRef("refs/remotes/my/fork/", remotes: remotes))
        XCTAssertNil(GitHubBranchTarget.forRemoteRef("refs/heads/my/fork/topic", remotes: remotes))
        XCTAssertNil(GitHubBranchTarget.forRemoteRef("refs/remotes/my/fork/-x", remotes: remotes), "invalid ref")
    }

    /// Prefixes compare by bytes: an NFD spelling of a remote name is a different remote.
    func testRemoteNamesCompareByBytes() {
        let remotes = ["caf\u{E9}": fork]
        XCTAssertNil(GitHubBranchTarget.forRemoteRef("refs/remotes/cafe\u{301}/main", remotes: remotes))
        XCTAssertEqual(
            GitHubBranchTarget.forRemoteRef("refs/remotes/caf\u{E9}/main", remotes: remotes)?.repository, fork)
    }
}
