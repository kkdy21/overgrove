import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// Graph zoom (#121, interaction.md §6.3): five steps with fixed row heights, one app-wide setting, and the graph
/// panel drawn at each step.
@MainActor
final class GraphZoomTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() async throws {
        suite = "overgrove-zoom-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suite)
    }

    func testStepsAndRowHeights() {
        XCTAssertEqual(
            GraphZoom.scales.map { GraphZoom(step: GraphZoom.scales.firstIndex(of: $0)!).percent },
            [
                85, 100, 115, 130, 150,
            ])
        XCTAssertEqual(GraphZoom.rowHeights, [26, 30, 34, 39, 45])
        XCTAssertEqual(GraphZoom.scales.count, GraphZoom.rowHeights.count)
        XCTAssertEqual(GraphZoom.actualSize.geometry.rowHeight, Tokens.Size.rowGraph, "100 % is size.row-graph")
        for step in GraphZoom.rowHeights.indices {
            XCTAssertEqual(GraphZoom.rowHeights[step], GraphZoom.rowHeights[step].rounded(), "whole points")
        }

        XCTAssertFalse(GraphZoom(step: 0).canZoomOut)
        XCTAssertFalse(GraphZoom(step: GraphZoom.scales.count - 1).canZoomIn)
        XCTAssertEqual(GraphZoom(step: -3).step, 0, "clamped")
        XCTAssertEqual(GraphZoom(step: 99).step, GraphZoom.scales.count - 1, "clamped")
        XCTAssertEqual(GraphZoom.actualSize.zoomedIn.percent, 115)
        XCTAssertEqual(GraphZoom.actualSize.zoomedOut.percent, 85)
    }

    /// 100 % draws exactly as before the zoom existed; other steps scale lanes, nodes, and widths together.
    func testGeometryScales() {
        let standard = GraphGeometry.standard
        XCTAssertEqual(standard.lane, Tokens.Size.graphLaneWidth)
        XCTAssertEqual(standard.inset, 7)
        XCTAssertEqual(standard.node, Tokens.Size.graphNode)
        XCTAssertEqual(standard.width(lanes: 3), 3 * 20 + 14)

        let large = GraphZoom(step: 4).geometry
        XCTAssertEqual(large.lane, 30)
        XCTAssertEqual(large.width(lanes: 3), standard.width(lanes: 3) * 1.5, accuracy: 0.001)
        XCTAssertEqual(large.x(2), standard.x(2) * 1.5, accuracy: 0.001)
        XCTAssertEqual(large.maxOffset(lanes: 20), standard.maxOffset(lanes: 20) * 1.5, accuracy: 0.001)
    }

    /// At 100 % the row text uses the design tokens' text styles; other steps scale the styles' macOS sizes.
    func testTypography() {
        let actual = GraphZoom.actualSize.typography
        XCTAssertEqual(actual.body, Tokens.Font.body)
        XCTAssertEqual(actual.callout, Tokens.Font.callout)
        XCTAssertEqual(actual.monoSmall, Tokens.Font.monoSmall)
        XCTAssertEqual(GraphZoom(step: 4).typography.body, .system(size: 13 * 1.5))
        XCTAssertEqual(
            GraphZoom(step: 0).typography.points(11, weight: .medium), .system(size: 11 * 0.85, weight: .medium))
    }

    func testTheStepIsStoredAndClamped() {
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.graphZoom, .actualSize, "100 % until changed")
        settings.zoomGraphIn()
        settings.zoomGraphIn()
        XCTAssertEqual(settings.graphZoom.percent, 130)
        XCTAssertEqual(AppSettings(defaults: defaults).graphZoom.percent, 130, "kept for the next launch")
        for _ in 0..<10 { settings.zoomGraphIn() }
        XCTAssertEqual(settings.graphZoom.percent, 150, "stops at the last step")
        settings.resetGraphZoom()
        XCTAssertEqual(settings.graphZoom, .actualSize)
        for _ in 0..<10 { settings.zoomGraphOut() }
        XCTAssertEqual(settings.graphZoom.percent, 85)

        defaults.set(42, forKey: AppSettings.graphZoomStepKey)
        XCTAssertEqual(AppSettings(defaults: defaults).graphZoom.percent, 150, "an edited value is clamped")
    }

    /// The graph panel at the smallest and largest step, with the selected commit's row in view.
    func testGraphRendersAtEveryEnd() async throws {
        let store = GraphStore(loader: SampleGraphLoader())
        store.load(
            Repository(
                rootURL: URL(fileURLWithPath: "/tmp/dev/api"),
                commonGitDirectoryURL: URL(fileURLWithPath: "/tmp/dev/api/.git"), isBare: false),
            focus: nil)
        let deadline = ContinuousClock.now + .seconds(5)
        while store.status != .loaded, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.status, .loaded)
        for step in [0, GraphZoom.scales.count - 1] {
            let zoom = GraphZoom(step: step)
            let view = GraphView(store: store, now: Date(timeIntervalSince1970: 1_800_000_000))
                .environment(\.graphZoom, zoom)
            for (mode, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let size = CGSize(width: 960, height: 420)
                let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
                host.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                XCTAssertGreaterThan(bitmap.pixelsWide, 0)
                if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                    let png = bitmap.representation(using: .png, properties: [:])
                {
                    try png.write(
                        to: URL(fileURLWithPath: directory).appendingPathComponent(
                            "graph-zoom-\(zoom.percent)-\(mode).png"))
                }
            }
        }
    }
}
