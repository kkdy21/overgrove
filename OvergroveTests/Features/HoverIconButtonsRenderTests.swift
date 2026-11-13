import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// #616: the graph search's ⌃⌄ and the fetch failure details' Copy Command use the shared hover button style. Hover
/// itself cannot be drawn offscreen; these check the style did not change the layout around them. Set
/// `OVERGROVE_SNAPSHOT_DIR` to keep the PNGs.
@MainActor
final class HoverIconButtonsRenderTests: XCTestCase {
    private func render(_ view: some View, size: CGSize, name: String) throws {
        for (mode, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(
                rootView: view.frame(width: size.width, height: size.height).background(Tokens.Color.surfacePanel))
            host.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(mode).png"))
            }
        }
    }

    /// The search bar stays one column-header row high with the padded buttons in it.
    func testTheSearchBarKeepsItsHeight() throws {
        let result = GraphSearchResult(
            query: try XCTUnwrap(GraphSearchQuery("commit 14")), commits: FakeGraphLoader.linear(40), pills: [:],
            issueRepository: nil, isComplete: true)
        let bar = GraphSearchBar(result: result, onPrevious: {}, onNext: {})
        let height = NSHostingView(rootView: bar.frame(width: 720)).fittingSize.height
        XCTAssertEqual(height, Tokens.Size.columnHeader, accuracy: 0.5)
        try render(bar, size: CGSize(width: 720, height: Tokens.Size.columnHeader), name: "search-bar-616")
    }

    func testFetchFailureDetailsRender() throws {
        let failure = FetchFailureDetail(
            id: 0, summary: "origin: authentication failed", guidance: "Sign in again, then fetch.",
            commands: ["gh auth login"], detail: nil)
        try render(
            FetchFailureDetailsView(failures: [failure], dismiss: {}), size: CGSize(width: 420, height: 220),
            name: "fetch-failure-616")
    }
}
