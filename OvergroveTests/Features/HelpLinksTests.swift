import XCTest

@testable import Overgrove

/// The fetch failure details link to the self-hosted Git guide (#152).
final class HelpLinksTests: XCTestCase {
    func testSelfHostedGuideLinkPointsAtTheGuideInThisRepository() throws {
        let url = try XCTUnwrap(HelpLinks.selfHostedGit)
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "github.com")
        let prefix = "/kkdy21/overgrove/blob/main/"
        XCTAssertTrue(url.path.hasPrefix(prefix), url.path)
        // The linked file exists at that path in the repository.
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let file = root.appendingPathComponent(String(url.path.dropFirst(prefix.count)))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), file.path)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: file.deletingPathExtension().appendingPathExtension("ko.md").path))
    }
}
