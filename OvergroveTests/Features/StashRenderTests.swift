import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// S-04 and the STASHES section rendered offscreen in light and dark (#71). Set `OVERGROVE_SNAPSHOT_DIR`
/// (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep the PNGs.
@MainActor
final class StashRenderTests: XCTestCase {
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

    func testRendersInLightAndDark() throws {
        let stash = StashDetailModelTests.stash(
            parents: [StashDetailModelTests.base, StashDetailModelTests.index, StashDetailModelTests.untracked])
        let detail = StashDetail(
            stash: stash,
            files: [
                StashDetailModelTests.file("Sources/Parsing/Status.swift", 42, 8),
                StashDetailModelTests.file("Sources/Untracked.swift", 20, 0, untracked: true),
            ],
            isPartial: false)
        let model = StashDetailModel(stash: stash, state: .loaded(detail))
        let rows = [
            StashRow(stash),
            StashRow(StashDetailModelTests.stash(1, subject: "On main: spike notes", message: "spike notes")),
        ]
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let detailBitmap = try render(
                StashDetailView(model: model, selectedFile: nil, onSelectFile: { _ in }),
                size: CGSize(width: 344, height: 480), appearance: appearance)
            let listBitmap = try render(
                StashListSection(rows: rows, isPartial: false, selectedID: stash.oid, onSelect: { _ in })
                    .frame(maxHeight: .infinity, alignment: .top),
                size: CGSize(width: 256, height: 120), appearance: appearance)
            XCTAssertGreaterThan(detailBitmap.pixelsWide, 0)
            XCTAssertGreaterThan(listBitmap.pixelsWide, 0)
            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"] {
                for (part, bitmap) in [("detail", detailBitmap), ("list", listBitmap)] {
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try png.write(
                            to: URL(fileURLWithPath: directory).appendingPathComponent("stash-\(part)-\(name).png"))
                    }
                }
            }
        }
    }

    func testEmptyListRendersNoStashes() throws {
        let bitmap = try render(
            StashListSection(rows: [], isPartial: false, selectedID: nil, onSelect: { _ in }),
            size: CGSize(width: 256, height: 60), appearance: try XCTUnwrap(NSAppearance(named: .aqua)))
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
    }
}
