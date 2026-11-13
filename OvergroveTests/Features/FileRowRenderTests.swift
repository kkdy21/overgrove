import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// The one file row every detail file list draws (#577). Rendered offscreen in light and dark; set
/// `OVERGROVE_SNAPSHOT_DIR` (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep the PNGs.
@MainActor
final class FileRowRenderTests: XCTestCase {
    private static let longDirectory = "internal/observability/exporters/otlp/"
    private static let longName = "reporter_configuration.go"

    private var variants: [FileRowView] {
        [
            FileRowView(
                badge: .status(letter: "M", group: .unstaged), directory: "internal/http/", fileName: "middleware.go",
                lineCount: .lines(added: 38, deleted: 4), isSelectable: true, isSelected: false),
            FileRowView(
                badge: .neutral(letter: "A"), directory: "internal/ratelimit/", fileName: "limiter.go",
                lineCount: .lines(added: 112, deleted: 0), isSelectable: true, isSelected: true),
            FileRowView(
                badge: .unknown, directory: "", fileName: "README.md", lineCount: .lines(added: 2, deleted: 1),
                isSelectable: true, isSelected: false),
            FileRowView(
                badge: .status(letter: "?", group: .untracked), directory: "notes/", fileName: "todo.txt",
                lineCount: nil, isSelectable: true, isSelected: false),
            FileRowView(
                badge: .neutral(letter: "M"), directory: "assets/", fileName: "logo.png", lineCount: .binary,
                pill: "WIP", isSelectable: true, isSelected: false),
            FileRowView(
                badge: .neutral(letter: "M"), directory: Self.longDirectory, fileName: Self.longName,
                lineCount: .lines(added: 1_204, deleted: 87), isSelectable: true, isSelected: false),
        ]
    }

    /// design-tokens.md §3.6: every file row is `size.row-file` high, whatever its badge, pill, or counts.
    func testEveryRowIsTheFileRowHeight() {
        for row in variants {
            let host = NSHostingView(rootView: row.frame(width: 300))
            XCTAssertEqual(host.fittingSize.height, Tokens.Size.rowFile, "\(row.fileName)")
        }
    }

    /// A long path at the detail panel's minimum width: the directory loses its leading part, the name stays whole.
    func testRendersInLightAndDark() throws {
        let rows = variants
        let view = VStack(spacing: 0) {
            ForEach(rows.indices, id: \.self) { rows[$0] }
        }
        .padding(.vertical, Tokens.Spacing.sm)
        .background(Tokens.Color.surfaceRaised)
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: view.frame(width: 300))
            host.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            host.frame = NSRect(origin: .zero, size: host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("file-rows-\(name).png"))
            }
        }
    }

    func testLineCountFromNumstat() {
        func stat(_ added: Int?, _ deleted: Int?) -> FileStat {
            FileStat(path: GitPath("a.swift"), added: added, deleted: deleted, isFromUntracked: false)
        }
        XCTAssertEqual(stat(3, 1).lineCount, .lines(added: 3, deleted: 1))
        XCTAssertEqual(stat(nil, nil).lineCount, .binary)
    }
}
