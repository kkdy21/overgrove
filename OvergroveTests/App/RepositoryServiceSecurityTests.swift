import Foundation
import XCTest

@testable import Overgrove

/// The worktree list is untrusted (#226, security-review.md T14·T15): `worktree list` reads paths from
/// `.git/worktrees/<id>/gitdir`, which the repository controls. Every listed worktree must prove it belongs to the
/// repository before git runs in it, repeated folders are queried once, and the number of queried worktrees is capped.
///
/// Each forgery has a control showing that the #221 check (same git common directory) would have let it through.
/// Status calls are counted with a pass-through git stand-in (`TestExecutables.gatedGit`).
final class RepositoryServiceSecurityTests: XCTestCase {
    private var executables: TestExecutables!
    private var repository: GitTestRepository!
    private var markers: URL!

    override func setUp() async throws {
        executables = try TestExecutables()
        markers = executables.directory.appendingPathComponent("markers", isDirectory: true)
        repository = try await GitTestRepository.make()
        try repository.write("a.txt", "a\n")
        try await repository.git(["add", "a.txt"])
        try await repository.git(["commit", "-q", "-m", "one"])
        for index in 0..<3 {
            try await repository.git(["worktree", "add", "-q", "-b", "lane/\(index)", worktree(index).path])
        }
    }

    override func tearDown() {
        repository?.remove()
        executables?.remove()
    }

    // MARK: - Helpers

    private var model: Repository {
        Repository(
            rootURL: repository.root, commonGitDirectoryURL: repository.root.appendingPathComponent(".git"),
            isBare: false)
    }

    private var commonDirectory: URL { repository.root.appendingPathComponent(".git", isDirectory: true) }

    private func worktree(_ index: Int) -> URL {
        executables.directory.appendingPathComponent("wt-\(index)", isDirectory: true)
    }

    private func load(maximumQueriedWorktrees: Int = RepositoryService.defaultMaximumQueriedWorktrees) async throws
        -> RepositoryOverview
    {
        let gated = try executables.gatedGit(forwardingTo: repository.environment.executable, markers: markers)
        FileManager.default.createFile(atPath: markers.appendingPathComponent("release").path, contents: nil)
        let client = GitClient(environment: GitEnvironment(executable: gated, version: repository.environment.version))
        return try await RepositoryService(client: client, maximumQueriedWorktrees: maximumQueriedWorktrees)
            .loadOverview(of: model)
    }

    private func statusCalls() -> Int {
        let log = (try? String(contentsOf: markers.appendingPathComponent("invocations.log"), encoding: .utf8)) ?? ""
        return log.split(separator: "\n").filter { $0 == "status" }.count
    }

    /// The probe the #221 check relied on, run directly.
    private func probe(_ folder: URL) async throws -> RepositoryProbe {
        let output = try await GitClient(environment: repository.environment)
            .run(.probeRepository, in: folder, safety: .preInspection)
        return try ProbeParser.parse(output.stdout)
    }

    private func canonicalPath(_ url: URL) -> String? { PathValidator.canonical(url)?.path }

    /// Writes `.git/worktrees/<id>/` so that `worktree list` names the folder of `gitdirTarget`.
    private func forgeEntry(_ id: String, gitdirTarget: URL) throws {
        let entry = commonDirectory.appendingPathComponent("worktrees/\(id)", isDirectory: true)
        try FileManager.default.createDirectory(at: entry, withIntermediateDirectories: true)
        try (gitdirTarget.path + "\n").write(
            to: entry.appendingPathComponent("gitdir"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/main\n".write(to: entry.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "../..\n".write(to: entry.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)
    }

    private func entry(_ overview: RepositoryOverview, at folder: URL) throws -> RepositoryOverview.Entry {
        let target = canonicalPath(folder)
        return try XCTUnwrap(
            overview.entries.first { canonicalPath(URL(fileURLWithPath: $0.worktree.path.display)) == target },
            "no entry for \(folder.lastPathComponent)")
    }

    // MARK: - SEC-T14-05: listed worktrees must belong to the repository

    /// A forged entry naming a subfolder of the main worktree: git finds the main repository from there, so the same
    /// working tree would be queried twice under a second row.
    func testSECT14_05_forgedEntryForAMainWorktreeSubfolderIsNotQueried() async throws {
        let subfolder = repository.root.appendingPathComponent("sub", isDirectory: true)
        // An empty `.git` folder keeps the entry from being prunable; git skips it and finds the main repository.
        let emptyGitFolder = subfolder.appendingPathComponent(".git", isDirectory: true)
        try FileManager.default.createDirectory(at: emptyGitFolder, withIntermediateDirectories: true)
        try forgeEntry("sub", gitdirTarget: emptyGitFolder)

        let control = try await probe(subfolder)
        XCTAssertEqual(canonicalPath(control.commonDirectory), canonicalPath(commonDirectory), "control: #221 passes")
        XCTAssertNotEqual(canonicalPath(control.topLevel), canonicalPath(subfolder))

        let overview = try await load()
        XCTAssertEqual(try entry(overview, at: subfolder).status, .notQueried(.foreignRepository))
        XCTAssertEqual(statusCalls(), 4, "main and the three linked worktrees only")
    }

    /// A folder whose `.git` borrows a real linked worktree's entry: git would run status there with that worktree's
    /// index and HEAD, shown under its branch name. Only the entry's back-pointer tells them apart.
    func testSECT14_05_folderBorrowingALinkedWorktreeEntryIsNotQueried() async throws {
        let borrower = executables.directory.appendingPathComponent("borrower", isDirectory: true)
        try FileManager.default.createDirectory(at: borrower, withIntermediateDirectories: true)
        let borrowed = commonDirectory.appendingPathComponent("worktrees/wt-0").path
        try "gitdir: \(borrowed)\n".write(
            to: borrower.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try forgeEntry("borrow", gitdirTarget: borrower.appendingPathComponent(".git"))

        let control = try await probe(borrower)
        XCTAssertEqual(canonicalPath(control.commonDirectory), canonicalPath(commonDirectory), "control: #221 passes")
        XCTAssertEqual(canonicalPath(control.topLevel), canonicalPath(borrower), "control: git treats it as a root")

        let overview = try await load()
        XCTAssertEqual(try entry(overview, at: borrower).status, .notQueried(.foreignRepository))
        guard case .loaded = try entry(overview, at: worktree(0)).status else {
            return XCTFail("the real worktree is still queried")
        }
        XCTAssertEqual(statusCalls(), 4)
    }

    /// `core.worktree` in a linked worktree's `config.worktree` moves git's working tree elsewhere (the home folder,
    /// say), so status would walk a folder the user never registered.
    func testSECT14_05_coreWorktreeInWorktreeConfigurationIsNotQueried() async throws {
        let elsewhere = executables.directory.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try await repository.git(["config", "extensions.worktreeConfig", "true"])
        try await repository.git(["-C", worktree(1).path, "config", "--worktree", "core.worktree", elsewhere.path])

        let control = try await probe(worktree(1))
        XCTAssertEqual(canonicalPath(control.commonDirectory), canonicalPath(commonDirectory), "control: #221 passes")
        XCTAssertEqual(canonicalPath(control.topLevel), canonicalPath(elsewhere), "control: git works elsewhere")

        let overview = try await load()
        XCTAssertEqual(try entry(overview, at: worktree(1)).status, .notQueried(.foreignRepository))
        XCTAssertEqual(statusCalls(), 3)
    }

    // MARK: - SEC-T15-07: duplicates and the query limit

    func testSECT15_07_queriesStopAtTheLimit() async throws {
        let overview = try await load(maximumQueriedWorktrees: 2)

        XCTAssertEqual(overview.entries.count, 4, "every worktree is still listed")
        XCTAssertEqual(overview.entries.filter { $0.status == .notQueried(.limit) }.count, 2)
        XCTAssertTrue(overview.isQueryLimited)
        XCTAssertTrue(overview.entries.first?.worktree.isMain ?? false)
        guard case .loaded = overview.entries.first?.status else { return XCTFail("the main worktree comes first") }
        XCTAssertEqual(statusCalls(), 2)
    }

    func testSECT15_07_repeatedAndAliasedFoldersAreQueriedOnce() async throws {
        try forgeEntry("repeat", gitdirTarget: worktree(0).appendingPathComponent(".git"))
        let alias = executables.directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: worktree(2))
        try forgeEntry("alias", gitdirTarget: alias.appendingPathComponent(".git"))

        let overview = try await load()

        let paths = overview.entries.map(\.worktree.path)
        XCTAssertEqual(Set(paths).count, paths.count, "a repeated path is listed once (entry identity)")
        let wt2 = canonicalPath(worktree(2))
        let sameFolder = overview.entries.filter {
            canonicalPath(URL(fileURLWithPath: $0.worktree.path.display)) == wt2
        }
        XCTAssertEqual(sameFolder.count, 2, "wt-2 and its alias are both listed")
        XCTAssertEqual(sameFolder.filter { $0.status == .notQueried(.duplicate) }.count, 1, "and queried once")
        XCTAssertFalse(overview.isQueryLimited)
        XCTAssertEqual(statusCalls(), 4)
    }

    // MARK: - SEC-T4-07: each worktree's own configuration

    /// A linked worktree's `config.worktree` with a key that cannot be neutralized blocks that worktree only, and its
    /// status never runs (fail closed). The driver-neutralizing case is
    /// `RepositoryServiceTests.testLinkedWorktreeOwnConfigurationIsInspected`.
    func testSECT4_07_worktreeConfigurationThatBlocksQueriesStopsItsStatus() async throws {
        try await repository.git(["config", "extensions.worktreeConfig", "true"])
        try await repository.git(["-C", worktree(2).path, "config", "--worktree", "filter.a=b.clean", "x"])

        let overview = try await load()

        guard case .notQueried(.inspectionBlocked) = try entry(overview, at: worktree(2)).status else {
            return XCTFail("\(try entry(overview, at: worktree(2)).status)")
        }
        guard case .loaded = try entry(overview, at: repository.root).status else {
            return XCTFail("control: the main worktree is not blocked")
        }
        XCTAssertEqual(statusCalls(), 3, "no status in the blocked worktree")
    }
}
