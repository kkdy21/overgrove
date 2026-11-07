import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// S-10 rendered offscreen in light and dark (#232). Set `OVERGROVE_SNAPSHOT_DIR`
/// (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep the PNGs.
@MainActor
final class DiffViewerRenderTests: XCTestCase {
    private static let size = CGSize(width: 900, height: 420)

    /// The screens.md S-10 example.
    private var document: DiffDocument {
        let patch = """
            diff --git a/Sources/Parsing/Status.swift b/Sources/Parsing/Status.swift
            --- a/Sources/Parsing/Status.swift
            +++ b/Sources/Parsing/Status.swift
            @@ -40,4 +40,5 @@ struct StatusParser
                 func parse(_ data: Data) -> [FileChange] {
            -        let lines = data.split(separator: 0x0A)
            +        let records = data.split(separator: 0x00)
            +        // porcelain v2 records are NUL-terminated
                     var result: [FileChange] = []
                     return result

            """
        return DiffDocument(
            listing: try! PatchParser.parse(Data(patch.utf8)), path: GitPath("Sources/Parsing/Status.swift"),
            source: DiffDocument.Source(label: "Staged", kindLetter: "M"))
    }

    private func render(_ view: some View, appearance: NSAppearance) throws -> NSBitmapImageRep {
        let host = NSHostingView(
            rootView: view.frame(width: Self.size.width, height: Self.size.height).background(
                Tokens.Color.surfaceCanvas))
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: Self.size)
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

    func testRendersInLightAndDark() throws {
        let document = document
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let view = DiffViewerView(
                title: document.title, sourceLabel: "Staged · M", state: .loaded(document), onBack: {})
            let bitmap = try render(view, appearance: appearance)
            let scale = CGFloat(bitmap.pixelsWide) / Self.size.width

            // A removed row's background reaches the right edge (rows span the width): scan the column there.
            let expected = try color("Tokens/diffRemovedBg", in: appearance)
            let column = Int((Self.size.width - 20) * scale)
            let found = (0..<bitmap.pixelsHigh).contains { y in
                guard let pixel = bitmap.colorAt(x: column, y: y)?.usingColorSpace(.sRGB) else { return false }
                return abs(pixel.redComponent - expected.redComponent) < 0.03
                    && abs(pixel.greenComponent - expected.greenComponent) < 0.03
                    && abs(pixel.blueComponent - expected.blueComponent) < 0.03
            }
            XCTAssertTrue(found, "\(name): the removed row's background reaches the right edge")

            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("diff-viewer-\(name).png"))
            }
        }
    }

    func testStatesRender() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let large = (1...(DiffDocument.largeLineThreshold + 1)).map { "+\($0)" }.joined(separator: "\n")
        let largeDocument = DiffDocument(
            listing: try PatchParser.parse(
                Data(
                    "diff --git a/f b/f\n--- /dev/null\n+++ b/f\n@@ -0,0 +1,\(DiffDocument.largeLineThreshold + 1) @@\n\(large)\n"
                        .utf8)),
            path: GitPath("f"), source: DiffDocument.Source(label: "Untracked", kindLetter: "?"))
        for state: DiffLoadState in [.loading, .unavailable("Could not read the diff."), .loaded(largeDocument)] {
            let bitmap = try render(
                DiffViewerView(title: "f", sourceLabel: "Untracked", state: state, onBack: {}), appearance: appearance)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        }
    }
}
