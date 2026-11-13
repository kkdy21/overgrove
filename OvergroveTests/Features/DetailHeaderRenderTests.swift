import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// The detail panel's header at its 300 pt minimum (#578): the worktree tile, a long branch name beside the small
/// `Changes | Worktree` segment, and a commit's avatar mark. Set `OVERGROVE_SNAPSHOT_DIR`
/// (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep the PNGs.
@MainActor
final class DetailHeaderRenderTests: XCTestCase {
    private func render(_ view: some View, name: String) throws {
        let size = CGSize(width: 300, height: 120)
        for (mode, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(
                rootView: view.frame(width: size.width, height: size.height).background(Tokens.Color.surfaceCanvas))
            host.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            host.frame = NSRect(origin: .zero, size: size)
            host.layoutSubtreeIfNeeded()
            // The segment's size follows the measured width, which lands after the first layout.
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name)-\(mode).png"))
            }
        }
    }

    func testWorktreeHeaderAtTheMinimumWidth() throws {
        let worktree = FocusedWorktree(
            branch: "agent/2026-11-13-sidebar-remote-ids", headShortSHA: "a91f3c2", ahead: 0, behind: 0,
            hasUpstream: false)
        try render(
            DetailPanel(focusedWorktree: worktree, showsWorktreeSegment: false, worktreeLane: 2),
            name: "detail-header-worktree-300")
    }

    /// #618: at 300–339 pt the `Changes | Worktree` segment shows icons only, so it is narrower than the small text
    /// segment and the title gets that much more room.
    func testIconSegmentLeavesTheTitleMoreRoom() {
        func width(iconsOnly: Bool) -> CGFloat {
            let host = NSHostingView(
                rootView: DetailSegmentPicker(isWorktree: false, onChanges: {}, onWorktree: {}, iconsOnly: iconsOnly)
                    .controlSize(.small))
            host.layoutSubtreeIfNeeded()
            return host.fittingSize.width
        }
        let text = width(iconsOnly: false)
        let icons = width(iconsOnly: true)
        XCTAssertGreaterThan(text - icons, 20, "icons \(icons) pt vs text \(text) pt")
    }

    private func segmentedControls(in view: NSView) -> [NSSegmentedControl] {
        (view as? NSSegmentedControl).map { [$0] } ?? view.subviews.flatMap(segmentedControls(in:))
    }

    /// #635: the real segmented control drew each icon segment's name as text beside the icon, so the icons-only
    /// segment does not use one; it is two buttons with only the icon drawn.
    func testIconSegmentIsNotASegmentedControl() {
        let host = NSHostingView(
            rootView: DetailSegmentPicker(isWorktree: false, onChanges: {}, onWorktree: {}, iconsOnly: true)
                .controlSize(.small))
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 40)
        host.layoutSubtreeIfNeeded()
        XCTAssertEqual(segmentedControls(in: host).count, 0)
    }

    /// #635: after the icons-only segment, the text segment is a fresh control with titles and no icons left over.
    func testTextSegmentAfterIconsHasNoIcons() throws {
        let host = NSHostingView(
            rootView: AnyView(
                DetailSegmentPicker(isWorktree: false, onChanges: {}, onWorktree: {}, iconsOnly: true)
                    .controlSize(.small)))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 40)
        host.layoutSubtreeIfNeeded()
        host.rootView = AnyView(
            DetailSegmentPicker(isWorktree: false, onChanges: {}, onWorktree: {}, iconsOnly: false))
        host.layoutSubtreeIfNeeded()
        let control = try XCTUnwrap(segmentedControls(in: host).first)
        XCTAssertEqual(control.segmentCount, 2)
        XCTAssertEqual((0..<2).map { control.label(forSegment: $0) }, ["Changes", "Worktree"])
        XCTAssertEqual((0..<2).map { control.image(forSegment: $0) == nil }, [true, true])
    }

    func testIconSegmentSelected() throws {
        try render(
            DetailSegmentPicker(isWorktree: true, onChanges: {}, onWorktree: {}, iconsOnly: true).controlSize(.small),
            name: "detail-icon-segment")
    }

    func testEmptyHeader() throws {
        try render(DetailPanel(focusedWorktree: nil), name: "detail-header-empty-300")
    }
}
