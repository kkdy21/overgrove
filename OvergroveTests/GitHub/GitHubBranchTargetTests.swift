import Foundation
import XCTest

@testable import Overgrove

/// git's default fetch refspec for each remote name (`+refs/heads/*:refs/remotes/<name>/*`), for tests (#490).
func standardFetchRefspecs(_ names: some Sequence<String>) -> [String: [String]] {
    Dictionary(names.map { ($0, ["+refs/heads/*:refs/remotes/\($0)/*"]) }, uniquingKeysWith: { first, _ in first })
}

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
            GitHubBranchTarget.forRemoteRef(
                "refs/remotes/origin/feat/x", remotes: remotes, configuredRemotes: [],
                fetchRefspecs: standardFetchRefspecs(Array(remotes.keys) + [])),
            GitHubBranchTarget(repository: fork, branch: "feat/x"))
        XCTAssertEqual(
            GitHubBranchTarget.forRemoteRef(
                "refs/remotes/upstream/main", remotes: remotes, configuredRemotes: [],
                fetchRefspecs: standardFetchRefspecs(Array(remotes.keys) + [])),
            GitHubBranchTarget(repository: original, branch: "main"))
    }

    /// #490: Open on GitHub only for a ref the remote's fetch refspec maps from `refs/heads/`. With GitHub's pull
    /// request refspec, `origin/pr/123` is not the branch `pr/123`; a remote without refspecs opens nothing.
    func testOnlyRefsFetchedFromBranchesOpenABranch() {
        let refspecs = [
            "origin": ["+refs/heads/*:refs/remotes/origin/*", "+refs/pull/*/head:refs/remotes/origin/pr/*"]
        ]
        XCTAssertNil(
            GitHubBranchTarget.forRemoteRef(
                "refs/remotes/origin/pr/123", remotes: ["origin": fork], configuredRemotes: ["origin"],
                fetchRefspecs: refspecs))
        XCTAssertEqual(
            GitHubBranchTarget.forRemoteRef(
                "refs/remotes/origin/main", remotes: ["origin": fork], configuredRemotes: ["origin"],
                fetchRefspecs: refspecs),
            GitHubBranchTarget(repository: fork, branch: "main"))
        XCTAssertEqual(
            GitHubBranchTarget.forRemoteRef(
                "refs/remotes/origin/b/x", remotes: ["origin": fork], configuredRemotes: ["origin"],
                fetchRefspecs: ["origin": ["+refs/heads/*:refs/remotes/origin/b/*"]]),
            GitHubBranchTarget(repository: fork, branch: "x"))
        XCTAssertNil(
            GitHubBranchTarget.forRemoteRef(
                "refs/remotes/origin/main", remotes: ["origin": fork], configuredRemotes: ["origin"], fetchRefspecs: [:]
            ))
    }

    /// SEC-T14-490-1: the branch now comes from a refspec the repository wrote. A source that is not a valid branch
    /// (`..`, `?`, a control character) opens nothing, and what passes stays a path inside the repository's page.
    func testSECT14_490_1_HostileRefspecsStayInsideTheRepository() throws {
        func target(_ refspec: String, _ ref: String = "refs/remotes/origin/x") -> GitHubBranchTarget? {
            GitHubBranchTarget.forRemoteRef(
                ref, remotes: ["origin": fork], configuredRemotes: ["origin"], fetchRefspecs: ["origin": [refspec]])
        }
        for refspec in [
            "+refs/heads/..*:refs/remotes/origin/*", "+refs/heads/?x=*:refs/remotes/origin/*",
            "+refs/heads/a\n*:refs/remotes/origin/*", "+refs/heads/*/..:refs/remotes/origin/*",
            "+refs/heads/ *:refs/remotes/origin/*", "+refs/heads/-*:refs/remotes/origin/*",
            "+refs/heads/.*:refs/remotes/origin/*", "+refs/heads/*:refs/remotes/origin/*/",
        ] {
            XCTAssertNil(target(refspec), refspec)
        }
        let encoded = try XCTUnwrap(target("+refs/heads/a%2F*:refs/remotes/origin/*"))
        XCTAssertEqual(encoded.branch, "a%2Fx")
        let url = try XCTUnwrap(GitHubLinks.tree(encoded))
        XCTAssertEqual(url.host, "github.com")
        XCTAssertEqual(url.absoluteString, "https://github.com/me/app/tree/a%252Fx")
        let hash = try XCTUnwrap(target("+refs/heads/x#*:refs/remotes/origin/*"))
        XCTAssertEqual(GitHubLinks.tree(hash)?.absoluteString, "https://github.com/me/app/tree/x%23x")
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

    /// #466: the longest configured remote decides, not the longest GitHub one. With `my` on GitHub and `my/fork`
    /// elsewhere, `refs/remotes/my/fork/topic` belongs to `my/fork` and opens nothing; it never opens `my`'s
    /// `tree/fork/topic`.
    func testTheLongestConfiguredRemoteDecidesEvenWhenItIsNotOnGitHub() {
        let remotes = ["my": original]
        XCTAssertNil(
            GitHubBranchTarget.forRemoteRef(
                "refs/remotes/my/fork/topic", remotes: remotes, configuredRemotes: ["my", "my/fork"],
                fetchRefspecs: standardFetchRefspecs(Array(remotes.keys) + ["my", "my/fork"])))
        XCTAssertEqual(
            GitHubBranchTarget.forRemoteRef(
                "refs/remotes/my/topic", remotes: remotes, configuredRemotes: ["my", "my/fork"],
                fetchRefspecs: standardFetchRefspecs(Array(remotes.keys) + ["my", "my/fork"])),
            GitHubBranchTarget(repository: original, branch: "topic"))
        // A GitHub remote missing from the configured list (a stale map) still counts.
        XCTAssertEqual(
            GitHubBranchTarget.forRemoteRef(
                "refs/remotes/my/topic", remotes: remotes, configuredRemotes: [],
                fetchRefspecs: standardFetchRefspecs(Array(remotes.keys) + [])),
            GitHubBranchTarget(repository: original, branch: "topic"))
    }

    /// Remote names may contain `/`: the longest known remote name wins, and `HEAD` is not a branch.
    func testRemoteRefsMatchTheLongestRemoteName() {
        let remotes = ["my": original, "my/fork": fork]
        XCTAssertEqual(
            GitHubBranchTarget.forRemoteRef(
                "refs/remotes/my/fork/topic", remotes: remotes, configuredRemotes: [],
                fetchRefspecs: standardFetchRefspecs(Array(remotes.keys) + [])),
            GitHubBranchTarget(repository: fork, branch: "topic"))
        XCTAssertEqual(
            GitHubBranchTarget.forRemoteRef(
                "refs/remotes/my/topic", remotes: remotes, configuredRemotes: [],
                fetchRefspecs: standardFetchRefspecs(Array(remotes.keys) + [])),
            GitHubBranchTarget(repository: original, branch: "topic"))
        XCTAssertNil(
            GitHubBranchTarget.forRemoteRef(
                "refs/remotes/my/fork/HEAD", remotes: remotes, configuredRemotes: [],
                fetchRefspecs: standardFetchRefspecs(Array(remotes.keys) + [])))
        XCTAssertNil(
            GitHubBranchTarget.forRemoteRef(
                "refs/remotes/gitlab/main", remotes: remotes, configuredRemotes: [],
                fetchRefspecs: standardFetchRefspecs(Array(remotes.keys) + [])))
        XCTAssertNil(
            GitHubBranchTarget.forRemoteRef(
                "refs/remotes/my/fork/", remotes: remotes, configuredRemotes: [],
                fetchRefspecs: standardFetchRefspecs(Array(remotes.keys) + [])))
        XCTAssertNil(
            GitHubBranchTarget.forRemoteRef(
                "refs/heads/my/fork/topic", remotes: remotes, configuredRemotes: [],
                fetchRefspecs: standardFetchRefspecs(Array(remotes.keys) + [])))
        XCTAssertNil(
            GitHubBranchTarget.forRemoteRef(
                "refs/remotes/my/fork/-x", remotes: remotes, configuredRemotes: [],
                fetchRefspecs: standardFetchRefspecs(Array(remotes.keys) + [])),
            "invalid ref")
    }

    /// Prefixes compare by bytes: an NFD spelling of a remote name is a different remote.
    func testRemoteNamesCompareByBytes() {
        let remotes = ["caf\u{E9}": fork]
        XCTAssertNil(
            GitHubBranchTarget.forRemoteRef(
                "refs/remotes/cafe\u{301}/main", remotes: remotes, configuredRemotes: [],
                fetchRefspecs: standardFetchRefspecs(Array(remotes.keys) + [])))
        XCTAssertEqual(
            GitHubBranchTarget.forRemoteRef(
                "refs/remotes/caf\u{E9}/main", remotes: remotes, configuredRemotes: [],
                fetchRefspecs: standardFetchRefspecs(Array(remotes.keys) + []))?
                .repository, fork)
    }

    /// SEC-T9-546-1 (#546): a local branch's upstream remote is matched byte for byte. `branch.<b>.remote` spelled
    /// with KELVIN SIGN (U+212A) or in NFD is not the GitHub remote spelled in ASCII or NFC, though Swift's `String`
    /// equality says they are equal.
    func testSECT9_546_1_LocalUpstreamRemoteComparesByBytes() {
        XCTAssertEqual("\u{212A}", "K", "precondition: String equality folds canonical equivalence")
        let remotes = ["K": fork, "caf\u{E9}": original]
        for spoofed in ["\u{212A}", "cafe\u{301}"] {
            XCTAssertNil(
                GitHubBranchTarget.forLocal(local("a", remote: spoofed, merge: "refs/heads/a"), remotes: remotes),
                spoofed.unicodeScalars.map { String($0.value, radix: 16) }.joined(separator: " "))
        }
        XCTAssertEqual(
            GitHubBranchTarget.forLocal(local("a", remote: "K", merge: "refs/heads/a"), remotes: remotes)?.repository,
            fork)
        XCTAssertEqual(
            GitHubBranchTarget.forLocal(local("a", remote: "caf\u{E9}", merge: "refs/heads/a"), remotes: remotes)?
                .repository, original)
        // Both spellings configured: `repositories` keeps one of them (String keys fold), and neither upstream reaches
        // the other spelling's repository.
        let both = GitHubRemote.repositories(remotes: [
            (name: "\u{212A}", url: "https://github.com/evil/app"), (name: "K", url: "https://github.com/me/app"),
        ])
        XCTAssertEqual(both.count, 1)
        XCTAssertNil(
            GitHubBranchTarget.forLocal(local("a", remote: "K", merge: "refs/heads/a"), remotes: both),
            "ASCII K never opens the KELVIN SIGN remote's repository")
        XCTAssertEqual(
            GitHubBranchTarget.forLocal(local("a", remote: "\u{212A}", merge: "refs/heads/a"), remotes: both)?
                .repository.owner, "evil")
        // The stored key is the non-ASCII one: an ASCII upstream does not reach it either.
        XCTAssertNil(
            GitHubBranchTarget.forLocal(local("a", remote: "K", merge: "refs/heads/a"), remotes: ["\u{212A}": fork]))
    }
}
