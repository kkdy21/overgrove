import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// Shared hover, press, and motion helpers (#571). Rendered offscreen; set `OVERGROVE_SNAPSHOT_DIR`
/// (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep the PNGs.
@MainActor
final class InteractionTests: XCTestCase {
    private func render(_ view: some View, size: CGSize, appearance: NSAppearance) throws -> NSBitmapImageRep {
        let host = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height).background(Tokens.Color.surfacePanel))
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func appearances() throws -> [(String, NSAppearance)] {
        try [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)].map {
            ($0.0, try XCTUnwrap(NSAppearance(named: $0.1)))
        }
    }

    private func keep(_ bitmap: NSBitmapImageRep, _ name: String) throws {
        if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
            let png = bitmap.representation(using: .png, properties: [:])
        {
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("interaction-\(name).png"))
        }
    }

    /// Reduce Motion changes things at once; otherwise hover is 120ms and disclosures use the standard curve
    /// (art-direction.md §9, interaction.md §6.5).
    func testReduceMotionDropsTheAnimation() {
        XCTAssertNil(Animation.respectingReduceMotion(.fast, reduceMotion: true))
        XCTAssertNil(Animation.respectingReduceMotion(.standard, reduceMotion: true))
        XCTAssertEqual(Animation.respectingReduceMotion(.fast, reduceMotion: false), .fast)
        XCTAssertEqual(Animation.respectingReduceMotion(.standard, reduceMotion: false), .standard)
        XCTAssertEqual(Animation.fast, .easeOut(duration: Tokens.Motion.durationFast))
        XCTAssertEqual(Tokens.Motion.durationFast, 0.12)
        XCTAssertEqual(Animation.panelCollapse, .standard, "panel collapse is the standard motion")
    }

    /// `withMotion` runs the change either way and returns its result.
    func testWithMotionRunsTheBodyEitherWay() {
        var runs = 0
        for reduceMotion in [true, false] {
            let result = withMotion(.fast, reduceMotion: reduceMotion) {
                runs += 1
                return runs
            }
            XCTAssertEqual(result, runs)
        }
        XCTAssertEqual(runs, 2)
    }

    /// The hover fill is `surface.hover` on the panel and clear otherwise, in both modes and both shapes.
    func testHoverFillShowsOnlyWhenHovering() throws {
        for (name, appearance) in try appearances() {
            for shape in [HoverShape.fullWidth, .inset, .rounded(radius: Tokens.Radius.md)] {
                let size = CGSize(width: 80, height: 28)
                let idle = try render(HoverFill(shape: shape, isHovering: false), size: size, appearance: appearance)
                let hovered = try render(HoverFill(shape: shape, isHovering: true), size: size, appearance: appearance)
                let center = (x: 40, y: 14)
                XCTAssertNotEqual(
                    idle.colorAt(x: center.x, y: center.y), hovered.colorAt(x: center.x, y: center.y),
                    "\(name) \(shape)")
                let corner = (idle.colorAt(x: 0, y: 0), hovered.colorAt(x: 0, y: 0))
                if shape != .fullWidth {
                    XCTAssertEqual(corner.0, corner.1, "\(name): the inset fill is rounded")
                } else {
                    XCTAssertNotEqual(corner.0, corner.1, "\(name): the full-width fill reaches the corner")
                }
                try keep(hovered, "hover-\(shape)-\(name)")
            }
        }
    }

    /// The selected sidebar row is accent-tinted only while its list has focus (interaction.md §1.2).
    func testSidebarSelectionFollowsFocus() throws {
        for (name, appearance) in try appearances() {
            let size = CGSize(width: 80, height: 28)
            let focused = try render(SidebarSelectionBackground(isFocused: true), size: size, appearance: appearance)
            let inactive = try render(SidebarSelectionBackground(isFocused: false), size: size, appearance: appearance)
            XCTAssertNotEqual(focused.colorAt(x: 40, y: 14), inactive.colorAt(x: 40, y: 14), name)
        }
    }

    /// The footer, a hover-style button, and the author chips render in both modes.
    func testFooterButtonAndChipsRender() throws {
        for (name, appearance) in try appearances() {
            let view = VStack(spacing: 0) {
                HStack {
                    Button("All") {}.buttonStyle(GraphChipButtonStyle(isSelected: true))
                    Button("Alice") {}.buttonStyle(GraphChipButtonStyle(isSelected: false))
                }
                .frame(maxHeight: .infinity)
                PanelFooter {
                    Button("‹ Graph") {}.hoverButtonStyle()
                    Spacer()
                    Button {
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .hoverButtonStyle()
                }
            }
            let bitmap = try render(view, size: CGSize(width: 300, height: 120), appearance: appearance)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            try keep(bitmap, "footer-\(name)")
        }
    }

    // MARK: - AppKit tooltips (#658)

    /// An offscreen window that is never ordered in: nothing shows on screen and the real pointer is not used.
    private func window(_ view: some View) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 80), styleMask: [.borderless], backing: .buffered,
            defer: false)
        window.contentView = NSHostingView(rootView: view.frame(width: 200, height: 80))
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return window
    }

    private func toolTipViews(in view: NSView) -> [NSView] {
        (view is ToolTipArea.ToolTipView ? [view] : []) + view.subviews.flatMap(toolTipViews)
    }

    func testHoverButtonGetsAnAppKitTooltipOverItsWholeFrame() throws {
        let window = window(Button("Copy") {}.hoverButtonStyle().toolTip("Copy Path"))
        let views = toolTipViews(in: try XCTUnwrap(window.contentView))
        XCTAssertEqual(views.count, 1)
        let view = try XCTUnwrap(views.first)
        XCTAssertEqual(view.toolTip, "Copy Path")
        XCTAssertGreaterThan(view.frame.width, 20, "covers the button, padding included")
        XCTAssertGreaterThan(view.frame.height, 10)
    }

    func testAnEmptyTooltipShowsNone() throws {
        let window = window(Text("folder").toolTip(""))
        XCTAssertNil(try XCTUnwrap(toolTipViews(in: try XCTUnwrap(window.contentView)).first).toolTip)
    }

    func testDetailIconSegmentHasAnAppKitTooltip() throws {
        let segments = DetailIconSegments(isWorktree: false, onChanges: {}, onWorktree: {})
        let window = window(segments.segment("Changes", symbol: "list.bullet", isSelected: false, action: {}))
        XCTAssertEqual(toolTipViews(in: try XCTUnwrap(window.contentView)).map(\.toolTip), ["Changes"])
    }

    /// The tooltip view lies under the whole button and never takes a hit, so clicks, hover, and the cursor stay with
    /// the button.
    func testTheTooltipViewNeverTakesAHit() throws {
        let window = window(
            Button {
            } label: {
                Text("Copy").frame(width: 120, height: 40)
            }
            .hoverButtonStyle()
            .toolTip("Copy Path"))
        let hosting = try XCTUnwrap(window.contentView)
        let view = try XCTUnwrap(toolTipViews(in: hosting).first)
        let center = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: hosting.superview)
        XCTAssertNotNil(hosting.hitTest(center))
        XCTAssertFalse(hosting.hitTest(center) === view)
        XCTAssertNil(view.hitTest(NSPoint(x: view.bounds.midX, y: view.bounds.midY)))
    }
}
