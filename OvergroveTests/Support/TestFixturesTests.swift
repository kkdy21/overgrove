import Foundation
import XCTest

@testable import Overgrove

/// #312: a fixture the code under test rejects fails the one test that built it; the host keeps running.
final class TestFixturesTests: XCTestCase {
    func testRejectedPatchFailsTheTestInsteadOfCrashing() {
        var listing: PatchParser.Listing?
        XCTExpectFailure("a rejected fixture patch is a test failure") {
            listing = TestFixtures.patch("not a diff\n")
        }
        XCTAssertEqual(listing, PatchParser.Listing(files: [], isPartial: false))
    }

    func testValidFixturesPassThrough() {
        let listing = TestFixtures.patch("diff --git a/a b/a\n--- a/a\n+++ b/a\n@@ -1 +1 @@\n-x\n+y\n")
        XCTAssertEqual(listing.files.count, 1)
        XCTAssertFalse(TestFixtures.arguments(.worktreeDiff(path: GitPath("f"), staged: false)).isEmpty)
    }
}
