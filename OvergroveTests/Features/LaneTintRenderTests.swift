import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// #300: the selected worktree row and the toolbar focus chip carry the branch's lane colour (art-direction.md §3.4,
/// §6), rendered offscreen in light and dark. Set `OVERGROVE_SNAPSHOT_DIR` (xcodebuild:
/// `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep the PNGs.
@MainActor
final class LaneTintRenderTests: XCTestCase {
    private let appearances: [(String, NSAppearance.Name)] = [("light", .aqua), ("dark", .darkAqua)]
    private let lane = 2

    private func render(
        _ view: some View, width: CGFloat, height: CGFloat, background: Color, appearance: NSAppearance
    ) throws -> NSBitmapImageRep {
        let host = NSHostingView(
            rootView: view.frame(width: width, height: height, alignment: .leading).background(background))
        host.appearance = appearance
        host.frame = NSRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    /// The pixel at a point (top-left origin, points).
    private func pixel(_ bitmap: NSBitmapImageRep, width: CGFloat, x: CGFloat, y: CGFloat) throws -> NSColor {
        let scale = CGFloat(bitmap.pixelsWide) / width
        return try XCTUnwrap(bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))?.usingColorSpace(.sRGB))
    }

    private func color(_ name: String, in appearance: NSAppearance) throws -> NSColor {
        let named = try XCTUnwrap(NSColor(named: name))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance { resolved = named.usingColorSpace(.sRGB) }
        return try XCTUnwrap(resolved)
    }

    private func assertBlend(
        _ actual: NSColor, _ top: NSColor, over bottom: NSColor, opacity: Double, _ message: String,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        let expected = [
            (actual.redComponent, top.redComponent, bottom.redComponent),
            (actual.greenComponent, top.greenComponent, bottom.greenComponent),
            (actual.blueComponent, top.blueComponent, bottom.blueComponent),
        ]
        for (value, t, b) in expected {
            XCTAssertEqual(value, t * opacity + b * (1 - opacity), accuracy: 0.05, message, file: file, line: line)
        }
    }

    private func snapshot(_ bitmap: NSBitmapImageRep, _ name: String) throws {
        if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
            let png = bitmap.representation(using: .png, properties: [:])
        {
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    private func focusedRow(laneIndex: Int?) throws -> WorktreeRow {
        let model = WorktreeListModel(
            listing: .mockup, focused: GitPath("/tmp/dev/api-wt/42-rate-limit"), home: "/tmp/dev",
            laneIndex: { _ in laneIndex })
        return try XCTUnwrap(model.rows.first { $0.isFocused })
    }

    // MARK: - Selected row

    /// The selected row's border is the lane colour at `worktree-selection-border-opacity` over the selection fill.
    func testSelectedRowHasALaneColouredBorder() throws {
        let width: CGFloat = 256
        // The row is inset 6pt on each side (art-direction.md §6); the border is the first point inside that.
        let edge = (x: CGFloat(6.5), y: Tokens.Size.rowWorktree / 2)
        for (name, appearanceName) in appearances {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let tinted = try render(
                WorktreeRowView(row: try focusedRow(laneIndex: lane), isSelected: true, isListFocused: true),
                width: width, height: Tokens.Size.rowWorktree, background: Tokens.Color.surfacePanel,
                appearance: appearance)
            let plain = try render(
                WorktreeRowView(row: try focusedRow(laneIndex: nil), isSelected: true, isListFocused: true),
                width: width, height: Tokens.Size.rowWorktree, background: Tokens.Color.surfacePanel,
                appearance: appearance)

            let selection = try pixel(plain, width: width, x: edge.x, y: edge.y)
            let expectedSelection = try color("Tokens/surfaceSelection", in: appearance)
            XCTAssertEqual(selection.redComponent, expectedSelection.redComponent, accuracy: 0.05, "\(name): no lane")

            assertBlend(
                try pixel(tinted, width: width, x: edge.x, y: edge.y),
                try color("Tokens/graphLane\(lane)", in: appearance),
                over: selection, opacity: Tokens.Graph.worktreeSelectionBorderOpacity, "\(name): lane border")
            // Inside the border the row keeps the selection fill.
            let inside = try pixel(tinted, width: width, x: 9, y: edge.y)
            XCTAssertEqual(inside.redComponent, selection.redComponent, accuracy: 0.05, "\(name): fill unchanged")
            try snapshot(tinted, "worktree-row-selected-lane-\(name)")
        }
    }

    /// Only the selected row gets the border; an unselected row with a lane shows the panel.
    func testUnselectedRowHasNoBorder() throws {
        let width: CGFloat = 256
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let bitmap = try render(
            WorktreeRowView(row: try focusedRow(laneIndex: lane), isSelected: false, isListFocused: true),
            width: width, height: Tokens.Size.rowWorktree, background: Tokens.Color.surfacePanel,
            appearance: appearance)
        let edge = try pixel(bitmap, width: width, x: 6.5, y: Tokens.Size.rowWorktree / 2)
        let panel = try color("Tokens/surfacePanel", in: appearance)
        XCTAssertEqual(edge.redComponent, panel.redComponent, accuracy: 0.03)
        XCTAssertEqual(edge.blueComponent, panel.blueComponent, accuracy: 0.03)
    }

    // MARK: - Toolbar focus chip

    private let worktree = FocusedWorktree(
        branch: "feat/42-rate-limit", headShortSHA: "b2e8a44", ahead: 2, behind: 0, hasUpstream: true)

    /// The chip is the lane colour at `focus-chip-fill-opacity` over the toolbar, with a border at
    /// `focus-chip-border-opacity`.
    func testFocusChipIsTintedWithTheLaneColour() throws {
        let (width, height): (CGFloat, CGFloat) = (320, 32)
        for (name, appearanceName) in appearances {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let chip = WorktreeChip(worktree: worktree, laneIndex: lane, onJumpToHead: {}).fixedSize()
            let bitmap = try render(
                chip, width: width, height: height, background: Tokens.Color.surfaceWindow, appearance: appearance)
            let window = try color("Tokens/surfaceWindow", in: appearance)
            let laneColor = try color("Tokens/graphLane\(lane)", in: appearance)

            // Left of the symbol, on the vertical centre: the fill. The leftmost point: the border.
            let fill = try pixel(bitmap, width: width, x: 5, y: height / 2)
            assertBlend(fill, laneColor, over: window, opacity: Tokens.Graph.focusChipFillOpacity, "\(name): fill")
            assertBlend(
                try pixel(bitmap, width: width, x: 0.25, y: height / 2), laneColor, over: fill,
                opacity: Tokens.Graph.focusChipBorderOpacity, "\(name): border")
            try snapshot(bitmap, "focus-chip-lane-\(name)")
        }
    }

    /// Without a lane (detached HEAD, graph not loaded) the chip keeps its neutral control look.
    func testFocusChipWithoutALaneStaysNeutral() throws {
        let (width, height): (CGFloat, CGFloat) = (320, 32)
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let chip = WorktreeChip(worktree: worktree, laneIndex: nil, onJumpToHead: {}).fixedSize()
        let bitmap = try render(
            chip, width: width, height: height, background: Tokens.Color.surfaceWindow, appearance: appearance)
        let fill = try pixel(bitmap, width: width, x: 5, y: height / 2)
        let control = try color("Tokens/surfaceControl", in: appearance)
        let window = try color("Tokens/surfaceWindow", in: appearance)
        assertBlend(fill, control, over: window, opacity: control.alphaComponent, "neutral fill")
    }

    /// The `⌘J` hint is `text.secondary` on a tinted chip: `text.tertiary` falls below 4.5:1 on some lane tints in
    /// light mode (colorcheck).
    func testFocusChipHintStaysReadableOnTheTint() {
        XCTAssertEqual(WorktreeChip.hintColor(isTinted: true), Tokens.Color.textSecondary)
        XCTAssertEqual(WorktreeChip.hintColor(isTinted: false), Tokens.Color.textTertiary)
    }
}
