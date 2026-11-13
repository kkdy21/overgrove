import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// #572: every sidebar row selects the same way. A list without keyboard focus shows `surface.selection-inactive`
/// with `radius.card`, the colour the WORKTREES row already used, instead of an always-blue `radius.md` fill.
@MainActor
final class SidebarRowStyleRenderTests: XCTestCase {
    private func render(_ view: some View, size: CGSize, appearance: NSAppearance) throws -> NSBitmapImageRep {
        let host = NSHostingView(
            rootView: VStack(spacing: 0) { view }.frame(width: size.width, height: size.height, alignment: .top)
                .background(Tokens.Color.surfacePanel))
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
            let png = bitmap.representation(using: .png, properties: [:])
        {
            let name = appearance.name == .darkAqua ? "dark" : "light"
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("sidebar-572-stash-\(name).png"))
        }
        return bitmap
    }

    private func color(_ name: String, in appearance: NSAppearance) throws -> NSColor {
        let named = try XCTUnwrap(NSColor(named: name))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance { resolved = named.usingColorSpace(.sRGB) }
        return try XCTUnwrap(resolved)
    }

    func testAnUnfocusedStashSelectionUsesTheInactiveColour() throws {
        let first = StashDetailModelTests.stash(0, subject: "On main: refill", message: "refill")
        let rows = [
            StashRow(first), StashRow(StashDetailModelTests.stash(1, subject: "On main: spike", message: "spike")),
        ]
        let size = CGSize(width: 256, height: 120)
        for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let bitmap = try render(
                StashListSection(rows: rows, isPartial: false, selectedID: first.oid, onSelect: { _ in }), size: size,
                appearance: appearance)
            let scale = CGFloat(bitmap.pixelsWide) / size.width
            // Header 30pt, then the selected 28pt row; a point at its right end, clear of the text.
            let pixel = try XCTUnwrap(
                bitmap.colorAt(x: Int(240 * scale), y: Int((SidebarSectionHeader.height + 14) * scale))?
                    .usingColorSpace(.sRGB))
            let inactive = try color("Tokens/surfaceSelectionInactive", in: appearance)
            XCTAssertEqual(pixel.redComponent, inactive.redComponent, accuracy: 0.03, "\(appearanceName.rawValue)")
            XCTAssertEqual(pixel.greenComponent, inactive.greenComponent, accuracy: 0.03, "\(appearanceName.rawValue)")
            XCTAssertEqual(pixel.blueComponent, inactive.blueComponent, accuracy: 0.03, "\(appearanceName.rawValue)")
        }
    }
}

/// #572: a branch row stays highlighted only while it is the chosen row and its tip is still selected.
final class BranchRowHighlightTests: XCTestCase {
    private func row(_ name: String, tip: ObjectID?) -> BranchRow {
        let oid = tip ?? ObjectID(String(repeating: "cd", count: 20))!
        let refs = RefParser.Listing(
            branches: [
                Branch(
                    fullName: "refs/heads/\(name)", kind: .local, target: oid, upstreamStatus: .none, isHead: false,
                    committerDate: nil, symbolicTarget: nil)
            ], tags: [], isPartial: false, skippedRecords: 0)
        let model = BranchListModel(refs: refs, checkedOut: [], remoteNames: [])
        guard case .branch(var row) = model.local.first else { fatalError("\(model.local)") }
        row.tip = tip
        return row
    }

    func testHighlightFollowsTheChosenRowAndTheSelectedCommit() {
        let tip = ObjectID(String(repeating: "ab", count: 20))!
        let main = row("main", tip: tip)
        let other = row("other", tip: tip)
        XCTAssertTrue(BranchListSection.isHighlighted(main, chosenID: main.id, selectedCommit: tip))
        XCTAssertFalse(
            BranchListSection.isHighlighted(other, chosenID: main.id, selectedCommit: tip), "same tip, not chosen")
        XCTAssertFalse(
            BranchListSection.isHighlighted(main, chosenID: main.id, selectedCommit: nil), "selection moved on")
        let treeBranch = row("tree", tip: nil)
        XCTAssertFalse(
            BranchListSection.isHighlighted(treeBranch, chosenID: treeBranch.id, selectedCommit: nil),
            "no tip in the graph")
    }
}
