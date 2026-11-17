import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// The base compare card under S-02 and S-05 (#581): its texts match S-11's, and it renders in every state in light
/// and dark at the detail panel's 300 and 344pt widths. Set `OVERGROVE_SNAPSHOT_DIR`
/// (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep the PNGs.
@MainActor
final class BaseCompareCardTests: XCTestCase {
    private let worktree = GitPath("/tmp/dev/api-wt/agent-logging")
    private let main = FullRefName("refs/heads/main")!
    private let develop = FullRefName("refs/remotes/origin/develop")!

    private var comparison: WorktreeComparison {
        ComparisonModelTests.comparison(
            files: [
                ComparisonModelTests.stat("internal/log/logger.go", .modified, 40, 8),
                ComparisonModelTests.stat("internal/log/requestid.go", .added, 6, 0),
                ComparisonModelTests.stat("logo.png", .modified, nil, nil),
            ],
            counts: .init(behind: 3, ahead: 1))
    }

    private func summary(_ result: ComparisonLoadState, base: FullRefName? = nil) -> BaseCompareSummary {
        BaseCompareSummary(worktree: worktree, base: base ?? main, bases: [main, develop], result: result)
    }

    /// The card shows S-11's ahead/behind, file count, and line totals for the same comparison.
    func testLoadedValuesMatchS11() {
        let card = BaseCompareCardModel(summary: summary(.loaded(comparison)), status: .loaded)
        var session = ComparisonSession(worktree: worktree, base: main)
        session.result = .loaded(comparison)
        let s11 = ComparisonModel(session: session, workingState: nil)
        guard case .loaded(let text, let added, let deleted, let baseCommit) = card.state else {
            return XCTFail("\(card.state)")
        }
        XCTAssertEqual(text, "1 commit ahead · 3 behind · 3 files")
        XCTAssertEqual("+\(added) −\(deleted)", s11.totalLineChange)
        XCTAssertTrue(s11.summary?.hasPrefix("1 commit ahead · 3 behind") == true, s11.summary ?? "")
        XCTAssertTrue(s11.summary?.contains("3 files") == true, s11.summary ?? "")
        XCTAssertEqual(baseCommit, "aaaaaaa")
        XCTAssertEqual(card.baseName, "main")
        XCTAssertEqual(card.bases.map(\.name), ["main", "origin/develop"])
    }

    func testStates() {
        XCTAssertEqual(
            BaseCompareCardModel(summary: summary(.loading), status: .loaded).state, .loading("Comparing with main…"))
        XCTAssertEqual(
            BaseCompareCardModel(summary: summary(.failed(.noBaseBranch), base: nil), status: .loaded).state,
            .noBase("No base branch to compare with."))
        if case .failed(let text) = BaseCompareCardModel(
            summary: summary(.failed(.baseNotFound(develop))), status: .loaded
        ).state {
            XCTAssertFalse(text.isEmpty)
        } else {
            XCTFail("a failure shows its message")
        }
        let waiting = BaseCompareCardModel(summary: nil, status: .pending)
        XCTAssertEqual(waiting.state, .failed("Waiting for this worktree's status."))
        XCTAssertFalse(waiting.canCompare, "Compare with Base… is off until the status loads")
        XCTAssertEqual(BaseCompareCardModel(summary: nil, status: .loaded).baseName, "base branch")
        // A list still loading may already hold this worktree's last comparison: it stays until the status is back.
        XCTAssertEqual(
            BaseCompareCardModel(summary: summary(.loading), status: .pending).state, .loading("Comparing with main…"))
    }

    /// A worktree whose folder is missing (prunable) is never queried, so its status never comes: the card says why
    /// instead of waiting (#684). The same goes for a status that failed or was not queried in this load.
    func testWorktreeWithoutStatusSaysWhyInsteadOfWaiting() {
        let missing = BaseCompareCardModel(summary: nil, status: .missing)
        XCTAssertEqual(missing.state, .failed("The worktree folder is missing, so it cannot be compared."))
        XCTAssertFalse(missing.canCompare)
        // An earlier comparison of the same path (the folder was deleted since) gives way to the reason.
        let deleted = BaseCompareCardModel(summary: summary(.loaded(comparison)), status: .missing)
        XCTAssertEqual(deleted.state, missing.state)
        XCTAssertTrue(deleted.bases.isEmpty, "the base menu is off, as the button")
        let unavailable = BaseCompareCardModel(summary: nil, status: .unavailable)
        XCTAssertEqual(unavailable.state, .failed("This worktree's status is not available, so it cannot be compared."))
        XCTAssertFalse(unavailable.canCompare)
        for state in [missing.state, unavailable.state] {
            XCTAssertNotEqual(state, .failed("Waiting for this worktree's status."))
        }
    }

    /// Which listing states are worth waiting for.
    func testStatusFromTheWorktreeEntry() {
        func entry(_ state: WorktreeListing.State, isPrunable: Bool = false) -> WorktreeListing.Entry {
            WorktreeListing.entry(worktree.display, branch: "spike/prunable", isPrunable: isPrunable, state: state)
        }
        typealias Status = BaseCompareCardModel.WorktreeStatus
        XCTAssertEqual(Status(nil), .pending, "the list is still loading")
        XCTAssertEqual(Status(entry(.loaded(WorktreeListing.state(branch: "spike/prunable")))), .loaded)
        XCTAssertEqual(Status(entry(.missing, isPrunable: true)), .missing)
        XCTAssertEqual(Status(entry(.failed(.timeout(seconds: 10)))), .unavailable)
        XCTAssertEqual(Status(entry(.notQueried(.duplicate))), .unavailable)
    }

    /// Detached HEAD: no ahead/behind counts, only the commits ahead (as S-11).
    func testDetachedShowsCommitsAhead() {
        let detached = ComparisonModelTests.comparison(
            files: [ComparisonModelTests.stat("a.swift", .modified, 1, 0)], counts: nil)
        guard
            case .loaded(let text, _, _, _) = BaseCompareCardModel(
                summary: summary(.loaded(detached)), status: .loaded
            ).state
        else { return XCTFail() }
        XCTAssertEqual(text, "0 commits ahead · 1 file")
    }

    func testRendersEveryStateInLightAndDark() throws {
        let states: [(String, BaseCompareCardModel)] = [
            ("loaded", BaseCompareCardModel(summary: summary(.loaded(comparison)), status: .loaded)),
            ("loading", BaseCompareCardModel(summary: summary(.loading), status: .loaded)),
            ("no-base", BaseCompareCardModel(summary: summary(.failed(.noBaseBranch), base: nil), status: .loaded)),
            ("failed", BaseCompareCardModel(summary: summary(.failed(.baseNotFound(develop))), status: .loaded)),
            ("waiting", BaseCompareCardModel(summary: nil, status: .pending)),
            ("missing", BaseCompareCardModel(summary: nil, status: .missing)),
        ]
        let view = VStack(spacing: Tokens.Spacing.md) {
            ForEach(states.indices, id: \.self) { index in
                BaseCompareCard(model: states[index].1, onChooseBase: { _ in }, onCompare: {})
            }
        }
        .padding(Tokens.Spacing.md)
        .background(Tokens.Color.surfacePanel)
        for width in [300, 344] {
            for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                let host = NSHostingView(rootView: view.frame(width: CGFloat(width)))
                host.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
                host.frame = NSRect(origin: .zero, size: host.fittingSize)
                host.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: bitmap)
                XCTAssertGreaterThan(bitmap.pixelsWide, 0)
                try keep(bitmap, "base-compare-card-\(width)-\(name)")
            }
        }
    }

    /// S-02 with the card pinned at the bottom: the file list scrolls above it.
    func testPinnedUnderTheWipDetail() throws {
        let state = WorkingState(
            headCommit: ObjectID(String(repeating: "b", count: 40)), head: .branch("agent/refactor-logging"),
            upstream: .none, stashCount: 0,
            staged: (0..<14).map { FileChange(path: GitPath("internal/log/file\($0).go"), status: .modified) },
            unstaged: [], untracked: [], conflicted: [], isPartial: false, skippedRecords: 0)
        let wip = WipDetailModel(
            entry: WorktreeListing.entry(worktree.display, branch: "agent/refactor-logging", state: .loaded(state)),
            home: "/tmp/dev")
        let card = BaseCompareCardModel(summary: summary(.loaded(comparison)), status: .loaded)
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let panel = DetailPanel(focusedWorktree: nil, wipModel: wip, compareCard: card)
            let host = NSHostingView(
                rootView: panel.frame(width: 300, height: 560).background(Tokens.Color.surfacePanel))
            host.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            host.frame = NSRect(x: 0, y: 0, width: 300, height: 560)
            host.layoutSubtreeIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            try keep(bitmap, "s02-compare-card-\(name)")
        }
    }

    private func keep(_ bitmap: NSBitmapImageRep, _ name: String) throws {
        if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
            let png = bitmap.representation(using: .png, properties: [:])
        {
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }
}
