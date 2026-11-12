import Foundation
import XCTest

@testable import Overgrove

/// `FileChangeClassifier` (#119): event paths (untrusted strings) to worktrees, by component comparison only.
final class FileChangeClassifierTests: XCTestCase {
    private let main = GitPath("/dev/api")
    private let lane = GitPath("/dev/api-wt/lane")
    private let nested = GitPath("/dev/api/.claude/worktrees/agent")

    private var classifier: FileChangeClassifier {
        FileChangeClassifier(
            commonDirectory: "/dev/api/.git",
            worktrees: [
                .init(path: main, folder: "/dev/api", gitDirectory: "/dev/api/.git"),
                .init(path: lane, folder: "/dev/api-wt/lane", gitDirectory: "/dev/api/.git/worktrees/lane"),
                .init(
                    path: nested, folder: "/dev/api/.claude/worktrees/agent",
                    gitDirectory: "/dev/api/.git/worktrees/agent"),
            ])
    }

    private func classify(_ paths: String...) -> FileChangeSet {
        classifier.classify(paths.map { FileEvent(path: $0) })
    }

    func testWorktreeFiles() {
        XCTAssertEqual(classify("/dev/api/src/a.swift"), FileChangeSet(worktrees: [main]))
        XCTAssertEqual(classify("/dev/api-wt/lane/README.md"), FileChangeSet(worktrees: [lane]))
        XCTAssertEqual(
            classify("/dev/api/.claude/worktrees/agent/x.txt"), FileChangeSet(worktrees: [nested]),
            "the deepest worktree folder wins")
        XCTAssertEqual(
            classify("/dev/api/src/a.swift", "/dev/api-wt/lane/b"), FileChangeSet(worktrees: [main, lane]))
    }

    func testGitDirectory() {
        // A HEAD change (a switch, a detached commit) also changes the worktree list record: branch, head (#416).
        XCTAssertEqual(classify("/dev/api/.git/HEAD"), FileChangeSet(worktrees: [main], worktreeList: true))
        XCTAssertEqual(classify("/dev/api/.git/index"), FileChangeSet(worktrees: [main]))
        XCTAssertEqual(
            classify("/dev/api/.git/worktrees/lane/HEAD"), FileChangeSet(worktrees: [lane], worktreeList: true))
        XCTAssertEqual(classify("/dev/api/.git/worktrees/lane/index"), FileChangeSet(worktrees: [lane]))
        XCTAssertEqual(classify("/dev/api/.git/refs/heads/main"), FileChangeSet(refs: true))
        XCTAssertEqual(classify("/dev/api/.git/packed-refs"), FileChangeSet(refs: true))
        XCTAssertEqual(classify("/dev/api/.git/worktrees/new"), FileChangeSet(worktreeList: true))
        XCTAssertEqual(classify("/dev/api/.git/worktrees/lane/locked"), FileChangeSet(worktreeList: true))
        XCTAssertEqual(classify("/dev/api/.git/config"), classifier.everything)
    }

    /// Objects, logs, FETCH_HEAD and the like change on fetch and gc without changing any status (#163).
    func testIgnoredGitFiles() {
        for path in [
            "/dev/api/.git/objects/ab/cdef", "/dev/api/.git/logs/HEAD", "/dev/api/.git/FETCH_HEAD",
            "/dev/api/.git/ORIG_HEAD", "/dev/api/.git/index.lock", "/dev/api/.git/hooks/pre-commit",
            "/dev/api/.git/worktrees/lane/logs/HEAD", "/dev/api/.git/worktrees/lane/ORIG_HEAD",
            "/dev/api/.git/worktrees/unknown/HEAD", "/dev/api/.git/refs-not",
        ] {
            XCTAssertEqual(classify(path), FileChangeSet(), path)
        }
    }

    /// SEC-T14-09: FSEvents paths are untrusted strings. Prefix tricks, relative paths, dot segments, and a linked
    /// worktree's `.git` file affect nothing.
    func testHostilePaths() {
        for path in [
            "/dev/api-other/x", "/dev/apix", "dev/api/src/a", "", "/dev/api/../etc/passwd",
            "/dev/api-wt/lane/./x", "/elsewhere/file", "/dev/api-wt/lane/.git",
        ] {
            XCTAssertEqual(classify(path), FileChangeSet(), path)
        }
    }

    func testRescanMeansEverything() {
        XCTAssertEqual(classifier.classify([FileEvent(path: "/dev/api", needsRescan: true)]), classifier.everything)
    }

    /// SEC-T15-17: the work per batch is bounded. A batch over the cap counts as a rescan without looking at each
    /// path, and classification stops once everything is affected.
    func testOversizedBatchesAreARescan() {
        let storm = (0...FileChangeClassifier.maximumEventsPerBatch).map {
            FileEvent(path: "/dev/api/node_modules/f\($0)")
        }
        XCTAssertEqual(classifier.classify(storm), classifier.everything)
        let atCap = Array(storm.dropLast())
        XCTAssertEqual(classifier.classify(atCap), FileChangeSet(worktrees: [main]))
        XCTAssertEqual(
            classifier.classify([FileEvent(path: "/dev/api/.git/config"), FileEvent(path: "/dev/api/x")]),
            classifier.everything)
    }

    /// The deepest folder wins whatever order the worktrees come in.
    func testDeepestFolderWinsInAnyOrder() {
        let reversed = FileChangeClassifier(
            commonDirectory: classifier.commonDirectory, worktrees: classifier.worktrees.reversed())
        XCTAssertEqual(
            reversed.classify([FileEvent(path: "/dev/api/.claude/worktrees/agent/x")]),
            FileChangeSet(worktrees: [nested]))
        XCTAssertEqual(reversed.classify([FileEvent(path: "/dev/api/.claude/x")]), FileChangeSet(worktrees: [main]))
    }

    /// `git clone --bare … repo.git` then `git -C repo.git worktree add main`: the worktree sits inside the shared git
    /// directory (#421). Its files are its own; the git directory's files still classify as before.
    func testWorktreeInsideABareRepositoryFolder() {
        let inner = GitPath("/dev/repo.git/main")
        let deeper = GitPath("/dev/repo.git/lanes/feature")
        let bare = FileChangeClassifier(
            commonDirectory: "/dev/repo.git",
            worktrees: [
                .init(path: inner, folder: "/dev/repo.git/main", gitDirectory: "/dev/repo.git/worktrees/main"),
                .init(
                    path: deeper, folder: "/dev/repo.git/lanes/feature",
                    gitDirectory: "/dev/repo.git/worktrees/feature"),
            ])
        func classify(_ path: String) -> FileChangeSet { bare.classify([FileEvent(path: path)]) }

        XCTAssertEqual(classify("/dev/repo.git/main/src/a.swift"), FileChangeSet(worktrees: [inner]))
        XCTAssertEqual(classify("/dev/repo.git/main"), FileChangeSet(worktrees: [inner]))
        XCTAssertEqual(classify("/dev/repo.git/lanes/feature/b.txt"), FileChangeSet(worktrees: [deeper]))
        XCTAssertEqual(
            classify("/dev/repo.git/main/.git"), FileChangeSet(), "the linked worktree's .git file is not its files")
        XCTAssertEqual(
            classify("/dev/repo.git/worktrees/main/index"), FileChangeSet(worktrees: [inner]),
            "the git directory still classifies as before")
        XCTAssertEqual(classify("/dev/repo.git/refs/heads/main"), FileChangeSet(refs: true))
        XCTAssertEqual(classify("/dev/repo.git/lanes/other"), FileChangeSet(), "not inside a worktree folder")
        XCTAssertEqual(classify("/dev/repo.git/objects/ab/cdef"), FileChangeSet())
    }

    func testWatchedPaths() {
        XCTAssertEqual(
            classifier.watchedPaths,
            ["/dev/api", "/dev/api-wt/lane", "/dev/api/.claude/worktrees/agent", "/dev/api/.git"].sorted())
    }

    /// Only worktrees whose status was queried (verified by #226) are watched.
    func testListingKeepsOnlyQueriedWorktrees() throws {
        let root = try XCTUnwrap(PathValidator.canonical(FileManager.default.temporaryDirectory))
            .appendingPathComponent("overgrove-watch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let loaded = WorktreeListing.entry(
            root.path, branch: "main", isMain: true, state: .loaded(WorktreeListing.state(branch: "main")))
        let foreign = WorktreeListing.entry(
            "/tmp/elsewhere", branch: "x", state: .notQueried(.foreignRepository))
        let repository = Repository(
            rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false)
        let listing = WorktreeListing(entries: [loaded, foreign], isPartial: false)
        let watcher = try XCTUnwrap(FileChangeClassifier(listing: listing, repository: repository))
        XCTAssertEqual(watcher.worktrees.map(\.folder), [root.path])
        XCTAssertEqual(watcher.commonDirectory, root.appendingPathComponent(".git").path)
    }
}
