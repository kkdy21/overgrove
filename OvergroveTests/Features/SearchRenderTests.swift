import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// The graph's search bar and the sidebar filter rendered offscreen in light and dark (#74). Set
/// `OVERGROVE_SNAPSHOT_DIR` (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep the PNGs.
@MainActor
final class SearchRenderTests: XCTestCase {
    func testRendersInLightAndDark() throws {
        let commits = FakeGraphLoader.linear(1_500)
        let result = GraphSearchResult(
            query: try XCTUnwrap(GraphSearchQuery("commit 14")), commits: commits, pills: [:], issueRepository: nil,
            isComplete: false)
        let view = VStack(spacing: Tokens.Spacing.md) {
            GraphSearchBar(result: result, onPrevious: {}, onNext: {})
            SidebarFilterField(text: .constant("feat"), focusRequest: 0).frame(width: 240)
            SidebarFilterField(text: .constant(""), focusRequest: 0).frame(width: 240)
            Spacer()
        }
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(
                rootView: view.frame(width: 720, height: 160).background(Tokens.Color.surfacePanel))
            host.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            host.frame = NSRect(x: 0, y: 0, width: 720, height: 160)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("search-\(name).png"))
            }
        }
    }
}
