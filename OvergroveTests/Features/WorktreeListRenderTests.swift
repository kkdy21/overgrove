import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// The WORKTREES section rendered offscreen in light and dark (#65). Set `OVERGROVE_SNAPSHOT_DIR`
/// (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep the PNGs.
@MainActor
final class WorktreeListRenderTests: XCTestCase {
    private func render(_ view: some View, appearance: NSAppearance) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: 256, height: 340).background(Tokens.Color.surfacePanel))
        host.appearance = appearance
        host.frame = NSRect(x: 0, y: 0, width: 256, height: 340)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func color(_ name: String, in appearance: NSAppearance) throws -> NSColor {
        let named = try XCTUnwrap(NSColor(named: name))
        var resolved: NSColor?
        appearance.performAsCurrentDrawingAppearance { resolved = named.usingColorSpace(.sRGB) }
        return try XCTUnwrap(resolved)
    }

    func testSectionRendersInLightAndDark() throws {
        let model = WorktreeListModel(
            listing: .mockup, focused: GitPath("/tmp/dev/api-wt/42-rate-limit"), home: "/tmp/dev")
        // In a stack, as the sidebar holds it: the section is a `Section` with a pinned header (#573).
        let section = VStack(spacing: 0) {
            WorktreeListSection(
                status: .loaded(.mockup), model: model, selectedPath: GitPath("/tmp/dev/api-wt/42-rate-limit"),
                onSelect: { _ in })
        }
        .frame(maxHeight: .infinity, alignment: .top)

        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let bitmap = try render(section, appearance: appearance)

            // Header 30, then 46pt rows: the selected row (second) is filled with the inactive selection colour.
            let scale = CGFloat(bitmap.pixelsWide) / 256
            let selected = try XCTUnwrap(
                bitmap.colorAt(x: Int(200 * scale), y: Int((30 + 46 + 4) * scale))?.usingColorSpace(.sRGB))
            let expected = try color("Tokens/surfaceSelectionInactive", in: appearance)
            XCTAssertEqual(selected.redComponent, expected.redComponent, accuracy: 0.04, "\(name) selection")
            XCTAssertEqual(selected.blueComponent, expected.blueComponent, accuracy: 0.04, "\(name) selection")

            // Below the six rows the panel colour shows.
            let empty = try XCTUnwrap(
                bitmap.colorAt(x: Int(128 * scale), y: Int(335 * scale))?.usingColorSpace(.sRGB))
            let panel = try color("Tokens/surfacePanel", in: appearance)
            XCTAssertEqual(empty.redComponent, panel.redComponent, accuracy: 0.03, "\(name) panel")

            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("worktree-list-\(name).png"))
            }
        }
    }

    func testLoadingAndFailureStatesRender() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        for status in [WorktreeListStatus.loading, .failed(message: "This folder is not a Git repository.")] {
            let bitmap = try render(
                WorktreeListSection(status: status, model: nil, selectedPath: nil, onSelect: { _ in }),
                appearance: appearance)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        }
    }
}
