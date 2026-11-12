import Foundation
import XCTest

@testable import Overgrove

/// Safety and fetch-refusal reasons (#495): each has an English report value, which Copy Report and the tests use, and
/// a localized display value for the screen.
final class SafetyReasonTests: XCTestCase {
    private static let reasons = [
        SafetyReason.truncatedListing, SafetyReason.keyContainsEquals, SafetyReason.keyNotUTF8,
        SafetyReason.unsafeFilterDriver, SafetyReason.unneutralizedHooks, SafetyReason.ownTLSFiles,
        SafetyReason.pinnedHosts, SafetyReason.ownRefStorage, SafetyReason.tooManyFetchOverrides,
        SafetyReason.partialClone, SafetyReason.partialCloneNeedsNewerGit, SafetyReason.passwordInURL,
        SafetyReason.nonBuiltInRemote, SafetyReason.untrustedLocalRemote, SafetyReason.localRemoteNeedsNewerGit,
        SafetyReason.worktreeFolderMissing, SafetyReason.notInspected, SafetyReason.noLongerMatches,
        SafetyReason.tooManyFilterDrivers(65, limit: 64),
    ]

    private static func koreanBundle() throws -> Bundle {
        try XCTUnwrap(Bundle.main.path(forResource: "ko", ofType: "lproj").flatMap(Bundle.init(path:)))
    }

    /// The tests run in English: the display value of every reason is its report value.
    func testDisplayInEnglishIsTheReportValue() {
        for reason in Self.reasons {
            XCTAssertEqual(SafetyReason.display(reason), reason)
        }
    }

    /// Every reason is translated in the Korean table, under the key `display` looks up.
    func testEveryReasonHasKorean() throws {
        let ko = try Self.koreanBundle()
        let version = "\(GitEnvironment.lazyFetchControlVersion)"
        for reason in Self.reasons {
            var key = reason.replacingOccurrences(of: version, with: "%@")
            if reason.hasPrefix("This repository defines 65") {
                key = "This repository defines %lld filter drivers, more than Overgrove can neutralize (%lld)."
            }
            let missing = "\u{0}missing"
            let korean = ko.localizedString(forKey: key, value: missing, table: nil)
            XCTAssertNotEqual(korean, missing, "no Korean: \(key)")
            XCTAssertNotEqual(korean, key, "not translated: \(key)")
        }
    }

    /// Text that is not one of the reasons (git's own, a path) passes through, and a near match is not rewritten.
    func testOtherTextPassesThrough() {
        XCTAssertEqual(SafetyReason.display("fatal: something else"), "fatal: something else")
        XCTAssertEqual(
            SafetyReason.display("This repository defines x filter drivers, more than Overgrove can neutralize (64)."),
            "This repository defines x filter drivers, more than Overgrove can neutralize (64).")
        XCTAssertEqual(SafetyReason.display(""), "")
    }

    /// The reasons the inspector and fetch produce are these values, so the screen can translate them.
    func testProducersUseTheseValues() {
        XCTAssertEqual(TransportName.nonBuiltInRemoteReason, SafetyReason.nonBuiltInRemote)
        XCTAssertEqual(GitClient.passwordInURLReason, SafetyReason.passwordInURL)
        XCTAssertEqual(RepositoryService.untrustedLocalReason, SafetyReason.untrustedLocalRemote)
        XCTAssertEqual(RepositoryService.olderGitLocalReason, SafetyReason.localRemoteNeedsNewerGit)
        XCTAssertEqual(LiveWorktreeInspector.notInspected, SafetyReason.notInspected)
        XCTAssertEqual(LiveWorktreeInspector.noLongerMatches, SafetyReason.noLongerMatches)
    }
}
