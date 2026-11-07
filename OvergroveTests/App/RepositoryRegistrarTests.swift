import Foundation
import XCTest

@testable import Overgrove

/// `RepositoryRegistrar` (#84, #222, overview.md §3.2 and §9, T14): validate the picked folder, then run only the
/// probes.
final class RepositoryRegistrarTests: XCTestCase {
    private var cleanup: [URL] = []

    override func tearDown() {
        for url in cleanup { try? FileManager.default.removeItem(at: url) }
    }

    /// Counts probe runs; `GitClient` does the real work.
    private actor ProbeLog {
        private(set) var runs: [(RegistrationProbe, URL)] = []
        var folders: [URL] { runs.map(\.1) }
        var kinds: [RegistrationProbe] { runs.map(\.0) }
        func record(_ kind: RegistrationProbe, _ folder: URL) { runs.append((kind, folder)) }
    }

    private func registrar(environment: GitEnvironment, log: ProbeLog? = nil) -> RepositoryRegistrar {
        RepositoryRegistrar(probe: { kind, folder in
            await log?.record(kind, folder)
            return try await GitClient(environment: environment)
                .run(kind.command, in: folder, safety: .preInspection).stdout
        })
    }

    /// A fake probe: `gitDirectory` and `worktree` answers as git would print them.
    private func fake(gitDirectory: String, worktree: String = "") -> RepositoryRegistrar {
        RepositoryRegistrar(probe: { kind, _ in
            Data((kind == .gitDirectory ? gitDirectory : worktree).utf8)
        })
    }

    private func assertRefused(
        _ registrar: RepositoryRegistrar,
        _ folder: URL,
        _ expected: RegistrationError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            let registration = try await registrar.register(folder)
            XCTFail("registered \(registration.entry.locationPath) for \(folder.path)", file: file, line: line)
        } catch {
            XCTAssertEqual(error, expected, folder.path, file: file, line: line)
        }
    }

    /// A repository with one commit, at its real path (`/var` is a link to `/private/var` on macOS).
    private func makeRepository() async throws -> GitTestRepository {
        let made = try await GitTestRepository.make()
        let real = try XCTUnwrap(PathValidator.canonical(made.root))
        cleanup.append(real)
        let repository = GitTestRepository(root: real, environment: made.environment)
        try repository.write("README", "hello\n")
        try await repository.git(["add", "README"])
        try await repository.git(["commit", "-q", "-m", "first"])
        return repository
    }

    private func temporaryDirectory(_ name: String = UUID().uuidString) throws -> URL {
        let base = try XCTUnwrap(PathValidator.canonical(FileManager.default.temporaryDirectory))
        let url = base.appendingPathComponent("overgrove-registrar-\(name)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        cleanup.append(url)
        return url
    }

    func testMainWorktreeRegistersItsRootAndCommonDirectory() async throws {
        let repository = try await makeRepository()
        let log = ProbeLog()
        let registration = try await registrar(environment: repository.environment, log: log).register(repository.root)

        XCTAssertEqual(registration.entry.rootPath, repository.root.path)
        XCTAssertEqual(registration.entry.commonDirectoryPath, repository.root.appendingPathComponent(".git").path)
        XCTAssertFalse(registration.isThroughSymlink)
        XCTAssertNil(registration.notice)
        let kinds = await log.kinds
        XCTAssertEqual(kinds, [.gitDirectory, .worktree], "the two probes are the only git commands")
    }

    func testSubfolderRegistersTheRepositoryWithANotice() async throws {
        let repository = try await makeRepository()
        let subfolder = repository.root.appendingPathComponent("src/app", isDirectory: true)
        try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)

        let registration = try await registrar(environment: repository.environment).register(subfolder)
        XCTAssertEqual(registration.entry.rootPath, repository.root.path)
        XCTAssertEqual(registration.notice, "Overgrove added the repository at \(repository.root.path).")
    }

    /// Worktrees of one repository share the common directory, so they dedupe to one registration.
    func testLinkedWorktreeResolvesToTheSameRepository() async throws {
        let repository = try await makeRepository()
        let worktree = try temporaryDirectory().appendingPathComponent("wt", isDirectory: true)
        try await repository.git(["worktree", "add", "-q", "-b", "feature", "--", worktree.path])

        let registrar = registrar(environment: repository.environment)
        let main = try await registrar.register(repository.root)
        let linked = try await registrar.register(worktree)
        XCTAssertEqual(linked.entry, main.entry)
        XCTAssertNotNil(linked.notice)
    }

    /// SEC-T14-01: a path through a symbolic link registers the real location and says so.
    func testSymlinkRegistersTheRealPathWithAWarning() async throws {
        let repository = try await makeRepository()
        let link = try temporaryDirectory().appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repository.root)

        let registration = try await registrar(environment: repository.environment).register(link)
        XCTAssertTrue(registration.isThroughSymlink)
        XCTAssertEqual(registration.entry.rootPath, repository.root.path)
        XCTAssertEqual(
            registration.notice,
            "The folder you chose is a symbolic link. Overgrove added the repository at \(repository.root.path).")
    }

    func testFolderOutsideARepositoryIsRefused() async throws {
        let environment = try await GitEnvironment.discoverForTesting()
        let plain = try temporaryDirectory()
        do {
            _ = try await registrar(environment: environment).register(plain)
            XCTFail("expected a refusal")
        } catch {
            guard case .git(.notARepository) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(error.message, "This folder is not a Git repository.")
        }
    }

    func testInsideAGitDirectoryIsRefusedWithGuidance() async throws {
        let repository = try await makeRepository()
        let gitDirectory = repository.root.appendingPathComponent(".git", isDirectory: true)
        for folder in [gitDirectory, gitDirectory.appendingPathComponent("refs", isDirectory: true)] {
            await assertRefused(registrar(environment: repository.environment), folder, .insideGitDirectory)
        }
        XCTAssertTrue(RegistrationError.insideGitDirectory.message.contains("bare repository"))
    }

    /// parsing-spec.md §11.2: a control character in the path is refused before git runs.
    func testControlCharactersAreRefusedBeforeTheProbe() async throws {
        let folder = try temporaryDirectory("new\nline")
        let log = ProbeLog()
        let registrar = RepositoryRegistrar(probe: { kind, folder in
            await log.record(kind, folder)
            return Data()
        })
        do {
            _ = try await registrar.register(folder)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error, .invalidPath(.controlCharacters))
        }
        let probed = await log.folders
        XCTAssertEqual(probed, [], "git never ran")
    }

    func testMissingFolderAndFileAreRefusedBeforeTheProbe() async throws {
        let base = try temporaryDirectory()
        let file = base.appendingPathComponent("file.txt")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        let registrar = RepositoryRegistrar(probe: { _, _ in
            XCTFail("the probe must not run")
            return Data()
        })
        let cases: [(URL, RegistrationError)] = [
            (base.appendingPathComponent("missing"), .invalidPath(.doesNotExist)),
            (file, .invalidPath(.notADirectory)),
        ]
        for (url, expected) in cases {
            do {
                _ = try await registrar.register(url)
                XCTFail("expected \(expected)")
            } catch {
                XCTAssertEqual(error, expected)
            }
        }
    }

    func testMalformedProbeOutputIsAParseFailure() async throws {
        let folder = try temporaryDirectory()
        for (registrar, parser) in [
            (fake(gitDirectory: "/tmp/a\n"), "GitDirectoryProbeParser"),
            (
                fake(gitDirectory: "\(folder.path)/.git\n\(folder.path)/.git\nfalse\ntrue\n", worktree: "/tmp/a\n"),
                "ProbeParser"
            ),
        ] {
            do {
                _ = try await registrar.register(folder)
                XCTFail("expected a refusal")
            } catch {
                guard case .git(.parseFailed(let name, _)) = error else { return XCTFail("\(error)") }
                XCTAssertEqual(name, parser)
            }
        }
    }

    /// `--separate-git-dir`: the worktree's `.git` file leads to the shared directory, so the worktree is the root.
    func testSeparateGitDirectoryRegistersTheWorktree() async throws {
        let repository = try await makeRepository()
        let base = try temporaryDirectory()
        let worktree = base.appendingPathComponent("work", isDirectory: true)
        let meta = base.appendingPathComponent("meta", isDirectory: true)
        try await repository.git(["init", "-q", "--separate-git-dir", meta.path, "--", worktree.path])

        let registration = try await registrar(environment: repository.environment).register(worktree)
        XCTAssertEqual(registration.entry.rootPath, worktree.path)
        XCTAssertEqual(registration.entry.commonDirectoryPath, meta.path)
    }

    /// SEC-T14-04 (security review of #84): `core.worktree` makes the probe report a worktree outside the picked
    /// folder. Registering it would run later commands somewhere the shared directory does not describe.
    func testSECT14_04_coreWorktreePointingElsewhereIsRefused() async throws {
        let repository = try await makeRepository()
        let base = try temporaryDirectory()
        let picked = base.appendingPathComponent("picked", isDirectory: true)
        let meta = picked.appendingPathComponent("meta", isDirectory: true)
        let elsewhere = base.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        try await repository.git(["init", "-q", "--separate-git-dir", meta.path, "--", picked.path])
        try await GitTestRepository(root: picked, environment: repository.environment)
            .git(["config", "core.worktree", elsewhere.path])
        // The plain-repository form too: `core.worktree` in an ordinary `.git` directory.
        try await repository.git(["config", "core.worktree", elsewhere.path])

        for folder in [picked, repository.root] {
            do {
                let registration = try await registrar(environment: repository.environment).register(folder)
                XCTFail("registered \(registration.entry.locationPath) for \(folder.lastPathComponent)")
            } catch {
                XCTAssertEqual(error, .inconsistentRepository, folder.lastPathComponent)
            }
        }
    }

    /// SEC-T14-04: a `.git` file whose administrative directory claims another repository's shared directory
    /// (`commondir`) must not register the picked folder as that repository.
    func testSECT14_04_forgedCommonDirectoryIsRefused() async throws {
        let victim = try await makeRepository()
        let picked = try temporaryDirectory().appendingPathComponent("picked", isDirectory: true)
        let admin = picked.appendingPathComponent("admin", isDirectory: true)
        try FileManager.default.createDirectory(at: admin, withIntermediateDirectories: true)
        try "gitdir: \(admin.path)\n".write(
            to: picked.appendingPathComponent(".git"), atomically: true, encoding: .utf8)
        try "ref: refs/heads/main\n".write(
            to: admin.appendingPathComponent("HEAD"), atomically: true, encoding: .utf8)
        try "\(victim.root.path)/.git\n".write(
            to: admin.appendingPathComponent("commondir"), atomically: true, encoding: .utf8)

        // git itself believes the forgery (that is what makes it dangerous).
        let raw = try await GitClient(environment: victim.environment)
            .run(.probeRepository, in: picked, safety: .preInspection).stdout
        XCTAssertEqual(try ProbeParser.parse(raw).commonDirectory.path, victim.root.appendingPathComponent(".git").path)

        do {
            let registration = try await registrar(environment: victim.environment).register(picked)
            XCTFail("registered \(registration.entry.locationPath)")
        } catch {
            XCTAssertEqual(error, .inconsistentRepository)
        }
    }

    func testProbeNamingFoldersThatDoNotExistIsRefused() async throws {
        let folder = try temporaryDirectory()
        let missing = "/tmp/overgrove-missing-\(UUID().uuidString)"
        await assertRefused(
            fake(
                gitDirectory: "\(missing)/.git\n\(missing)/.git\nfalse\ntrue\n",
                worktree: "\(folder.path)\n\(missing)/.git\nfalse\n"),
            folder, .inconsistentRepository)
        await assertRefused(
            fake(gitDirectory: "\(missing).git\n\(missing).git\ntrue\nfalse\n"), folder, .inconsistentRepository)
    }

    /// The two probes run one after the other; answers that disagree (the repository changed in between, or a
    /// forged answer) are not registered.
    func testProbesThatDisagreeAreRefused() async throws {
        let repository = try await makeRepository()
        let root = repository.root.path
        await assertRefused(
            fake(gitDirectory: "\(root)/.git\n\(root)/.git\nfalse\ntrue\n", worktree: "\(root)\n\(root)/.git\ntrue\n"),
            repository.root, .inconsistentRepository)
        let other = try await makeRepository().root.path
        await assertRefused(
            fake(
                gitDirectory: "\(other)/.git\n\(other)/.git\nfalse\ntrue\n", worktree: "\(root)\n\(root)/.git\nfalse\n"),
            repository.root, .inconsistentRepository)
        // The worktree's own git directory must be the one the first probe reported.
        await assertRefused(
            fake(
                gitDirectory: "\(root)/.git\n\(root)/.git/worktrees/x\nfalse\ntrue\n",
                worktree: "\(root)\n\(root)/.git\nfalse\n"),
            repository.root, .inconsistentRepository)
    }

    func testNotBareAndNotInAWorkTreeIsInsideAGitDirectory() async throws {
        let folder = try temporaryDirectory()
        await assertRefused(
            fake(gitDirectory: "\(folder.path)\n\(folder.path)\nfalse\nfalse\n"), folder, .insideGitDirectory)
    }
}
