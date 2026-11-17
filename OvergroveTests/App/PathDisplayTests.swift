import Foundation
import XCTest

@testable import Overgrove

/// `PathDisplay` (#713): the one place that shows the home folder as `~`, for the sidebar, the detail panel, S-07, the
/// registration notices, the alerts, and Settings alike.
final class PathDisplayTests: XCTestCase {
    func testShortensTheHomeFolderAndWhatIsInsideIt() {
        XCTAssertEqual(PathDisplay.abbreviated("/Users/user/dev/api", home: "/Users/user"), "~/dev/api")
        XCTAssertEqual(PathDisplay.abbreviated("/Users/user", home: "/Users/user"), "~")
        XCTAssertEqual(PathDisplay.abbreviated("/Users/user/dev/api", home: "/Users/user/"), "~/dev/api")
        XCTAssertEqual(PathDisplay.abbreviated("/Users/user", home: "/Users/user/"), "~", "a trailing slash on home")
    }

    func testLeavesPathsOutsideTheHomeFolderWhole() {
        XCTAssertEqual(PathDisplay.abbreviated("/tmp/dev/api", home: "/Users/user"), "/tmp/dev/api")
        XCTAssertEqual(
            PathDisplay.abbreviated("/Users/username/dev/api", home: "/Users/user"), "/Users/username/dev/api",
            "only whole path components match")
        XCTAssertEqual(PathDisplay.abbreviated("/Users", home: "/Users/user"), "/Users")
    }

    /// An empty or root home would otherwise turn every path into `~…`.
    func testAnEmptyOrRootHomeShortensNothing() {
        XCTAssertEqual(PathDisplay.abbreviated("/tmp/dev/api", home: "/"), "/tmp/dev/api")
        XCTAssertEqual(PathDisplay.abbreviated("/", home: "/"), "/")
        XCTAssertEqual(PathDisplay.abbreviated("/tmp/dev/api", home: ""), "/tmp/dev/api")
    }

    /// The real home is the default, as the screens call it.
    func testUsesTheUsersHomeFolderByDefault() {
        XCTAssertEqual(PathDisplay.abbreviated(NSHomeDirectory() + "/dev/api"), "~/dev/api")
    }
}
