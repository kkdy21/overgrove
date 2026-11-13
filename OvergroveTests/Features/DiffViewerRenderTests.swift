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
            listing: TestFixtures.patch(patch), path: GitPath("Sources/Parsing/Status.swift"),
            source: DiffDocument.Source(label: "Staged", kindLetter: "M"))
    }

    /// Renders, letting the run loop turn until `ready` holds (rows are built off the main thread) or 3 s pass.
    private func render(
        _ view: some View, appearance: NSAppearance, size: CGSize = DiffViewerRenderTests.size,
        until ready: (NSBitmapImageRep) -> Bool
    ) throws -> NSBitmapImageRep {
        let host = NSHostingView(
            rootView: view.frame(width: size.width, height: size.height).background(Tokens.Color.surfaceCanvas))
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: size)
        let deadline = Date().addingTimeInterval(3)
        while true {
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if ready(bitmap) || Date() > deadline { return bitmap }
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
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
            // A removed row's background reaches the right edge (rows span the width): scan the column there.
            let expected = try color("Tokens/diffRemovedBg", in: appearance)
            func hasRemovedRow(_ bitmap: NSBitmapImageRep) -> Bool {
                let column = Int((Self.size.width - 20) * CGFloat(bitmap.pixelsWide) / Self.size.width)
                return (0..<bitmap.pixelsHigh).contains { y in
                    guard let pixel = bitmap.colorAt(x: column, y: y)?.usingColorSpace(.sRGB) else { return false }
                    return abs(pixel.redComponent - expected.redComponent) < 0.03
                        && abs(pixel.greenComponent - expected.greenComponent) < 0.03
                        && abs(pixel.blueComponent - expected.blueComponent) < 0.03
                }
            }
            let bitmap = try render(view, appearance: appearance, until: hasRemovedRow)
            XCTAssertTrue(hasRemovedRow(bitmap), "\(name): the removed row's background reaches the right edge")

            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("diff-viewer-\(name).png"))
            }
        }
    }

    /// Word highlights and `Show Whitespace` (#387): TABs, trailing spaces, and a CR drawn as marks.
    func testWordHighlightsAndWhitespaceRender() throws {
        let patch =
            "diff --git a/a.go b/a.go\n--- a/a.go\n+++ b/a.go\n@@ -1,3 +1,3 @@\n"
            + " func limit() {\n-\treturn rate.New(10, time.Second)  \r\n+\treturn rate.New(25, time.Minute)\n }\n"
        let document = DiffDocument(
            listing: TestFixtures.patch(patch), path: GitPath("a.go"),
            source: DiffDocument.Source(label: "Unstaged", kindLetter: "M"))
        let key = "diffShowsWhitespace"
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let view = DiffViewerView(
                title: document.title, sourceLabel: "Unstaged · M", state: .loaded(document), onBack: {})
            func matches(_ pixel: NSColor?, _ expected: NSColor) -> Bool {
                guard let pixel = pixel?.usingColorSpace(.sRGB) else { return false }
                return abs(pixel.redComponent - expected.redComponent) < 0.03
                    && abs(pixel.greenComponent - expected.greenComponent) < 0.03
                    && abs(pixel.blueComponent - expected.blueComponent) < 0.03
            }
            // Ready once the rows are drawn (the removed row's background reaches the right edge).
            let removed = try color("Tokens/diffRemovedBg", in: appearance)
            let bitmap = try render(view, appearance: appearance) { bitmap in
                let column = Int((Self.size.width - 20) * CGFloat(bitmap.pixelsWide) / Self.size.width)
                return (0..<bitmap.pixelsHigh).contains { matches(bitmap.colorAt(x: column, y: $0), removed) }
            }
            let word = try color("Tokens/diffRemovedWordBg", in: appearance)
            func hasWordMark(_ bitmap: NSBitmapImageRep) -> Bool {
                stride(from: 0, to: bitmap.pixelsHigh, by: 2).contains { y in
                    stride(from: 0, to: bitmap.pixelsWide / 2, by: 2).contains { x in
                        matches(bitmap.colorAt(x: x, y: y), word)
                    }
                }
            }
            XCTAssertTrue(hasWordMark(bitmap), "\(name): a changed word is highlighted")
            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("diff-words-\(name).png"))
            }
        }
    }

    /// Split fits the default centre width (#579): each side takes half of it, so the "after" side starts just right
    /// of the middle instead of past a 520 pt "before" side, and a line longer than its side wraps rather than
    /// running off the edge.
    func testSplitFitsTheDefaultCentreWidth() throws {
        let size = CGSize(width: 808, height: 420)
        let long = String(repeating: "abcdefgh ", count: 20)
        let patch =
            "diff --git a/a.go b/a.go\n--- a/a.go\n+++ b/a.go\n@@ -1,1 +1,1 @@\n-old \(long)\n+new \(long)\n"
        let document = DiffDocument(
            listing: TestFixtures.patch(patch), path: GitPath("a.go"),
            source: DiffDocument.Source(label: "Unstaged", kindLetter: "M"))
        let key = "diffViewMode"
        let previous = UserDefaults.standard.object(forKey: key)
        UserDefaults.standard.set(true, forKey: key)
        defer { UserDefaults.standard.set(previous, forKey: key) }
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        let added = try color("Tokens/diffAddedBg", in: appearance)
        func isAdded(_ bitmap: NSBitmapImageRep, x: CGFloat, y: Int) -> Bool {
            let column = Int(x * CGFloat(bitmap.pixelsWide) / size.width)
            guard let pixel = bitmap.colorAt(x: column, y: y)?.usingColorSpace(.sRGB) else { return false }
            return abs(pixel.redComponent - added.redComponent) < 0.03
                && abs(pixel.greenComponent - added.greenComponent) < 0.03
                && abs(pixel.blueComponent - added.blueComponent) < 0.03
        }
        func addedHeight(_ bitmap: NSBitmapImageRep, x: CGFloat) -> CGFloat {
            let rows = (0..<bitmap.pixelsHigh).filter { isAdded(bitmap, x: x, y: $0) }.count
            return CGFloat(rows) * size.height / CGFloat(bitmap.pixelsHigh)
        }
        let view = DiffViewerView(
            title: document.title, sourceLabel: "Unstaged · M", state: .loaded(document), onBack: {})
        let bitmap = try render(view, appearance: appearance, size: size) { addedHeight($0, x: size.width - 20) > 0 }
        XCTAssertGreaterThan(addedHeight(bitmap, x: size.width / 2 + 12), 0, "the after side starts at the middle")
        XCTAssertGreaterThan(addedHeight(bitmap, x: size.width - 20), 30, "the long line wraps within its side")
        if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
            let png = bitmap.representation(using: .png, properties: [:])
        {
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("diff-split-808.png"))
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
