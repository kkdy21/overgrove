import Foundation
import XCTest

@testable import Overgrove

/// `ComparisonModel` (#158): screens.md S-11 from a `WorktreeComparison`, without views.
final class ComparisonModelTests: XCTestCase {
    private let main = FullRefName("refs/heads/main")!
    private let tip = ObjectID(String(repeating: "a", count: 40))!

    static func stat(
        _ path: String, _ status: FileChange.Status, _ added: Int?, _ deleted: Int?, from: String? = nil
    ) -> FileStat {
        FileStat(
            path: GitPath(path), originalPath: from.map(GitPath.init), status: status, added: added, deleted: deleted,
            isFromUntracked: false)
    }

    static func commit(_ hex: Character, _ subject: String) -> CommitNode {
        CommitNode(
            oid: ObjectID(String(repeating: hex, count: 40))!, parents: [], authorName: "Alex Kim",
            authorEmail: "alex@example.com", authorDate: Date(timeIntervalSince1970: 0), subject: subject,
            coAuthors: [])
    }

    static func comparison(
        base: FullRefName = FullRefName("refs/heads/main")!, files: [FileStat], untracked: [String] = [],
        commits: [CommitNode] = [], counts: RevListParser.Counts? = .init(behind: 0, ahead: 2),
        includesWorkingTree: Bool = true
    ) -> WorktreeComparison {
        WorktreeComparison(
            base: base, baseTip: ObjectID(String(repeating: "a", count: 40))!, head: nil,
            includesWorkingTree: includesWorkingTree, files: files, isFileListPartial: false,
            untracked: untracked.map(GitPath.init), commits: commits, isCommitListPartial: false, counts: counts)
    }

    private func model(_ result: ComparisonLoadState, working: WorkingState? = nil, showAll: Bool = false)
        -> ComparisonModel
    {
        var session = ComparisonSession(worktree: GitPath("/tmp/dev/wt"), base: main)
        session.result = result
        session.showsAllFiles = showAll
        return ComparisonModel(session: session, workingState: working)
    }

    func testLoadedComparison() {
        let working = WorktreeListing.state(branch: "feat", staged: 0, unstaged: 0)
        let comparison = Self.comparison(
            files: [
                Self.stat("internal/ratelimit/limiter.go", .added, 120, nil),
                Self.stat("internal/http/middleware.go", .modified, 30, 4),
                Self.stat("internal/http/pass.go", .renamed(score: 90), 2, 1, from: "internal/http/noop.go"),
                Self.stat("logo.png", .modified, nil, nil),
            ],
            untracked: ["docs/rate-limit.md"],
            commits: [Self.commit("b", "feat(ratelimit): add limiter\u{202E}"), Self.commit("c", "test: cover it")])
        let model = model(.loaded(comparison), working: working)
        XCTAssertEqual(model.state, .loaded)
        XCTAssertEqual(model.baseName, "main")
        XCTAssertEqual(model.summary, "2 commits ahead · 0 behind · uncommitted: 0 files · 4 files · +152 −5")
        XCTAssertEqual(
            model.files.map(\.fileName), ["middleware.go", "{noop.go → pass.go}", "limiter.go", "logo.png"],
            "sorted by path")
        XCTAssertEqual(model.files.map(\.kindLetter), ["M", "R", "A", "M"])
        XCTAssertEqual(model.files.map(\.lineChange), ["+30 −4", "+2 −1", "+120", nil])
        XCTAssertEqual(model.totalLineChange, "+152 −5")
        XCTAssertEqual(model.untracked.map(\.fileName), ["rate-limit.md"])
        XCTAssertEqual(model.untracked.first?.lineChange, nil, "untracked line counts are not shown")
        XCTAssertEqual(model.commits.map(\.shortSHA), ["bbbbbbb", "ccccccc"])
        XCTAssertEqual(model.commits.first?.subject, "feat(ratelimit): add limiter\\u{202E}")
        XCTAssertNil(model.uncommittedFileCount)
    }

    /// Files that also have uncommitted changes get the `WIP` pill, and the uncommitted row counts them.
    func testUncommittedChangesAreMarked() {
        let working = WorkingState(
            headCommit: nil, head: .branch("feat"), upstream: .none, stashCount: 0,
            staged: [FileChange(path: GitPath("a.go"), status: .modified)],
            unstaged: [FileChange(path: GitPath("b.go"), status: .modified)], untracked: [], conflicted: [],
            isPartial: false, skippedRecords: 0)
        let comparison = Self.comparison(
            files: [
                Self.stat("a.go", .modified, 1, 1), Self.stat("b.go", .modified, 1, 0), Self.stat("c.go", .added, 3, 0),
            ])
        let model = model(.loaded(comparison), working: working)
        XCTAssertEqual(model.files.map(\.hasUncommittedChanges), [true, true, false])
        XCTAssertEqual(model.uncommittedFileCount, 2)
        XCTAssertTrue(model.summary?.contains("uncommitted: 2 files") == true)

        // Without uncommitted changes in the comparison, nothing is marked.
        let committedOnly = self.model(
            .loaded(Self.comparison(files: comparison.files, includesWorkingTree: false)), working: working)
        XCTAssertEqual(committedOnly.files.map(\.hasUncommittedChanges), [false, false, false])
        XCTAssertNil(committedOnly.uncommittedFileCount)
        XCTAssertFalse(committedOnly.summary?.contains("uncommitted") == true)
    }

    func testDetachedHeadCountsListedCommits() {
        let model = model(
            .loaded(
                Self.comparison(files: [Self.stat("a", .modified, 1, 1)], commits: [Self.commit("b", "x")], counts: nil)
            ))
        XCTAssertTrue(model.summary?.hasPrefix("1 commit ahead · uncommitted") == true, model.summary ?? "")
    }

    func testStates() {
        XCTAssertEqual(model(.loading).state, .loading("Comparing with main…"))
        XCTAssertEqual(model(.loaded(Self.comparison(files: []))).state, .noChanges("No changes compared with main"))
        XCTAssertEqual(
            model(.failed(.noBaseBranch)).state,
            .failed(message: ComparisonError.noBaseBranch.message, canChooseBase: true))
        XCTAssertEqual(
            model(.failed(.baseNotFound(main))).state,
            .failed(message: "The base branch refs/heads/main no longer exists.", canChooseBase: true))
        XCTAssertEqual(
            model(.failed(.git(.timeout(seconds: 15)))).state,
            .failed(message: GitError.timeout(seconds: 15).message, canChooseBase: false))
    }

    /// screens.md S-11: over 1,000 files shows the first 1,000 and `Show all n files`.
    func testLargeComparisonIsCapped() {
        let files = (0..<(ComparisonModel.fileLimit + 5)).map {
            Self.stat(String(format: "f%05d", $0), .modified, 1, 0)
        }
        let capped = model(.loaded(Self.comparison(files: files)))
        XCTAssertEqual(capped.files.count, ComparisonModel.fileLimit)
        XCTAssertEqual(capped.totalFileCount, ComparisonModel.fileLimit + 5)
        XCTAssertEqual(capped.showAllTitle, "Show all 1,005 files")
        let all = model(.loaded(Self.comparison(files: files)), showAll: true)
        XCTAssertEqual(all.files.count, ComparisonModel.fileLimit + 5)
        XCTAssertNil(all.showAllTitle)
    }

    func testBaseNames() {
        XCTAssertEqual(ComparisonModel.shortName(FullRefName("refs/heads/main")!), "main")
        XCTAssertEqual(ComparisonModel.shortName(FullRefName("refs/remotes/origin/main")!), "origin/main")
        var session = ComparisonSession(worktree: GitPath("/tmp/dev/wt"))
        session.result = .loading
        XCTAssertEqual(
            ComparisonModel(session: session, workingState: nil).state, .loading("Comparing with base branch…"))
    }

    func testUnrepresentablePathIsNotSelectable() {
        let path = GitPath(raw: Data([0x61, 0xFF]))
        let comparison = Self.comparison(files: [
            FileStat(path: path, originalPath: nil, status: .modified, added: 1, deleted: 0, isFromUntracked: false)
        ])
        XCTAssertEqual(model(.loaded(comparison)).files.first?.isSelectable, false)
    }
}
