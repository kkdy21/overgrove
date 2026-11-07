import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// `PanelSplitView` rendered in an `NSHostingView` (#174).
///
/// The divider's VoiceOver label and value come from `PanelLayout` and are covered by `PanelLayoutTests`. SwiftUI
/// builds its macOS accessibility tree only for a connected assistive client, so the element itself is checked by
/// hand with VoiceOver (manual QA in the pull request).
@MainActor
final class PanelSplitViewTests: XCTestCase {
    /// Counts how often a panel's content `body` runs.
    private final class Counter {
        var evaluations = 0
    }

    private struct CountingPanel: View {
        let title: String
        let counter: Counter

        var body: some View {
            counter.evaluations += 1
            return Text(title)
        }
    }

    private final class LayoutBox {
        var layout = PanelLayout.default
    }

    private func makeView(_ box: LayoutBox, counter: Counter) -> some View {
        PanelSplitView(layout: Binding(get: { box.layout }, set: { box.layout = $0 })) {
            CountingPanel(title: "Sidebar", counter: counter)
        } center: {
            CountingPanel(title: "Graph", counter: counter)
        } detail: {
            CountingPanel(title: "Detail", counter: counter)
        }
    }

    /// PB-4 guard, standing in for the Instruments check in #174: a drag only moves panel frames, so changing the
    /// width 40 times (as drag frames would) does not re-run the panels' content bodies.
    func testResizingDoesNotReEvaluatePanelContent() {
        let box = LayoutBox()
        let counter = Counter()
        let host = NSHostingView(rootView: AnyView(makeView(box, counter: counter)))
        host.frame = NSRect(x: 0, y: 0, width: 1440, height: 600)
        host.layoutSubtreeIfNeeded()
        let initial = counter.evaluations
        XCTAssertGreaterThanOrEqual(initial, 3, "each panel rendered at least once")

        for step in 0..<40 {
            box.layout.sidebarWidth = 230 + CGFloat(step) * 4
            box.layout.detailWidth = 320 + CGFloat(step) * 3
            host.rootView = AnyView(makeView(box, counter: counter))
            host.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(counter.evaluations, initial, "panel content must not be rebuilt on every resize frame")
    }

    /// Renders the default layout in light and dark. Set `OVERGROVE_SNAPSHOT_DIR` (with xcodebuild:
    /// `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to write the PNGs, e.g. for a pull request.
    func testRendersInLightAndDark() throws {
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let box = LayoutBox()
            let host = NSHostingView(rootView: AnyView(makeView(box, counter: Counter())))
            host.appearance = NSAppearance(named: appearance)
            host.frame = NSRect(x: 0, y: 0, width: 1440, height: 600)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertEqual(bitmap.size.width, 1440)

            // The window background shows in the outer gutter.
            let gutter = try XCTUnwrap(bitmap.colorAt(x: 2, y: bitmap.pixelsHigh / 2))
            let window = try XCTUnwrap(NSColor(named: "Tokens/surfaceWindow"))
            var resolved: NSColor?
            host.effectiveAppearance.performAsCurrentDrawingAppearance {
                resolved = window.usingColorSpace(.sRGB)
            }
            let expected = try XCTUnwrap(resolved)
            let actual = try XCTUnwrap(gutter.usingColorSpace(.sRGB))
            XCTAssertEqual(actual.redComponent, expected.redComponent, accuracy: 0.03, name)
            XCTAssertEqual(actual.blueComponent, expected.blueComponent, accuracy: 0.03, name)

            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("panel-split-\(name).png"))
            }
        }
    }
}
