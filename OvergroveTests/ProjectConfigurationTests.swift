import AppKit
import XCTest

@testable import Overgrove

/// Guards the project settings required by docs/README.md §2.1 and issue #30.
final class ProjectConfigurationTests: XCTestCase {
    func testBundleIdentifier() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "io.github.kkdy21.overgrove")
    }

    func testMinimumSystemVersionIsMacOS14() {
        let minimum = Bundle.main.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String
        XCTAssertEqual(minimum, "14.0")
    }

    func testAppSandboxIsDisabled() {
        // The app reads repositories anywhere on disk (HANDOFF §4), so it must not run sandboxed.
        let containerPath = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"]
        XCTAssertNil(containerPath)
    }

    /// #38: the app icon comes from AppIcon.appiconset (scripts/render-app-icon.sh), and the mark is an asset (S-07).
    func testAppIconAndMarkAreInTheAssetCatalog() throws {
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String, "AppIcon")
        let mark = try XCTUnwrap(NSImage(named: "Mark"), "Mark.imageset")
        XCTAssertGreaterThan(mark.size.width, 0)
    }
}
