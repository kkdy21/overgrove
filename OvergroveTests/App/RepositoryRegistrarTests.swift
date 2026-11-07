import Foundation
import XCTest

@testable import Overgrove

/// `RepositoryRegistrar` (#84, overview.md §3.2 and §9, T14): validate the picked folder, then run only the probe.
final class RepositoryRegistrarTests: XCTestCase {
    private var cleanup: [URL] = []

    override func tearDown() {
        for url in cleanup { try? FileManager.default.removeItem(at: url) }
    }

    /// Counts probe runs; `GitClient` does the real work.
    private actor ProbeLog {
        private(set) var folders: [URL] = []
        func record(_ folder: URL) { folders.append(folder) }
    }

    private func registrar(environment: GitEnvironment, log: ProbeLog? = nil) -> RepositoryRegistrar {
        RepositoryRegistrar(probe: { folder in
            await log?.record(folder)
            return try await GitClient(environment: environment)
                .run(.probeRepository, in: folder, safety: .preInspection).stdout
        })
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
        let probed = await log.folders
        XCTAssertEqual(probed.count, 1, "the probe is the only git command")
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
        let environment = try await GitEnvironment.discover()
        let plain = try temporaryDirectory()
        do {
            _ = try await registrar(environment: environment).register(plain)
            XCTFail("expected a refusal")
        } catch {
            guard case .git(.notARepository) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(error.message, "This folder is not a Git repository.")
        }
    }

    func testBareRepositoryIsRefusedWithGuidance() async throws {
        let repository = try await makeRepository()
        let bare = try temporaryDirectory().appendingPathComponent("bare.git", isDirectory: true)
        try await repository.git(["clone", "-q", "--bare", "--", repository.root.path, bare.path])

        for folder in [bare, repository.root.appendingPathComponent(".git", isDirectory: true)] {
            do {
                _ = try await registrar(environment: repository.environment).register(folder)
                XCTFail("expected a refusal for \(folder.lastPathComponent)")
            } catch {
                XCTAssertEqual(error, .bareRepository, folder.lastPathComponent)
            }
        }
    }

    /// parsing-spec.md §11.2: a control character in the path is refused before git runs.
    func testControlCharactersAreRefusedBeforeTheProbe() async throws {
        let folder = try temporaryDirectory("new\nline")
        let log = ProbeLog()
        let registrar = RepositoryRegistrar(probe: { folder in
            await log.record(folder)
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
        let registrar = RepositoryRegistrar(probe: { _ in
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
        let registrar = RepositoryRegistrar(probe: { _ in Data("/tmp/a\n".utf8) })
        do {
            _ = try await registrar.register(folder)
            XCTFail("expected a refusal")
        } catch {
            guard case .git(.parseFailed(let parser, _)) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(parser, "ProbeParser")
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
                XCTFail("registered \(registration.entry.rootPath) for \(folder.lastPathComponent)")
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
            XCTFail("registered \(registration.entry.rootPath)")
        } catch {
            XCTAssertEqual(error, .inconsistentRepository)
        }
    }

    func testProbeNamingFoldersThatDoNotExistIsRefused() async throws {
        let folder = try temporaryDirectory()
        let output = "\(folder.path)\n/tmp/overgrove-missing-\(UUID().uuidString)/.git\nfalse\n"
        do {
            _ = try await RepositoryRegistrar(probe: { _ in Data(output.utf8) }).register(folder)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error, .inconsistentRepository)
        }
    }

    func testBareFlagFromTheProbeIsRefused() async throws {
        let folder = try temporaryDirectory()
        let output = "\(folder.path)\n\(folder.path)/.git\ntrue\n"
        do {
            _ = try await RepositoryRegistrar(probe: { _ in Data(output.utf8) }).register(folder)
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(error, .bareRepository)
        }
    }
}
