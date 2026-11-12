import XCTest

@testable import Overgrove

/// Which branch on the remote a remote-tracking ref holds, read from the remote's fetch refspecs (#490).
final class FetchRefspecTests: XCTestCase {
    private func branch(_ ref: String, _ refspecs: [String]) -> String? {
        FetchRefspec.sourceBranch(of: ref, refspecs: refspecs)
    }

    func testTheDefaultRefspecMapsEveryBranch() {
        let standard = ["+refs/heads/*:refs/remotes/origin/*"]
        XCTAssertEqual(branch("refs/remotes/origin/main", standard), "main")
        XCTAssertEqual(branch("refs/remotes/origin/feat/x", standard), "feat/x")
        XCTAssertEqual(branch("refs/remotes/origin/main", ["refs/heads/*:refs/remotes/origin/*"]), "main", "no +")
    }

    /// The issue's case: `origin/pr/123` comes from `refs/pull/123/head`, not a branch named `pr/123`.
    func testANonBranchSourceIsNotABranch() {
        let refspecs = ["+refs/heads/*:refs/remotes/origin/*", "+refs/pull/*/head:refs/remotes/origin/pr/*"]
        XCTAssertNil(branch("refs/remotes/origin/pr/123", refspecs))
        XCTAssertEqual(branch("refs/remotes/origin/main", refspecs), "main")
        XCTAssertNil(branch("refs/remotes/origin/v1", ["+refs/tags/*:refs/remotes/origin/*"]))
        XCTAssertNil(
            branch("refs/remotes/origin/main", ["+main:refs/remotes/origin/main"]), "a short source is not sure")
    }

    func testRenamedAndExactMappings() {
        XCTAssertEqual(branch("refs/remotes/origin/b/x", ["+refs/heads/*:refs/remotes/origin/b/*"]), "x")
        XCTAssertNil(branch("refs/remotes/origin/x", ["+refs/heads/*:refs/remotes/origin/b/*"]))
        XCTAssertEqual(
            branch("refs/remotes/origin/stable", ["refs/heads/release/2:refs/remotes/origin/stable"]), "release/2")
        XCTAssertEqual(branch("refs/remotes/o/f-x", ["+refs/heads/feat-*:refs/remotes/o/f-*"]), "feat-x")
        XCTAssertEqual(branch("refs/remotes/o/a/x/b", ["refs/heads/p/*/q:refs/remotes/o/a/*/b"]), "p/x/q")
    }

    /// Negative refspecs, no destination, and two sources for one ref open nothing.
    func testNegativeMissingAndAmbiguousRefspecs() {
        let standard = "+refs/heads/*:refs/remotes/origin/*"
        XCTAssertNil(branch("refs/remotes/origin/secret", [standard, "^refs/heads/secret"]))
        XCTAssertNil(branch("refs/remotes/origin/tmp/a", [standard, "^refs/heads/tmp/*"]))
        XCTAssertEqual(branch("refs/remotes/origin/main", [standard, "^refs/heads/tmp/*"]), "main")
        XCTAssertNil(branch("refs/remotes/origin/main", ["refs/heads/main"]), "fetched to FETCH_HEAD only")
        XCTAssertNil(branch("refs/remotes/origin/main", ["refs/heads/main:"]))
        XCTAssertNil(branch("refs/remotes/origin/x", [standard, "+refs/heads/other/*:refs/remotes/origin/*"]))
        XCTAssertEqual(branch("refs/remotes/origin/x", [standard, standard]), "x", "the same source twice is one")
        XCTAssertNil(branch("refs/remotes/origin/x", []))
        XCTAssertNil(branch("refs/remotes/origin/x", ["+refs/heads/**:refs/remotes/origin/*"]), "malformed")
        XCTAssertNil(branch("refs/remotes/origin/x", ["+refs/heads/*:refs/remotes/origin/x"]), "one-sided glob")
        XCTAssertNil(branch("refs/remotes/origin/", [standard]), "an empty branch")
    }
}
