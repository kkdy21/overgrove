import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// Sixteen branches off one root: wider than `size.graph-max-lanes-visible`.
struct WideGraphLoader: GraphLoading {
    static let branchCount = 16

    static func oid(_ index: Int) -> ObjectID { ObjectID(String(format: "%040x", 0xb000 + index))! }

    static let root = CommitNode(
        oid: oid(999), parents: [], authorName: "Alice Example", authorEmail: "alice@example.com",
        authorDate: Date(timeIntervalSince1970: 1_700_000_000), subject: "chore: initial import")

    static let commits: [CommitNode] =
        (0..<branchCount).map { index in
            CommitNode(
                oid: oid(index), parents: [root.oid], authorName: "Author \(index % 7)",
                authorEmail: "a\(index % 7)@example.com",
                authorDate: Date(timeIntervalSince1970: 1_800_000_000 - Double(index) * 600),
                subject: "feat: branch \(index)")
        } + [root]

    static let refs = RefParser.Listing(
        branches: (0..<branchCount).map { index in
            Branch(
                fullName: "refs/heads/topic/\(index)", kind: .local, target: oid(index), upstreamStatus: .none,
                isHead: false, committerDate: nil, symbolicTarget: nil)
        }, tags: [], isPartial: false, skippedRecords: 0)

    func page(_ repository: Repository, skip: Int, limit: Int) async -> Result<GraphPageSnapshot, GitError> {
        let slice = skip < Self.commits.count ? Array(Self.commits[skip...].prefix(limit)) : []
        return .success(
            GraphPageSnapshot(
                commits: slice, isPartial: false, refSet: GraphRefSet(refs: Self.refs, worktrees: []),
                refs: Self.refs, worktrees: []))
    }
}

/// The graph polish of #255 rendered offscreen: the author chip row with a chip picked and SHA hidden, more than
/// twelve lanes scrolled sideways, and lane-tinted worktree tiles. Set `OVERGROVE_SNAPSHOT_DIR`
/// (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep the PNGs.
@MainActor
final class GraphPolishRenderTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func loadedStore(_ loader: some GraphLoading, focus: WorktreeListing.Entry? = nil) async throws
        -> GraphStore
    {
        let store = GraphStore(loader: loader)
        store.load(
            Repository(
                rootURL: URL(fileURLWithPath: "/tmp/dev/api"),
                commonGitDirectoryURL: URL(fileURLWithPath: "/tmp/dev/api/.git"), isBare: false),
            focus: focus)
        let deadline = ContinuousClock.now + .seconds(5)
        while store.status != .loaded, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.status, .loaded)
        return store
    }

    private func render(_ view: some View, size: CGSize, name: String) throws {
        for (mode, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            host.appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            host.frame = NSRect(origin: .zero, size: size)
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

    func testAuthorChipsAndHiddenColumnRender() async throws {
        let store = try await loadedStore(SampleGraphLoader())
        let summary = GraphAuthorSummary(commits: store.commits)
        XCTAssertTrue(summary.hasChoices)
        let selection = GraphAuthorSelection.author("bo@example.com")
        let matches = try XCTUnwrap(GraphAuthorFilterResult(selection: selection, commits: store.commits)).matchSet
        let panel = GraphPanel(
            hasRepository: true, graphStore: store, authorSummary: summary, authorFilter: selection,
            authorMatches: matches, columns: GraphColumnLayout.default.toggling(.sha).setting(.refs, to: 200))
        try render(panel, size: CGSize(width: 960, height: 280), name: "graph-author-filter")
    }

    func testMoreThanTwelveLanesScrollInsideTheGraphColumn() async throws {
        let store = try await loadedStore(WideGraphLoader())
        XCTAssertGreaterThan(store.laneCount, Tokens.Size.graphMaxLanesVisible)
        XCTAssertEqual(
            GraphGeometry.standard.width(lanes: store.laneCount),
            GraphGeometry.standard.width(lanes: Tokens.Size.graphMaxLanesVisible),
            "the column stops growing at twelve lanes")
        XCTAssertGreaterThan(GraphGeometry.standard.maxOffset(lanes: store.laneCount), 0)
        // Picking the last branch's tip scrolls its lane into view (GraphView's `onChange` of the selection).
        store.select(WideGraphLoader.oid(WideGraphLoader.branchCount - 1))
        try render(
            GraphView(store: store, now: now, columns: GraphColumnLayout.default.toggling(.date)),
            size: CGSize(width: 960, height: 560), name: "graph-wide-lanes")
    }

    func testFitMeasuresTheLoadedRows() async throws {
        let store = try await loadedStore(SampleGraphLoader())
        let authors = GraphColumnFit.contentWidths(.author, commits: store.commits[...], pills: store.pills, now: now)
        XCTAssertEqual(authors.count, 3, "one measurement per distinct name")
        XCTAssertTrue(authors.allSatisfy { $0 > 20 })
        let refs = GraphColumnFit.contentWidths(.refs, commits: store.commits[...], pills: store.pills, now: now)
        XCTAssertEqual(refs.count, store.commits.filter { store.pills[$0.oid] != nil }.count)
        let sha = GraphColumnFit.contentWidths(.sha, commits: store.commits[...], pills: store.pills, now: now)
        XCTAssertEqual(sha.count, 1)
        let fitted = GraphColumnLayout.fittedWidth(.sha, contentWidths: sha)
        XCTAssertTrue((64...96).contains(fitted))
        XCTAssertEqual(
            GraphColumnFit.contentWidths(.author, commits: [], pills: [:], now: now), [], "nothing loaded")
    }

    func testWorktreeTilesAreTintedWithTheirLane() throws {
        let tip = try XCTUnwrap(ObjectID("a91f3c2000000000000000000000000000000000"))
        let model = WorktreeListModel(
            listing: .mockup, focused: nil, home: "/tmp/dev", laneIndex: { $0 == tip ? 2 : nil })
        XCTAssertFalse(model.rows.compactMap(\.laneIndex).isEmpty)
        let sidebar = SidebarPanel(hasRepository: true, worktreeStatus: .loaded(.mockup), worktreeModel: model)
        try render(sidebar, size: CGSize(width: 280, height: 360), name: "sidebar-lane-tiles")
    }
}
