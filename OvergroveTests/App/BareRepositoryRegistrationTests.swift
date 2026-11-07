import Foundation
import XCTest

@testable import Overgrove

/// Bare repositories that host linked worktrees (#222, security-review.md T14 / SEC-T14-04), with real git.
///
/// Layout: `repo.git` (bare) with linked worktrees `wt-a` and `wt-b`, the arrangement worktree-heavy users keep.
final class BareRepositoryRegistrationTests: XCTestCase {
    private var cleanup: [URL] = []

    override func tearDown() {
        for url in cleanup { try? FileManager.default.removeItem(at: url) }
    }

    private struct Layout {
        let base: URL
        let bare: URL
        let worktreeA: URL
        let worktreeB: URL
        let environment: GitEnvironment
    }

    /// Real paths throughout (`/var` is a link to `/private/var`), as the registrar compares after `realpath(3)`.
    private func makeLayout(bareName: String = "repo.git") async throws -> Layout {
        let source = try await GitTestRepository.make()
        cleanup.append(source.root)
        try source.write("README", "hello\n")
        try await source.git(["add", "README"])
        try await source.git(["commit", "-q", "-m", "first"])

        let temporary = try XCTUnwrap(PathValidator.canonical(FileManager.default.temporaryDirectory))
        let base = temporary.appendingPathComponent("overgrove-bare-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        cleanup.append(base)
        let bare = base.appendingPathComponent(bareName, isDirectory: true)
        try await source.git(["clone", "-q", "--bare", "--", source.root.path, bare.path])

        let repository = GitTestRepository(root: bare, environment: source.environment)
        let worktreeA = base.appendingPathComponent("wt-a", isDirectory: true)
        let worktreeB = base.appendingPathComponent("wt-b", isDirectory: true)
        try await repository.git(["worktree", "add", "-q", "-b", "a", "--", worktreeA.path, "main"])
        try await repository.git(["worktree", "add", "-q", "-b", "b", "--", worktreeB.path, "main"])
        return Layout(
            base: base, bare: bare, worktreeA: worktreeA, worktreeB: worktreeB, environment: source.environment)
    }

    private func registrar(_ environment: GitEnvironment) -> RepositoryRegistrar {
        RepositoryRegistrar(probe: { kind, folder in
            try await GitClient(environment: environment).run(kind.command, in: folder, safety: .preInspection).stdout
        })
    }

    private func assertRefused(
        _ folder: URL,
        _ expected: RegistrationError,
        environment: GitEnvironment,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let registration = try await registrar(environment).register(folder)
            XCTFail("registered \(registration.entry.locationPath) for \(folder.path)", file: file, line: line)
        } catch {
            XCTAssertEqual(error, expected, folder.path, file: file, line: line)
        }
    }

    // MARK: - Registration

    func testBareRepositoryRegistersItsGitDirectoryWithoutARoot() async throws {
        let layout = try await makeLayout()
        let registration = try await registrar(layout.environment).register(layout.bare)

        XCTAssertNil(registration.entry.rootPath)
        XCTAssertEqual(registration.entry.commonDirectoryPath, layout.bare.path)
        XCTAssertTrue(registration.entry.isBare)
        XCTAssertEqual(registration.entry.name, "repo.git")
        XCTAssertNil(registration.notice, "the picked folder is the one registered")

        let repository = registration.entry.repository
        XCTAssertNil(repository.rootURL)
        XCTAssertTrue(repository.isBare)
        XCTAssertEqual(repository.commonGitDirectoryURL.path, layout.bare.path)
    }

    /// Picking the bare repository or any of its linked worktrees (or a folder inside one) gives one entry.
    func testBareRepositoryAndItsLinkedWorktreesDedupeToOneEntry() async throws {
        let layout = try await makeLayout()
        let subfolder = layout.worktreeA.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
        let registrar = registrar(layout.environment)

        let fromBare = try await registrar.register(layout.bare)
        for folder in [layout.worktreeA, layout.worktreeB, subfolder] {
            let registration = try await registrar.register(folder)
            XCTAssertEqual(registration.entry, fromBare.entry, folder.path)
            XCTAssertEqual(registration.notice, "Overgrove added the repository at \(layout.bare.path).", folder.path)
        }

        let defaults = try XCTUnwrap(UserDefaults(suiteName: "overgrove-bare-\(UUID().uuidString)"))
        let registry = await RepositoryRegistry(defaults: defaults)
        let worktreeFirst = try await registrar.register(layout.worktreeB)
        let first = await registry.add(worktreeFirst.entry)
        let second = await registry.add(fromBare.entry)
        XCTAssertEqual(first, .added)
        XCTAssertEqual(second, .alreadyRegistered)
        let stored = await registry.repositories
        XCTAssertEqual(stored, [fromBare.entry])
    }

    /// A bare repository kept as the `.git` of a folder (`core.bare = true`), and the `.bare` + `.git` file layout:
    /// picking the folder registers the bare repository, because its `.git` entry leads there on disk.
    func testFolderWhoseGitEntryLeadsToABareRepositoryRegistersIt() async throws {
        let dotGit = try await makeLayout(bareName: ".git")
        let parent = dotGit.bare.deletingLastPathComponent()
        for folder in [parent, dotGit.bare, dotGit.worktreeA] {
            let registration = try await registrar(dotGit.environment).register(folder)
            XCTAssertNil(registration.entry.rootPath, folder.path)
            XCTAssertEqual(registration.entry.commonDirectoryPath, dotGit.bare.path, folder.path)
        }

        let hidden = try await makeLayout(bareName: ".bare")
        let holder = hidden.bare.deletingLastPathComponent()
        try "gitdir: ./.bare\n".write(to: holder.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        let registration = try await registrar(hidden.environment).register(holder)
        XCTAssertNil(registration.entry.rootPath)
        XCTAssertEqual(registration.entry.commonDirectoryPath, hidden.bare.path)
    }

    // MARK: - Refusals (SEC-T14-04)

    /// A subfolder of the bare repository and its administrative `worktrees/<id>` folder are git directories too
    /// (git reports both as bare), but they are not the repository.
    func testInsideTheBareRepositoryIsRefused() async throws {
        let layout = try await makeLayout()
        let refs = layout.bare.appendingPathComponent("refs", isDirectory: true)
        let admin = layout.bare.appendingPathComponent("worktrees/wt-a", isDirectory: true)
        for folder in [refs, admin] {
            await assertRefused(folder, .insideGitDirectory, environment: layout.environment)
        }
    }

    /// A copy of a linked worktree: its `.git` file still names `repo.git/worktrees/wt-a`, whose back-pointer
    /// leads to the original. git believes the copy is that worktree; the registrar does not.
    func testSECT14_04_folderWhoseGitFilePointsAtAnotherWorktreesEntryIsRefused() async throws {
        let layout = try await makeLayout()
        let copy = layout.base.appendingPathComponent("copy", isDirectory: true)
        try FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: layout.worktreeA.appendingPathComponent(".git"), to: copy.appendingPathComponent(".git"))

        let raw = try await GitClient(environment: layout.environment)
            .run(.probeGitDirectory, in: copy, safety: .preInspection).stdout
        XCTAssertEqual(try GitDirectoryProbeParser.parse(raw).commonDirectory.path, layout.bare.path)

        await assertRefused(copy, .inconsistentRepository, environment: layout.environment)
    }

    /// A folder made to look like a git directory whose `commondir` names the bare repository. git reports the
    /// bare repository as its shared directory; the folder's own git directory is not that one, so it is refused.
    func testSECT14_04_forgedCommonDirectoryNamingABareRepositoryIsRefused() async throws {
        let layout = try await makeLayout()
        let forged = layout.base.appendingPathComponent("forged", isDirectory: true)
        try FileManager.default.createDirectory(
            at: forged.appendingPathComponent("refs", isDirectory: true), withIntermediateDirectories: true)
        try "ref: refs/heads/main\n".write(
            to: forged.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "\(layout.bare.path)\n".write(
            to: forged.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)

        let raw = try await GitClient(environment: layout.environment)
            .run(.probeGitDirectory, in: forged, safety: .preInspection).stdout
        let probe = try GitDirectoryProbeParser.parse(raw)
        XCTAssertEqual(probe.commonDirectory.path, layout.bare.path, "git believes the forgery")

        await assertRefused(forged, .insideGitDirectory, environment: layout.environment)
    }

    /// Security review of #222: a folder whose `.git` file points at a bare repository somewhere else is not that
    /// repository's holder. git follows the file; the registrar refuses instead of registering an unrelated repository.
    func testSECT14_04_gitFilePointingAtABareRepositoryElsewhereIsRefused() async throws {
        let layout = try await makeLayout()
        let decoy = layout.base.appendingPathComponent("decoy", isDirectory: true)
        try FileManager.default.createDirectory(at: decoy, withIntermediateDirectories: true)
        try "gitdir: \(layout.bare.path)\n".write(
            to: decoy.appendingPathComponent(".git"), atomically: true, encoding: .utf8)

        let raw = try await GitClient(environment: layout.environment)
            .run(.probeGitDirectory, in: decoy, safety: .preInspection).stdout
        XCTAssertTrue(try GitDirectoryProbeParser.parse(raw).isBare, "git treats the decoy as the bare repository")

        await assertRefused(decoy, .inconsistentRepository, environment: layout.environment)
    }

    /// `core.bare = true` with a `core.worktree`: git ignores the work tree and reports a bare repository, so it is
    /// registered as one (commands run in the git directory). The local `core.worktree` is still reported when the
    /// repository's configuration is inspected (SEC-T14-03).
    func testBareRepositoryWithCoreWorktreeRegistersAsBareAndIsReported() async throws {
        let layout = try await makeLayout()
        let elsewhere = layout.base.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try await GitTestRepository(root: layout.bare, environment: layout.environment)
            .git(["config", "core.worktree", elsewhere.path])

        let registration = try await registrar(layout.environment).register(layout.bare)
        XCTAssertNil(registration.entry.rootPath)
        XCTAssertEqual(registration.entry.commonDirectoryPath, layout.bare.path)

        let config = try await GitClient(environment: layout.environment)
            .run(.configList, in: layout.bare, safety: .preInspection)
        let report = RepoConfigInspector.inspect(try ConfigParser.parse(config.stdout, truncated: config.isTruncated))
            .report
        XCTAssertTrue(
            report.findings.contains { $0.entry.key == "core.worktree" && $0.threat == "T14" },
            "\(report.findings)")
    }

    // MARK: - Opening

    /// The registered bare repository loads its worktree list from the shared git directory: the bare main record
    /// is not queried, and both linked worktrees get their status.
    func testRegisteredBareRepositoryListsItsLinkedWorktrees() async throws {
        let layout = try await makeLayout()
        let repository = try await registrar(layout.environment).register(layout.bare).entry.repository
        let client = GitClient(environment: layout.environment)

        // The service inspects the repository's configuration itself (#88).
        let overview = try await RepositoryService(client: client).loadOverview(of: repository)
        XCTAssertEqual(overview.entries.count, 3)
        let main = try XCTUnwrap(overview.entries.first)
        XCTAssertTrue(main.worktree.isBare)
        XCTAssertEqual(main.status, .notQueried(.bare))
        let linked = overview.entries.dropFirst()
        XCTAssertEqual(linked.map(\.worktree.branch), ["refs/heads/a", "refs/heads/b"])
        for entry in linked {
            guard case .loaded = entry.status else { return XCTFail("\(entry.worktree.path): \(entry.status)") }
        }
    }
}
