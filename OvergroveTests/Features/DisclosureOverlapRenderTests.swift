import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// Rows below a disclosure are opaque (#638): drawn over a magenta backdrop, no magenta shows through a row, a notice,
/// an empty text, or the gaps between a detail card's items, so they cover the rows a disclosure inserts while they
/// slide down.
@MainActor
final class DisclosureOverlapRenderTests: XCTestCase {
    private func render(_ view: some View, width: CGFloat, appearance: NSAppearance) throws -> NSBitmapImageRep {
        let host = NSHostingView(
            rootView: view.frame(width: width).fixedSize(horizontal: false, vertical: true)
                .background(Color(red: 1, green: 0, blue: 1)))
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: CGSize(width: width, height: host.fittingSize.height))
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    /// The sidebar's stack (`PanelChrome`): no spacing between rows, headers pinned.
    private func sidebarStack(@ViewBuilder _ content: () -> some View) -> some View {
        LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders, content: content)
    }

    /// The share of the pixels that are the magenta backdrop, as the same renderer draws it with nothing on top.
    private func magentaShare(_ bitmap: NSBitmapImageRep) throws -> Double {
        let backdrop = try render(Color.clear.frame(height: 4), width: 4, appearance: NSAppearance(named: .aqua)!)
        let reference = try XCTUnwrap(backdrop.colorAt(x: 1, y: 1))
        func near(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.02 }
        var magenta = 0
        var total = 0
        for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
            for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                guard let color = bitmap.colorAt(x: x, y: y) else { continue }
                total += 1
                if near(color.redComponent, reference.redComponent),
                    near(color.greenComponent, reference.greenComponent),
                    near(color.blueComponent, reference.blueComponent)
                {
                    magenta += 1
                }
            }
        }
        return total == 0 ? 1 : Double(magenta) / Double(total)
    }

    /// The check sees the backdrop where nothing covers it.
    func testTheBackdropShowsThroughPlainText() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let bitmap = try render(
            VStack(spacing: Tokens.Spacing.sm) {
                Text("Hooks")
                Text("Filters")
            }, width: 300, appearance: appearance)
        XCTAssertGreaterThan(try magentaShare(bitmap), 0.5)
    }

    func testSidebarRowsAndNoticesCoverWhatIsBehindThem() throws {
        let rows = [
            StashRow(StashDetailModelTests.stash(0, subject: "On main: wip", message: "wip")),
            StashRow(StashDetailModelTests.stash(1, subject: "On main: spike notes", message: "spike notes")),
        ]
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let stashes = try render(
                sidebarStack { StashListSection(rows: rows, isPartial: true, selectedID: nil, onSelect: { _ in }) },
                width: 256, appearance: appearance)
            let empty = try render(
                sidebarStack { StashListSection(rows: [], isPartial: false, selectedID: nil, onSelect: { _ in }) },
                width: 256, appearance: appearance)
            let notice = try render(
                SidebarNotice(symbol: "exclamationmark.triangle", text: "Some stashes could not be listed."),
                width: 256, appearance: appearance)
            for (part, bitmap) in [("stashes", stashes), ("empty", empty), ("notice", notice)] {
                XCTAssertEqual(try magentaShare(bitmap), 0, "\(part) \(name.rawValue)")
            }
        }
    }

    func testDetailCardItemsCoverTheGapsBetweenThem() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let card = try render(
                VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
                    ForEach(["Hooks", "Filters", "Values are never shown."], id: \.self) { text in
                        Text(text).frame(maxWidth: .infinity, alignment: .leading).cardOpaque()
                    }
                }
                .padding(.vertical, Tokens.Spacing.sm / 2),
                width: 300, appearance: appearance)
            XCTAssertEqual(try magentaShare(card), 0, name.rawValue)
        }
    }
}
