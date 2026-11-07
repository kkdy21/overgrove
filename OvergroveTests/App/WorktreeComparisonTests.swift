import Foundation
import XCTest

@testable import Overgrove

/// Comparing a worktree with its base branch from the merge-base (#157, git-command-catalog.md §3): what a pull
/// request's "Files changed" would show, the working tree option, the default base, errors, and the cache.
///
/// Layout: `main` has `a.txt`; the linked worktree `feature` adds `b.txt` in one commit, while `main` moves on with
/// `m.txt`, which the comparison must not show.
final class WorktreeComparisonTests: XCTestCase {
    private var executables: TestExecutables!
    private var repository: GitTestRepository!
    private var markers: URL!
    private var service: RepositoryService!

    override func setUp() async throws {
        executables = try TestExecutables()
        markers = executables.directory.appendingPathComponent("markers", isDirectory: true)
        repository = try await GitTestRepository.make()
        try repository.write("a.txt", "a\n")
        try await repository.git(["add", "a.txt"])
        try await repository.git(["commit", "-q", "-m", "one"])
        try await repository.git(["worktree", "add", "-q", "-b", "feature", feature.path])
        try "b\n".write(to: feature.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        try await repository.git(["-C", feature.path, "add", "b.txt"])
        try await repository.git(["-C", feature.path, "commit", "-q", "-m", "feature work"])
        try repository.write("m.txt", "main\n")
        try await repository.git(["add", "m.txt"])
        try await repository.git(["commit", "-q", "-m", "main moves on"])
        service = try makeService()
    }

    override func tearDown() {
        repository?.remove()
        executables?.remove()
    }

    // MARK: - Helpers

    private var feature: URL { executables.directory.appendingPathComponent("feature", isDirectory: true) }

    private var model: Repository {
        Repository(
            rootURL: repository.root, commonGitDirectoryURL: repository.root.appendingPathComponent(".git"),
            isBare: false)
    }

    private let main = FullRefName("refs/heads/main")!

    /// A service whose git logs every subcommand (`TestExecutables.gatedGit`, released at once).
    private func makeService() throws -> RepositoryService {
        let gated = try executables.gatedGit(forwardingTo: repository.environment.executable, markers: markers)
        FileManager.default.createFile(atPath: markers.appendingPathComponent("release").path, contents: nil)
        return RepositoryService(
            client: GitClient(environment: GitEnvironment(executable: gated, version: repository.environment.version)))
    }

    private func calls() -> [String: Int] {
        let log = (try? String(contentsOf: markers.appendingPathComponent("invocations.log"), encoding: .utf8)) ?? ""
        return log.split(separator: "\n").reduce(into: [:]) { $0[String($1), default: 0] += 1 }
    }

    private func resetCalls() {
        try? FileManager.default.removeItem(at: markers.appendingPathComponent("invocations.log"))
    }

    /// The `feature` worktree's listed path, after a load (matched by folder: it may be detached).
    private func featurePath() async throws -> GitPath {
        let refresh = await service.refresh(model, trigger: .user)
        guard case .success(let overview) = refresh?.result else { throw GitError.cancelled }
        let folder = PathValidator.canonical(feature)?.path
        return try XCTUnwrap(
            overview.entries.first {
                PathValidator.canonical(URL(fileURLWithPath: $0.worktree.path.display))?.path == folder
            }
        ).worktree.path
    }

    private func compare(
        base: FullRefName? = nil, includeWorkingTree: Bool, file: StaticString = #filePath, line: UInt = #line
    ) async throws -> WorktreeComparison {
        let result = await service.compare(
            model, worktree: try await featurePath(), base: base, includeWorkingTree: includeWorkingTree)
        switch result {
        case .success(let comparison): return comparison
        case .failure(let error): throw error
        }
    }

    private func paths(_ comparison: WorktreeComparison) -> [String] {
        comparison.files.map(\.path.display)
    }

    // MARK: - What is compared

    func testCommittedComparisonShowsOnlyTheWorktreeBranchChanges() async throws {
        let comparison = try await compare(base: main, includeWorkingTree: false)

        XCTAssertEqual(paths(comparison), ["b.txt"], "main's own m.txt is not part of the comparison")
        XCTAssertEqual(comparison.files.first?.status, .added)
        XCTAssertEqual(comparison.files.first?.added, 1)
        XCTAssertEqual(comparison.commits.map(\.subject), ["feature work"])
        XCTAssertEqual(comparison.counts, RevListParser.Counts(behind: 1, ahead: 1))
        XCTAssertEqual(comparison.untracked, [])
        XCTAssertFalse(comparison.isFileListPartial)
        XCTAssertFalse(comparison.isCommitListPartial)
    }

    /// Uncommitted tracked changes come from git diff, whose working tree side has zero object names; untracked files
    /// come from status.
    func testWorkingTreeComparisonAddsUncommittedAndUntrackedFiles() async throws {
        try "a changed\n".write(to: feature.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "u\n".write(to: feature.appendingPathComponent("u.txt"), atomically: true, encoding: .utf8)

        let withWorkingTree = try await compare(base: main, includeWorkingTree: true)
        let committedOnly = try await compare(base: main, includeWorkingTree: false)

        XCTAssertEqual(paths(withWorkingTree), ["a.txt", "b.txt"])
        XCTAssertEqual(withWorkingTree.files.first?.status, .modified)
        XCTAssertEqual(withWorkingTree.untracked, [GitPath("u.txt")])
        XCTAssertEqual(paths(committedOnly), ["b.txt"])
        XCTAssertEqual(committedOnly.untracked, [])
    }

    /// #305: a tracked file whose modification time changed but whose content did not (an editor saving without
    /// changes, a checkout, an archive) is listed by `git diff --raw` with a zero object name but has no numstat
    /// record. The comparison failed with "numstat record does not match raw record"; it now leaves the file out.
    func testStatOnlyChangeInTheWorkingTreeIsNotAChange() async throws {
        let file = feature.appendingPathComponent("a.txt")
        let old = Date(timeIntervalSince1970: 1_577_836_800)  // 2020-01-01: older than the index written next
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: file.path)
        try await repository.git(["-C", feature.path, "update-index", "-q", "--really-refresh"])
        // Another old time: stat-dirty, but not racily clean, so git does not hash it before diffing.
        try FileManager.default.setAttributes(
            [.modificationDate: old.addingTimeInterval(86_400 * 366)], ofItemAtPath: file.path)
        try "c\n".write(to: feature.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        try await repository.git(["-C", feature.path, "add", "c.txt"])

        let comparison = try await compare(base: main, includeWorkingTree: true)

        XCTAssertEqual(paths(comparison), ["b.txt", "c.txt"], "the touched a.txt is not a change")
    }

    func testDefaultBaseIsUsedWhenNoneIsGiven() async throws {
        let comparison = try await compare(includeWorkingTree: false)
        XCTAssertEqual(comparison.base, main)
    }

    func testDetachedHeadHasNoAheadBehind() async throws {
        try await repository.git(["-C", feature.path, "switch", "-q", "--detach"])
        let path = try await featurePath()
        let result = await service.compare(model, worktree: path, base: main, includeWorkingTree: false)
        guard case .success(let comparison) = result else { return XCTFail("\(result)") }
        XCTAssertNil(comparison.counts)
        XCTAssertEqual(comparison.commits.map(\.subject), ["feature work"])
    }

    func testPatchOfOneFile() async throws {
        let path = try await featurePath()
        let result = await service.comparePatch(
            model, worktree: path, base: main, file: GitPath("b.txt"), includeWorkingTree: false)
        guard case .success(let patch) = result else { return XCTFail("\(result)") }
        let text = String(decoding: patch.patch, as: UTF8.self)
        XCTAssertTrue(text.contains("+b"), text)
        XCTAssertFalse(text.contains("m.txt"), text)
    }

    // MARK: - Errors

    func testUnrelatedHistoryReportsNoMergeBase() async throws {
        let tree = try await repository.git(["write-tree"])
        let lone = try await repository.git(
            ["commit-tree", String(decoding: tree.stdout, as: UTF8.self).trimmingCharacters(in: .newlines), "-m", "x"])
        let oid = String(decoding: lone.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        try await repository.git(["update-ref", "refs/heads/lone", oid])

        let path = try await featurePath()
        let result = await service.compare(
            model, worktree: path, base: FullRefName("refs/heads/lone")!, includeWorkingTree: false)
        XCTAssertEqual(result, .failure(.git(.noMergeBase)))
    }

    func testMissingBaseAndUnknownWorktree() async throws {
        let path = try await featurePath()
        let nope = FullRefName("refs/heads/nope")!
        let missingBase = await service.compare(model, worktree: path, base: nope, includeWorkingTree: false)
        XCTAssertEqual(missingBase, .failure(.baseNotFound(nope)))

        let unknown = await service.compare(
            model, worktree: GitPath("/nonexistent/worktree"), base: main, includeWorkingTree: false)
        XCTAssertEqual(unknown, .failure(.worktreeNotQueried))
    }

    // MARK: - Cache (overview.md §5)

    func testComparisonIsCachedUntilItsStatusIsQueriedAgain() async throws {
        let path = try await featurePath()
        _ = await service.compare(model, worktree: path, base: main, includeWorkingTree: true)
        _ = await service.compare(model, worktree: path, base: main, includeWorkingTree: false)
        resetCalls()

        _ = await service.compare(model, worktree: path, base: main, includeWorkingTree: true)
        _ = await service.compare(model, worktree: path, base: main, includeWorkingTree: false)
        XCTAssertEqual(calls(), [:], "both comparisons come from the cache")

        _ = await service.refresh(model, trigger: .worktreeSelected(path))
        resetCalls()
        _ = await service.compare(model, worktree: path, base: main, includeWorkingTree: false)
        XCTAssertEqual(calls(), [:], "commits are immutable: the committed comparison stays cached")
        _ = await service.compare(model, worktree: path, base: main, includeWorkingTree: true)
        XCTAssertEqual(calls()["diff"], 1, "a newer status makes the working tree comparison stale")
    }

    func testMovedBaseTipMakesANewComparison() async throws {
        let path = try await featurePath()
        let before = await service.compare(model, worktree: path, base: main, includeWorkingTree: false)
        try repository.write("n.txt", "next\n")
        try await repository.git(["add", "n.txt"])
        try await repository.git(["commit", "-q", "-m", "main moves again"])
        _ = await service.refresh(model, trigger: .user)

        let after = await service.compare(model, worktree: path, base: main, includeWorkingTree: false)

        guard case .success(let old) = before, case .success(let new) = after else { return XCTFail("\(after)") }
        XCTAssertNotEqual(new.baseTip, old.baseTip)
        XCTAssertEqual(new.counts, RevListParser.Counts(behind: 2, ahead: 1))
        XCTAssertEqual(paths(new), ["b.txt"])
    }

    func testForgetDropsComparisons() async throws {
        let path = try await featurePath()
        _ = await service.compare(model, worktree: path, base: main, includeWorkingTree: false)
        await service.forget(model)
        resetCalls()

        _ = await service.compare(model, worktree: path, base: main, includeWorkingTree: false)
        XCTAssertEqual(calls()["diff"], 1)
    }

    // MARK: - Default base

    private func branch(_ name: String, symbolicTarget: String? = nil) -> Branch {
        Branch(
            fullName: name, kind: name.hasPrefix("refs/remotes/") ? .remote(remote: "origin") : .local,
            target: ObjectID(String(repeating: "ab", count: 20))!, upstreamStatus: .none, isHead: false,
            committerDate: nil, symbolicTarget: symbolicTarget)
    }

    private func listing(_ branches: [Branch]) -> RefParser.Listing {
        RefParser.Listing(branches: branches, tags: [], isPartial: false, skippedRecords: 0)
    }

    func testDefaultBaseOrder() {
        let originHead = branch("refs/remotes/origin/HEAD", symbolicTarget: "refs/remotes/origin/trunk")
        let all = [
            branch("refs/heads/main"), branch("refs/heads/master"), originHead, branch("refs/remotes/origin/trunk"),
        ]
        XCTAssertEqual(WorktreeComparison.defaultBase(in: listing(all))?.value, "refs/remotes/origin/trunk")
        XCTAssertEqual(
            WorktreeComparison.defaultBase(in: listing([branch("refs/heads/main"), branch("refs/heads/master")]))?
                .value,
            "refs/heads/main")
        XCTAssertEqual(
            WorktreeComparison.defaultBase(in: listing([branch("refs/heads/master")]))?.value, "refs/heads/master")
        XCTAssertNil(WorktreeComparison.defaultBase(in: listing([branch("refs/heads/feature")])))
        let dangling = branch("refs/remotes/origin/HEAD", symbolicTarget: "refs/remotes/origin/gone")
        XCTAssertEqual(
            WorktreeComparison.defaultBase(in: listing([dangling, branch("refs/heads/main")]))?.value,
            "refs/heads/main", "origin/HEAD pointing at a missing branch falls back")
        let hostile = branch("refs/remotes/origin/HEAD", symbolicTarget: "refs/remotes/origin/-x..y")
        XCTAssertEqual(
            WorktreeComparison.defaultBase(in: listing([hostile, branch(hostile.symbolicTarget!)]))?.value, nil,
            "a target that FullRefName rejects is never used")
    }
}
