import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// TAGS rendered offscreen in light and dark (#377), open and closed. Set `OVERGROVE_SNAPSHOT_DIR`
/// (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep the PNGs.
@MainActor
final class TagListRenderTests: XCTestCase {
    func testRendersInLightAndDark() throws {
        func oid(_ character: Character) -> ObjectID { ObjectID(String(repeating: character, count: 40))! }
        let now = Date()
        func tag(_ name: String, _ commit: Character, annotated: Bool, days: Double) -> Tag {
            Tag(
                fullName: "refs/tags/\(name)", target: annotated ? oid("f") : oid(commit),
                peeledTarget: annotated ? oid(commit) : nil, date: now.addingTimeInterval(-days * 86_400))
        }
        let model = TagListModel(
            tags: [
                tag("v1.4.0", "a", annotated: true, days: 3), tag("v1.4.0-rc.2", "b", annotated: true, days: 12),
                tag("v1.3.2", "c", annotated: false, days: 40), tag("v1.3.1", "d", annotated: true, days: 70),
            ], detachedHeads: [oid("c")])
        let view = VStack(spacing: 0) {
            TagListSection(model: model, selectedCommit: oid("a"), isInitiallyExpanded: true)
            TagListSection(model: model)
            Spacer()
        }
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(
                rootView: view.frame(width: 256, height: 220).background(Tokens.Color.surfacePanel))
            host.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            host.frame = NSRect(x: 0, y: 0, width: 256, height: 220)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("tags-\(name).png"))
            }
        }
    }
}
