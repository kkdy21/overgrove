import AppKit
import Observation
import SwiftUI
import XCTest

@testable import Overgrove

/// Two linear histories by root folder: 40 commits in `long`, 3 in `short`. Switching from `long` to `short` shrinks
/// the graph's rows (#678).
private struct TwoRepositoryLoader: GraphLoading {
    static let long = repository("long")
    static let short = repository("short")
    static let longCommits = history(count: 40, first: 0x1000)
    static let shortCommits = history(count: 3, first: 0x2000)

    static func repository(_ name: String) -> Repository {
        let root = URL(fileURLWithPath: "/tmp/dev/\(name)", isDirectory: true)
        return Repository(rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false)
    }

    static func oid(_ value: Int) -> ObjectID { ObjectID(String(format: "%040x", value))! }

    static func history(count: Int, first: Int) -> [CommitNode] {
        (0..<count).map { offset in
            CommitNode(
                oid: oid(first + offset), parents: offset + 1 < count ? [oid(first + offset + 1)] : [],
                authorName: "Alice Example", authorEmail: "alice@example.com",
                authorDate: Date(timeIntervalSince1970: 1_800_000_000 - Double(offset + 1) * 3_600),
                subject: "commit \(offset)")
        }
    }

    func page(_ repository: Repository, skip: Int, limit: Int) async -> Result<GraphPageSnapshot, GitError> {
        let commits = repository.rootURL == Self.short.rootURL ? Self.shortCommits : Self.longCommits
        let slice = skip < commits.count ? Array(commits[skip...].prefix(limit)) : []
        let main = Branch(
            fullName: "refs/heads/main", kind: .local, target: commits[0].oid, upstreamStatus: .none, isHead: true,
            committerDate: nil, symbolicTarget: nil)
        let refs = RefParser.Listing(branches: [main], tags: [], isPartial: false, skippedRecords: 0)
        return .success(
            GraphPageSnapshot(
                commits: slice, isPartial: false, refSet: GraphRefSet(refs: refs, worktrees: []), refs: refs,
                worktrees: []))
    }
}

/// The app's other source of graph input: `AppState.stashes` comes from the worktree list, not from `GraphStore`.
@MainActor
@Observable
private final class StashSource {
    var stashes: [Stash] = []
}

/// The center panel as `MainWindowView` builds it: the store and the stashes reach it separately.
private struct SwitchingPanel: View {
    let store: GraphStore
    let source: StashSource

    var body: some View {
        GraphPanel(hasRepository: true, graphStore: store, stashes: source.stashes)
    }
}

/// #678: switching away from a repository whose graph shows stash rows ended the app with `Index out of range`.
@MainActor
final class GraphRepositorySwitchTests: XCTestCase {
    private let size = CGSize(width: 960, height: 420)

    /// A real stash commit (base and index parents) made on `base`.
    private func stash(_ index: Int, on base: ObjectID) -> Stash {
        Stash(
            index: index, oid: TwoRepositoryLoader.oid(0x5000 + index), subject: "On main: stash \(index)",
            branch: "main", message: "stash \(index)", date: Date(timeIntervalSince1970: 1_799_990_000),
            parents: [base, TwoRepositoryLoader.oid(0x6000 + index)])
    }

    /// The focused worktree on `head`, with changes: the WIP row and its line down to HEAD are drawn.
    private func focus(on head: ObjectID, folder: String) -> WorktreeListing.Entry {
        let worktree = Worktree(
            path: GitPath("/tmp/dev/\(folder)"), head: head, branch: "refs/heads/main", isMain: true,
            isDetached: false, isBare: false, lock: .unlocked, isPrunable: false, prunableReason: nil)
        let state = WorkingState(
            headCommit: head, head: .branch("main"), upstream: .none, stashCount: 0,
            staged: [], unstaged: [FileChange(path: GitPath("a.go"), status: .modified)], untracked: [],
            conflicted: [], isPartial: false, skippedRecords: 0)
        return WorktreeListing.Entry(worktree: worktree, state: .loaded(state))
    }

    private func load(_ store: GraphStore, long: Bool) async throws {
        let commits = long ? TwoRepositoryLoader.longCommits : TwoRepositoryLoader.shortCommits
        store.load(
            long ? TwoRepositoryLoader.long : TwoRepositoryLoader.short,
            focus: focus(on: commits[1].oid, folder: long ? "long" : "short"))
        let deadline = ContinuousClock.now + .seconds(5)
        while store.status != .loaded, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertEqual(store.status, .loaded)
        XCTAssertEqual(store.rows.count, commits.count)
    }

    /// Stashes on rows that the short history does not have (5 is on screen, 30 below it), and one on HEAD's row (1),
    /// which the short history has too.
    private var longStashes: [Stash] {
        [
            stash(0, on: TwoRepositoryLoader.longCommits[5].oid),
            stash(1, on: TwoRepositoryLoader.longCommits[1].oid),
            stash(2, on: TwoRepositoryLoader.longCommits[30].oid),
        ]
    }

    private var shortStashes: [Stash] { [stash(3, on: TwoRepositoryLoader.shortCommits[2].oid)] }

    /// Lays out and draws `host`. With `OVERGROVE_SNAPSHOT_DIR` set, a `name`d drawing is kept as a PNG.
    private func draw(_ host: NSView, keeping name: String? = nil) throws {
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        XCTAssertGreaterThan(bitmap.pixelsWide, 0)
        if let name, let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
            let png = bitmap.representation(using: .png, properties: [:])
        {
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    private func host(_ view: some View) -> NSHostingView<some View> {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.frame = NSRect(origin: .zero, size: size)
        return host
    }

    /// As `AppState.open` and the loads after it: the list and the graph clear together, the graph loads the short
    /// history, and the new stashes arrive with the worktree list. The panel is drawn after every step.
    func testSwitchingToAShorterHistoryStepByStep() async throws {
        let store = GraphStore(loader: TwoRepositoryLoader())
        let source = StashSource()
        try await load(store, long: true)
        source.stashes = longStashes
        let host = host(SwitchingPanel(store: store, source: source))
        try draw(host, keeping: "graph-switch-before")

        source.stashes = []
        store.clear()
        try draw(host)
        try await load(store, long: false)
        try draw(host)
        source.stashes = shortStashes
        try draw(host, keeping: "graph-switch-after")
    }

    /// The panel is not drawn until the short history is in: the stash rows are taken down and the rows shrink in
    /// one update.
    func testSwitchingToAShorterHistoryInOneUpdate() async throws {
        let store = GraphStore(loader: TwoRepositoryLoader())
        let source = StashSource()
        try await load(store, long: true)
        source.stashes = longStashes
        let host = host(SwitchingPanel(store: store, source: source))
        try draw(host)

        source.stashes = []
        store.clear()
        try await load(store, long: false)
        source.stashes = shortStashes
        try draw(host)
    }

    /// The graph view still holds the previous repository's stashes while its store has the short history: the
    /// placement is made against the rows on screen, so no stash is drawn on a row that is not there.
    func testStashesOfThePreviousRepositoryOverAShorterHistory() async throws {
        let store = GraphStore(loader: TwoRepositoryLoader())
        try await load(store, long: true)
        let host = host(GraphView(store: store, stashes: longStashes))
        try draw(host)

        try await load(store, long: false)
        try draw(host)
    }

    /// A pass's copy keeps its own rows when the store switches to the short history: the stash rows it placed, HEAD's
    /// row, and the lines it reads stay within them. A copy of the short rows places only stashes based on one of them.
    func testSnapshotKeepsItsRowsWhenTheStoreSwitches() async throws {
        let store = GraphStore(loader: TwoRepositoryLoader())
        try await load(store, long: true)
        let before = GraphRowsSnapshot(store, stashes: longStashes)
        XCTAssertEqual(before.stashesByRow.keys.sorted(), [1, 5, 30])
        XCTAssertEqual(before.headIndex, 1)

        try await load(store, long: false)
        XCTAssertEqual(before.rows.count, 40, "the copy does not follow the store")
        XCTAssertEqual(before.commits[30].oid, TwoRepositoryLoader.longCommits[30].oid)
        XCTAssertEqual(before.rows[30].column, 0)
        XCTAssertEqual(before.wipLine(at: 0), .through(0))
        XCTAssertEqual(before.wipLine(at: 1), .ends)
        XCTAssertEqual(before.wipLine(at: 5), .none)
        XCTAssertEqual(before.wipColumn(aboveRow: 1), 0, "the WIP line comes down through the stash on HEAD")
        XCTAssertNil(before.wipColumn(aboveRow: 30))
        XCTAssertEqual(before.outgoing(at: 30), before.rows[31].incoming)

        let stale = GraphRowsSnapshot(store, stashes: longStashes)
        XCTAssertEqual(stale.rows.count, 3)
        XCTAssertTrue(stale.stashesByRow.isEmpty, "the previous repository's stashes have no base row here")
        let after = GraphRowsSnapshot(store, stashes: shortStashes)
        XCTAssertEqual(after.stashesByRow.keys.sorted(), [2])
        XCTAssertEqual(after.headIndex, 1)
        XCTAssertEqual(after.outgoing(at: 2), store.pendingSegments, "below the last row")
    }
}
