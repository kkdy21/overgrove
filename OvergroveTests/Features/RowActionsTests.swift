import Foundation
import XCTest

@testable import Overgrove

/// Row menu safety checks (#73, interaction.md §5, security-review.md T14).
final class RowActionsTests: XCTestCase {
    private var root: URL!
    private var outside: URL!

    override func setUpWithError() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("overgrove-row-\(UUID().uuidString)")
        root = base.appendingPathComponent("repo", isDirectory: true)
        outside = base.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("src/a.swift"), atomically: true, encoding: .utf8)
        try "secret".write(to: outside.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("link.txt"), withDestinationURL: outside.appendingPathComponent("b.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("dir"), withDestinationURL: outside)
    }

    override func tearDown() {
        if let root { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
    }

    func testRevealOnlyInsideTheRepository() throws {
        let inside = RowActions.revealTarget(root.appendingPathComponent("src/a.swift"), within: root)
        XCTAssertEqual(try inside.get().lastPathComponent, "a.swift")

        XCTAssertEqual(
            RowActions.revealTarget(root.appendingPathComponent("link.txt"), within: root),
            .failure(.outsideRepository), "a link out of the repository is refused")
        XCTAssertEqual(
            RowActions.revealTarget(root.appendingPathComponent("dir/b.txt"), within: root),
            .failure(.outsideRepository), "a linked folder out of the repository is refused")
        XCTAssertEqual(
            RowActions.revealTarget(root.appendingPathComponent("src/../../elsewhere/b.txt"), within: root),
            .failure(.outsideRepository), "`..` out of the repository is refused")
        XCTAssertEqual(
            RowActions.revealTarget(root.appendingPathComponent("gone.txt"), within: root), .failure(.missing))
        XCTAssertEqual(RowActionRefusal.outsideRepository.message, "This path points outside the repository.")
    }

    func testBrowserOpensHTTPSOnly() {
        XCTAssertNoThrow(try RowActions.browserTarget(URL(string: "https://github.com/o/r/issues/1")!).get())
        for text in [
            "http://github.com/o/r", "file:///etc/passwd", "javascript:alert(1)", "x-apple.systempreferences:",
            "https:///nohost",
        ] {
            XCTAssertEqual(RowActions.browserTarget(URL(string: text)!), .failure(.notHTTPS), text)
        }
    }
}
