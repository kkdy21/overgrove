import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// #605: an unfocused selection and the hover fill look alike by colour (dark 43,49,60 against 46,51,59), so the
/// inactive selection carries a `border.strong` outline. Rendered on `surface.panel` in light and dark.
@MainActor
final class SelectionVersusHoverRenderTests: XCTestCase {
    private func render(_ view: some View, appearance: NSAppearance) throws -> NSBitmapImageRep {
        let size = CGSize(width: 200, height: 28)
        let host = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height).background(Tokens.Color.surfacePanel))
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func luminance(_ color: NSColor) -> Double {
        func linear(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }

    func testAnInactiveSelectionIsOutlinedAndTheHoverIsNot() throws {
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let selection = try render(SidebarSelectionBackground(isFocused: false), appearance: appearance)
            let hover = try render(HoverFill(shape: .inset, isHovering: true), appearance: appearance)
            let scale = CGFloat(selection.pixelsWide) / 200
            // The left edge at mid-height: the outline on the selection, plain fill on the hover.
            let x = Int(0.5 * scale)
            let y = Int(14 * scale)
            let edge = try XCTUnwrap(selection.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            let hoverEdge = try XCTUnwrap(hover.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            let (high, low) = (max(luminance(edge), luminance(hoverEdge)), min(luminance(edge), luminance(hoverEdge)))
            XCTAssertGreaterThan((high + 0.05) / (low + 0.05), 1.2, "\(appearanceName.rawValue): the edges differ")
            // A focused selection has no outline (`surface.selection` alone).
            let focused = try render(SidebarSelectionBackground(isFocused: true), appearance: appearance)
            let focusedEdge = try XCTUnwrap(focused.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
            let focusedMiddle = try XCTUnwrap(focused.colorAt(x: Int(100 * scale), y: y)?.usingColorSpace(.sRGB))
            XCTAssertEqual(focusedEdge.redComponent, focusedMiddle.redComponent, accuracy: 0.03, "no outline")
        }
    }
}
