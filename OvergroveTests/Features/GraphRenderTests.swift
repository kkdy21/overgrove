import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// A small history with a branch, a merge, refs of every kind, and an AI-assisted commit.
struct SampleGraphLoader: GraphLoading {
    static func oid(_ name: Character) -> ObjectID { ObjectID(String(repeating: name, count: 40))! }

    static func commit(
        _ name: Character, _ parents: [Character], _ subject: String, author: String = "Alice Example",
        email: String = "alice@example.com", minutesAgo: Double, coAuthors: [String] = []
    ) -> CommitNode {
        CommitNode(
            oid: oid(name), parents: parents.map(oid), authorName: author, authorEmail: email,
            authorDate: Date(timeIntervalSince1970: 1_800_000_000 - minutesAgo * 60), subject: subject,
            coAuthors: coAuthors)
    }

    static let commits: [CommitNode] = [
        commit(
            "1", ["2"], "feat(ratelimit): add sliding window limiter", minutesAgo: 30,
            coAuthors: ["Claude <noreply@anthropic.com>"]),
        commit(
            "3", ["4"], "docs: describe the release process", author: "Bo Kim", email: "bo@example.com",
            minutesAgo: 90),
        commit("2", ["4"], "test(ratelimit): cover burst and refill", minutesAgo: 180),
        commit(
            "4", ["5", "6"], "Merge branch 'fix/timeout'", author: "Bo Kim", email: "bo@example.com",
            minutesAgo: 600),
        commit(
            "6", ["5"], "fix(http): retry on timeout", author: "Chris Lee", email: "chris@example.com",
            minutesAgo: 1_400),
        commit("5", [], "chore: initial import", minutesAgo: 5_000),
    ]

    static func branch(_ name: String, _ target: Character) -> Branch {
        Branch(
            fullName: name, kind: name.hasPrefix("refs/remotes/") ? .remote(remote: "origin") : .local,
            target: oid(target), upstreamStatus: .none, isHead: false, committerDate: nil, symbolicTarget: nil)
    }

    static let refs = RefParser.Listing(
        branches: [
            branch("refs/heads/feat/42-rate-limit", "1"), branch("refs/heads/main", "3"),
            branch("refs/remotes/origin/main", "3"), branch("refs/remotes/origin/fix/timeout", "6"),
        ],
        tags: [Tag(fullName: "refs/tags/v0.1.0", target: oid("5"), peeledTarget: nil, date: nil, objectType: .commit)],
        isPartial: false, skippedRecords: 0)

    static let worktree = Worktree(
        path: GitPath("/tmp/dev/api-wt/42-rate-limit"), head: oid("1"), branch: "refs/heads/feat/42-rate-limit",
        isMain: false, isDetached: false, isBare: false, lock: .unlocked, isPrunable: false, prunableReason: nil)

    func page(_ repository: Repository, skip: Int, limit: Int) async -> Result<GraphPageSnapshot, GitError> {
        let slice = skip < Self.commits.count ? Array(Self.commits[skip...].prefix(limit)) : []
        return .success(
            GraphPageSnapshot(
                commits: slice, isPartial: false, refSet: GraphRefSet(refs: Self.refs, worktrees: [Self.worktree]),
                refs: Self.refs, worktrees: [Self.worktree]))
    }
}

/// The commit graph rendered offscreen in light and dark (#68). Set `OVERGROVE_SNAPSHOT_DIR`
/// (xcodebuild: `TEST_RUNNER_OVERGROVE_SNAPSHOT_DIR`) to keep the PNGs.
@MainActor
final class GraphRenderTests: XCTestCase {
    private func loadedStore() async throws -> GraphStore {
        let store = GraphStore(loader: SampleGraphLoader())
        let state = WorkingState(
            headCommit: SampleGraphLoader.oid("1"), head: .branch("feat/42-rate-limit"), upstream: .none,
            stashCount: 0, staged: [FileChange(path: GitPath("a.go"), status: .modified)],
            unstaged: [FileChange(path: GitPath("b.go"), status: .modified)], untracked: [], conflicted: [],
            isPartial: false, skippedRecords: 0)
        store.load(
            Repository(
                rootURL: URL(fileURLWithPath: "/tmp/dev/api"),
                commonGitDirectoryURL: URL(fileURLWithPath: "/tmp/dev/api/.git"),
                isBare: false),
            focus: WorktreeListing.Entry(worktree: SampleGraphLoader.worktree, state: .loaded(state)))
        let deadline = ContinuousClock.now + .seconds(5)
        while store.status != .loaded, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        store.select(SampleGraphLoader.oid("3"))
        return store
    }

    private func render(_ view: some View, size: CGSize, appearance: NSAppearance) throws -> NSBitmapImageRep {
        let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
        host.appearance = appearance
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    func testRendersInLightAndDark() async throws {
        let store = try await loadedStore()
        XCTAssertEqual(store.rows.count, 6)
        XCTAssertNotNil(store.wip)
        XCTAssertEqual(store.laneCount, 2, "the freed column is reused")
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            let appearance = try XCTUnwrap(NSAppearance(named: appearanceName))
            let bitmap = try render(
                GraphView(store: store, now: Date(timeIntervalSince1970: 1_800_000_000)),
                size: CGSize(width: 900, height: 260), appearance: appearance)
            XCTAssertGreaterThan(bitmap.pixelsWide, 0)
            if let directory = ProcessInfo.processInfo.environment["OVERGROVE_SNAPSHOT_DIR"],
                let png = bitmap.representation(using: .png, properties: [:])
            {
                try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("graph-\(name).png"))
            }
        }
    }
}
