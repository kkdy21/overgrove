import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// S-03 rendered offscreen in light and dark (#69). Set `OVERGROVE_SNAPSHOT_DIR`
/// (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep the PNGs.
@MainActor
final class CommitDetailRenderTests: XCTestCase {
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
        let detail = CommitDetailModelTests.detail(
            message:
                "feat(ratelimit): add sliding window limiter\n\nUse a sliding window counter per tenant key. Reject with 429 and Retry-After once the window is full.\n\nRefs: #42\nCo-Authored-By: Coding Agent <noreply@anthropic.com>\n",
            files: [
                CommitDetailModelTests.stat("internal/ratelimit/limiter.go", .added, 112, 0),
                CommitDetailModelTests.stat("internal/http/middleware.go", .modified, 38, 4),
                CommitDetailModelTests.stat("cmd/api/main.go", .modified, 6, 2),
                CommitDetailModelTests.stat("assets/logo.png", .modified, nil, nil),
            ])
        let pill = GraphRefPill(
            kind: .focusedBranch, title: "feat/42-rate-limit", hasMatchingRemote: true,
            tooltip: "refs/heads/feat/42-rate-limit")
        let model = CommitDetailModel(
            commit: CommitDetailModelTests.commit(subject: "feat(ratelimit): add sliding window limiter"),
            detail: .loaded(detail), pills: [pill], showsAllFiles: false)
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let bitmap = try render(
                CommitDetailView(
                    model: model, laneIndex: 2, selectedFile: GitPath("internal/http/middleware.go"),
                    onSelectFile: { _ in }),
                size: CGSize(width: 344, height: 640), appearance: appearance)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("commit-\(name).png"))
            }
        }
    }
}
