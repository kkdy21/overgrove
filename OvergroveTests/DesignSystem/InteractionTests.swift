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

    // MARK: - Tooltips over hover buttons (#658)

    /// The type of a view, as SwiftUI nests its modifiers: `ModifiedContent<Inner, Modifier>` lists the modifier
    /// applied last on the outside.
    private func typeName(_ view: some View) -> String { String(describing: type(of: view)) }

    /// Checks that `tracker` sits right outside the button's style and that `.help` wraps it. SwiftUI names the help
    /// wrapper `HelpView<…>` in current SDKs; a `ModifiedContent<…, Help…>` form would come
    /// after the tracker instead. Either way the tracker must not be inside the button's label.
    private func assertTooltipWrapsTracking(
        _ name: String, style: String, tracker: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let styleEnd = name.range(of: style + ">>, " + tracker)?.upperBound else {
            return XCTFail("\(tracker) is not right outside the button's style: \(name)", file: file, line: line)
        }
        // `HelpView<ModifiedContent<…Button…, Style>, Tracker>>`: the help wrapper opens right before the button and
        // closes right after the tracker.
        let helpWraps =
            name.contains("HelpView<ModifiedContent<ModifiedContent<Button<")
            && name.contains(style + ">>, " + tracker + ">>")
        let helpIsAfter = name[styleEnd...].contains("Help")
        XCTAssertTrue(helpWraps || helpIsAfter, "help does not wrap the tracking: \(name)", file: file, line: line)
        XCTAssertEqual(
            name.components(separatedBy: tracker).count, 2, "tracked only once, outside the label: \(name)",
            file: file, line: line)
    }

    /// Tooltips on buttons stayed up or stopped appearing when the pointer was tracked inside the `Button` and `.help`
    /// was put outside it. File rows, whose tooltip directly wraps the hover tracking, behaved. Hover buttons now track
    /// the pointer outside the `Button`, so `.help` wraps the tracking directly.
    func testHoverButtonTracksThePointerOutsideTheButton() {
        assertTooltipWrapsTracking(
            typeName(Button("Copy") {}.hoverButtonStyle().help("Copy Path")),
            style: "ButtonStyleContainerModifier<HoverButtonStyle", tracker: "ButtonHoverTracking")
    }

    func testDetailIconSegmentTracksThePointerOutsideTheButton() {
        let segments = DetailIconSegments(isWorktree: false, onChanges: {}, onWorktree: {})
        let segment = segments.segment("Changes", symbol: "list.bullet", isSelected: false, action: {})
        assertTooltipWrapsTracking(
            typeName(segment), style: "PrimitiveButtonStyleContainerModifier<PlainButtonStyle",
            tracker: "HoverHighlight")
    }

    /// The style only draws the hover state handed to it from outside the button.
    func testHoverButtonStyleDrawsTheHoverStateItIsGiven() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        func button(hovered: Bool) -> some View {
            Button("Copy") {}.buttonStyle(HoverButtonStyle()).environment(\.isButtonHovered, hovered)
        }
        let size = CGSize(width: 80, height: 30)
        let idle = try render(button(hovered: false), size: size, appearance: appearance).tiffRepresentation
        let hovered = try render(button(hovered: true), size: size, appearance: appearance).tiffRepresentation
        XCTAssertNotEqual(idle, hovered)
    }
}
