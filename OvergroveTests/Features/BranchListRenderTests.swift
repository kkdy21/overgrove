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

/// #615: folder and branch rows of one depth start their icons and names on the same x, and one level of indent is
/// the disclosure slot and its gap.
@MainActor
final class BranchTreeLeadTests: XCTestCase {
    private func width(_ lead: BranchTreeLead) -> CGFloat {
        NSHostingView(rootView: lead.fixedSize()).fittingSize.width
    }

    func testFolderAndBranchRowsLineUpAtEveryDepth() throws {
        for depth in 0..<3 {
            let branch = width(BranchTreeLead(depth: depth, disclosure: .none, symbol: "arrow.triangle.branch"))
            let closed = width(BranchTreeLead(depth: depth, disclosure: .closed, symbol: "folder"))
            let open = width(BranchTreeLead(depth: depth, disclosure: .open, symbol: "folder"))
            XCTAssertEqual(branch, closed, accuracy: 0.5, "depth \(depth): the name starts on the same x")
            XCTAssertEqual(open, closed, accuracy: 0.5, "depth \(depth): opening does not move the name")
            let next = width(BranchTreeLead(depth: depth + 1, disclosure: .none, symbol: "arrow.triangle.branch"))
            XCTAssertEqual(next - branch, BranchTreeLead.levelIndent, accuracy: 0.5, "one level")
        }
        XCTAssertEqual(BranchTreeLead.levelIndent, BranchTreeLead.disclosureWidth + Tokens.Spacing.xs)
    }

    /// A filtered tree opens its folders: `feat/` and its child, with `main` and `old-spike` beside it.
    func testAnOpenFolderRenders() throws {
        let tip = ObjectID(String(repeating: "a", count: 40))!
        let refs = RefParser.Listing(
            branches: ["refs/heads/main", "refs/heads/feat/42-rate-limit", "refs/heads/old-spike"].map {
                Branch(
                    fullName: $0, kind: .local, target: tip, upstreamStatus: .none, isHead: false, committerDate: nil,
                    symbolicTarget: nil)
            }, tags: [], isPartial: false, skippedRecords: 0)
        let model = BranchListModel(refs: refs, checkedOut: [], remoteNames: [])
        let view = VStack(spacing: 0) {
            BranchListSection(title: "LOCAL", count: model.localCount, nodes: model.local, isFiltered: true)
            Spacer()
        }
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(
                rootView: view.frame(width: 220, height: 160).background(Tokens.Color.surfacePanel))
            host.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            host.frame = NSRect(x: 0, y: 0, width: 220, height: 160)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("branches-615-\(name).png"))
            }
        }
    }
}
