import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// S-12 rendered offscreen in light and dark (#388): the center with a file's patch and the detail list. Set
/// `OVERGROVE_SNAPSHOT_DIR` (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep the PNGs.
@MainActor
final class CommitComparisonRenderTests: XCTestCase {
    func testRendersInLightAndDark() throws {
        let commits = Dictionary(uniqueKeysWithValues: SampleGraphLoader.commits.map { ($0.oid, $0) })
        var session = CommitComparisonSession(base: SampleGraphLoader.oid("4"), target: SampleGraphLoader.oid("1"))
        session.files = .loaded(
            NumstatParser.Files(
                files: [
                    CommitDetailModelTests.stat("internal/http/middleware.go", .modified, 38, 4),
                    CommitDetailModelTests.stat("internal/ratelimit/limiter.go", .added, 112, 0),
                ], isPartial: false))
        session.selectedFile = GitPath("internal/http/middleware.go")
        session.patch = .loaded(
            DiffDocument(
                listing: TestFixtures.patch(
                    "diff --git a/m.go b/m.go\n--- a/m.go\n+++ b/m.go\n@@ -8,3 +8,4 @@ import (\n"
                        + " \t\"net/http\"\n-\t\"time\"\n+\t\"time\"\n+\t\"github.com/acme/api/internal/ratelimit\"\n )\n"
                ),
                path: GitPath("internal/http/middleware.go"),
                source: DiffDocument.Source(label: "\(session.base.short) → \(session.target.short)", kindLetter: "M")))
        let model = CommitComparisonModel(session: session) { commits[$0] }
        let view = HStack(spacing: 0) {
            CommitComparisonCenterView(session: session, model: model, onBack: {}, onSwap: {})
                .frame(width: 640)
            Tokens.Color.borderSeparator.frame(width: 1)
            CommitComparisonListView(
                session: session, model: model, onSelectFile: { _ in }, onShowAll: {}, onShowCommit: { _ in }
            )
            .frame(width: 340)
        }
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(
                rootView: view.frame(width: 981, height: 360).background(Tokens.Color.surfacePanel))
            host.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            host.frame = NSRect(x: 0, y: 0, width: 981, height: 360)
            let deadline = Date().addingTimeInterval(2)
            var bitmap: NSBitmapImageRep
            repeat {
                host.layoutSubtreeIfNeeded()
                bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            } while Date() < deadline
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("s12-compare-\(name).png"))
            }
        }
    }
}
