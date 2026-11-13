import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// S-09 rendered offscreen in light and dark (#70). Set `OVERGROVE_SNAPSHOT_DIR`
/// (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep the PNGs.
@MainActor
final class FileHistoryRenderTests: XCTestCase {
    func testRendersInLightAndDark() async throws {
        let entries = [
            FileHistoryStoreTests.entry(0), FileHistoryStoreTests.entry(1),
            FileHistoryStoreTests.entry(2, path: "internal/http/middleware.go", from: "internal/mw/middleware.go"),
            FileHistoryStoreTests.entry(3, path: "internal/mw/middleware.go"),
        ]
        let store = FileHistoryStore(
            loader: StubFileHistoryLoader([.page(LogParser.FileHistoryPage(entries: entries, isPartial: false))]))
        store.open(FileHistoryStoreTests.target(path: "internal/http/middleware.go"))
        await store.task?.value
        store.select(entries[0].id)
        let view = FileHistoryView(
            store: store, onBack: {}, onSelect: { _ in }, onOpen: { _ in },
            now: Date(timeIntervalSince1970: 1_793_853_652 + 7_200))
        // 820 shows every column; 480, the centre's minimum, hides Author so the subject reads (#579).
        for (name, appearanceName, width) in [
            ("light", NSAppearance.Name.aqua, 820.0), ("dark", .darkAqua, 820), ("480-light", .aqua, 480),
            ("480-dark", .darkAqua, 480),
        ] {
            let host = NSHostingView(rootView: view.frame(width: width, height: 300))
            host.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            host.frame = NSRect(x: 0, y: 0, width: width, height: 300)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("file-history-\(name).png"))
            }
        }
    }
}
