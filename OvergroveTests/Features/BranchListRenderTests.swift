import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// LOCAL and REMOTE rendered offscreen in light and dark (#72). Set `OVERGROVE_SNAPSHOT_DIR`
/// (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep the PNGs.
@MainActor
final class BranchListRenderTests: XCTestCase {
    func testRendersInLightAndDark() throws {
        let tip = ObjectID(String(repeating: "a", count: 40))!
        func branch(_ full: String, _ kind: Branch.Kind, _ upstream: UpstreamStatus = .none) -> Branch {
            Branch(
                fullName: full, kind: kind, target: tip, upstreamStatus: upstream, isHead: false,
                committerDate: Date().addingTimeInterval(-7_200), symbolicTarget: nil)
        }
        let refs = RefParser.Listing(
            branches: [
                branch("refs/heads/main", .local, .tracking(upstream: "refs/remotes/origin/main", ahead: 0, behind: 0)),
                branch(
                    "refs/heads/feat/42-rate-limit", .local,
                    .tracking(upstream: "refs/remotes/origin/feat/42-rate-limit", ahead: 2, behind: 0)),
                branch("refs/heads/old-spike", .local, .gone(upstream: "refs/remotes/origin/old-spike")),
                branch("refs/remotes/origin/main", .remote(remote: "origin")),
            ],
            tags: [], isPartial: false, skippedRecords: 1)
        let model = BranchListModel(refs: refs, checkedOut: ["refs/heads/main"], remoteNames: ["origin"])
        let view = VStack(spacing: 0) {
            BranchListSection(title: "LOCAL", count: model.localCount, nodes: model.local, warning: model.warning)
            BranchListSection(title: "REMOTE", count: model.remoteCount, nodes: model.remote)
            Spacer()
        }
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(
                rootView: view.frame(width: 256, height: 320).background(Tokens.Color.surfacePanel))
            host.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            host.frame = NSRect(x: 0, y: 0, width: 256, height: 320)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("branches-\(name).png"))
            }
        }
    }
}
