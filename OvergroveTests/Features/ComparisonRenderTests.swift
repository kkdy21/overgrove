import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// S-11 rendered offscreen in light and dark (#158). Set `OVERGROVE_SNAPSHOT_DIR`
/// (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep the PNGs.
@MainActor
final class ComparisonRenderTests: XCTestCase {
    private var session: ComparisonSession {
        var session = ComparisonSession(
            worktree: GitPath("/tmp/dev/api-wt/42"), base: FullRefName("refs/heads/main"),
            bases: [FullRefName("refs/heads/main")!])
        session.result = .loaded(
            ComparisonModelTests.comparison(
                files: [
                    ComparisonModelTests.stat("internal/http/middleware.go", .modified, 30, 4),
                    ComparisonModelTests.stat("internal/ratelimit/limiter.go", .added, 120, nil),
                    ComparisonModelTests.stat(
                        "internal/http/pass.go", .renamed(score: 90), 2, 1, from: "internal/http/noop.go"),
                ],
                untracked: ["docs/rate-limit.md"],
                commits: [
                    ComparisonModelTests.commit("b", "feat(ratelimit): add sliding window limiter"),
                    ComparisonModelTests.commit("c", "test(ratelimit): cover burst and refill"),
                ]))
        return session
    }

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
        let session = session
        let model = ComparisonModel(session: session, workingState: nil)
        XCTAssertEqual(model.state, .loaded)
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let center = try render(
                ComparisonCenterView(
                    session: session, model: model, onBack: {}, onChooseBase: { _ in }, onIncludeUncommitted: { _ in }),
                size: CGSize(width: 900, height: 300), appearance: appearance)
            let list = try render(
                ComparisonListView(
                    title: "feat/42", session: session, model: model, onSelect: { _ in }, onShowAll: {}),
                size: CGSize(width: 344, height: 520), appearance: appearance)
            XCTAssertGreaterThan(center.pixelsWide, 0)
            XCTAssertGreaterThan(list.pixelsWide, 0)
            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"] {
                for (part, bitmap) in [("center", center), ("list", list)] {
                    if let png = bitmap.representation(using: .png, properties: [:]) {
                        try png.write(
                            to: URL(fileURLWithPath: directory).appendingPathComponent("comparison-\(part)-\(name).png")
                        )
                    }
                }
            }
        }
    }

    func testStatesRender() throws {
        let appearance = try XCTUnwrap(NSAppearance(named: .aqua))
        for result: ComparisonLoadState in [
            .loading, .failed(.noBaseBranch), .loaded(ComparisonModelTests.comparison(files: [])),
        ] {
            var session = session
            session.result = result
            let model = ComparisonModel(session: session, workingState: nil)
            let bitmap = try render(
                ComparisonCenterView(
                    session: session, model: model, onBack: {}, onChooseBase: { _ in }, onIncludeUncommitted: { _ in }),
                size: CGSize(width: 900, height: 300), appearance: appearance)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        }
    }

    /// #374: a stale S-11 (the worktree list failed to load) renders dimmed under its notice, in light and dark.
    func testStaleComparisonRenders() throws {
        let session = session
        let model = ComparisonModel(session: session, workingState: nil, isListStale: true)
        XCTAssertEqual(model.staleNotice, ComparisonModel.listFailedNotice)
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let center = try render(
                ComparisonCenterView(
                    session: session, model: model, onBack: {}, onChooseBase: { _ in }, onIncludeUncommitted: { _ in }),
                size: CGSize(width: 900, height: 300), appearance: appearance)
            XCTAssertGreaterThan(center.pixelsWide, 0)
            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                let png = center.representation(using: .png, properties: [:])
            {
                try png.write(
                    to: URL(fileURLWithPath: directory).appendingPathComponent("comparison-stale-\(name).png"))
            }
        }
    }
}
