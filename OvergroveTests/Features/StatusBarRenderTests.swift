import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// The status bar at the window's minimum width and narrower (#575): every field on one line, Read-only and gh whole.
/// Set `OVERGROVE_SNAPSHOT_DIR` (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep the PNGs.
@MainActor
final class StatusBarRenderTests: XCTestCase {
    /// A crowded bar: a failed fetch with details, the focused worktree's fields, and a long gh account.
    private let items = [
        StatusBarItem(kind: .readOnly, text: "Read-only", symbol: "checkmark.shield", tone: .ok),
        StatusBarItem(
            kind: .fetch, text: "Last fetched 3 h ago · last attempt failed — Details",
            symbol: "exclamationmark.triangle", tone: .warning),
        StatusBarItem(
            kind: .aheadBehind, text: "fix/57-token-refresh ↑12 ↓3", symbol: "arrow.up.arrow.down", tone: .neutral),
        StatusBarItem(kind: .worktrees, text: "6 worktrees", symbol: "square.stack.3d.up", tone: .neutral),
        StatusBarItem(kind: .prunable, text: "2 prunable", symbol: "trash", tone: .warning),
        StatusBarItem(
            kind: .gh, text: "gh: mina-lee@ghe.example +1", symbol: "person.crop.circle.badge.checkmark", tone: .ok),
    ]

    func testReadOnlyAndGhKeepTheirTextAndFetchGivesWayFirst() {
        func priority(_ kind: StatusBarItem.Kind) -> Double {
            StatusBarItem(kind: kind, text: "", symbol: nil, tone: .neutral).layoutPriority
        }
        XCTAssertEqual(priority(.readOnly), priority(.gh))
        for kind: StatusBarItem.Kind in [.refreshing, .slowStatus, .worktrees, .prunable] {
            XCTAssertLessThan(priority(kind), priority(.readOnly), "\(kind)")
            XCTAssertGreaterThan(priority(kind), priority(.aheadBehind), "short fields stay whole: \(kind)")
        }
        XCTAssertGreaterThan(priority(.aheadBehind), priority(.fetch))
    }

    /// The window's minimum (1040 pt) folded the fetch text onto two lines; 640 pt cut the gh login mid-word.
    func testEveryFieldStaysOnOneLine() throws {
        for width: CGFloat in [1_040, 640] {
            for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let size = CGSize(width: width, height: Tokens.Size.statusBar)
                let bar = StatusBar(items: items, onFetchDetails: {}, onGitHubSetup: {})
                let host = NSHostingView(rootView: bar.frame(width: size.width, height: size.height))
                host.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                host.frame = NSRect(origin: .zero, size: size)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)

                // The rows that carry any ink: one line of caption text and its icons is about 13 pt tall, two lines
                // more than 20.
                let background = try XCTUnwrap(bitmap.colorAt(x: bitmap.pixelsWide - 2, y: 1)?.usingColorSpace(.sRGB))
                let inked = (0..<bitmap.pixelsHigh).filter { y in
                    stride(from: 0, to: bitmap.pixelsWide, by: 2).contains { x in
                        guard let pixel = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { return false }
                        return abs(pixel.redComponent - background.redComponent)
                            + abs(pixel.greenComponent - background.greenComponent)
                            + abs(pixel.blueComponent - background.blueComponent) > 0.3
                    }
                }
                let scale = CGFloat(bitmap.pixelsHigh) / size.height
                let extent = CGFloat((inked.max() ?? 0) - (inked.min() ?? 0) + 1) / scale
                XCTAssertLessThan(extent, 18, "\(Int(width)) pt \(name): one line of fields")

                if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                    let png = bitmap.representation(using: .png, properties: [:])
                {
                    try png.write(
                        to: URL(fileURLWithPath: directory).appendingPathComponent(
                            "status-bar-\(Int(width))-\(name).png"))
                }
            }
        }
    }
}
