import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// #617: a chip's outline (`border.chip`) shows on a selected sidebar row in dark mode, where `border.separator` was
/// the selection colour itself; and the PR pill leaves room between its symbol and the capsule.
@MainActor
final class ChipOutlineRenderTests: XCTestCase {
    private func luminance(_ color: NSColor) -> Double {
        func linear(_ channel: CGFloat) -> Double {
            let value = Double(channel)
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(color.redComponent) + 0.7152 * linear(color.greenComponent)
            + 0.0722 * linear(color.blueComponent)
    }

    private func contrast(_ lhs: NSColor, _ rhs: NSColor) -> Double {
        let (high, low) = (max(luminance(lhs), luminance(rhs)), min(luminance(lhs), luminance(rhs)))
        return (high + 0.05) / (low + 0.05)
    }

    func testAnInertIssueChipIsOutlinedOnASelectedRow() throws {
        let size = CGSize(width: 80, height: 24)
        for appearanceName in [NSAppearance.Name.darkAqua, .aqua] {
            for focused in [true, false] {
                let view = IssueNumberBadge(number: 7)
                    .frame(width: size.width, height: size.height)
                    .background(focused ? Tokens.Color.surfaceSelection : Tokens.Color.surfaceSelectionInactive)
                let host = NSHostingView(rootView: view)
                host.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                let y = bitmap.pixelsHigh / 2
                let background = try XCTUnwrap(bitmap.colorAt(x: 0, y: y)?.usingColorSpace(.sRGB))
                // Scanning in from the left, the first pixel that is not the background is the chip's outline.
                var outline: NSColor?
                for x in 0..<(bitmap.pixelsWide / 2) {
                    let pixel = try XCTUnwrap(bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB))
                    if contrast(pixel, background) > 1.02 {
                        outline = pixel
                        break
                    }
                }
                let found = try XCTUnwrap(outline, "an outline at all [\(appearanceName.rawValue), focused \(focused)]")
                XCTAssertGreaterThanOrEqual(
                    contrast(found, background), 1.25, "\(appearanceName.rawValue), focused \(focused)")
            }
        }
    }

    func testThePullRequestPillMatchesTheRefPillPadding() {
        XCTAssertEqual(PullRequestPill.horizontalPadding, 6, "the ref pill's 6pt, so the symbol clears the curve")
    }
}
