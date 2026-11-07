import Foundation
import XCTest

@testable import Overgrove

private let oid = ObjectID(String(repeating: "ab", count: 20))!
private let parent = ObjectID(String(repeating: "cd", count: 20))!

private let allReadOnlyCommands: [ReadOnlyGitCommand] = [
    .version, .probeRepository, .configList, .worktreeList, .status, .refs,
    .aheadBehind(local: FullRefName("refs/heads/feat/12-x")!, upstream: FullRefName("refs/remotes/origin/feat/12-x")!),
    .stashList, .stashFiles(oid), .stashPatch(oid, path: GitPath("--output=x"), fromUntracked: false),
    .stashPatch(oid, path: GitPath("new.txt"), fromUntracked: true), .graphPage(skip: 500, limit: 500),
    .commitMeta(oid), .commitFiles(oid, firstParent: nil), .commitFiles(oid, firstParent: parent),
    .commitPatch(oid, parent: parent, path: GitPath("-x")), .worktreeDiff(path: GitPath("a b.txt"), staged: true),
    .worktreeDiff(path: GitPath(":(exclude)x"), staged: false),
    .fileHistory(path: GitPath("*"), limit: 100),
]

/// SEC-T9-01, SEC-T13-01 (docs/design/security-review.md) and catalog §3–§4.
final class GitCommandTests: XCTestCase {
    func testSECT13_01_OnlyReadOnlySubcommandsExist() throws {
        let allowed: [String: Set<String>?] = [
            "version": nil, "rev-parse": nil, "config": ["--list"], "worktree": ["list"], "status": nil,
            "for-each-ref": nil, "rev-list": nil, "stash": ["list", "show"], "log": nil, "diff-tree": nil, "diff": nil,
        ]
        for command in allReadOnlyCommands {
            let arguments = try command.subcommandArguments()
            let subcommand = try XCTUnwrap(arguments.first)
            XCTAssertTrue(allowed.keys.contains(subcommand), "\(command) uses \(subcommand)")
            if let second = allowed[subcommand] ?? nil {
                XCTAssertTrue(second.contains(arguments[1]), "\(command): \(subcommand) \(arguments[1])")
            }
        }
        XCTAssertEqual(FetchCommand.fetch(remote: RemoteName("origin")!).subcommandArguments().first, "fetch")
    }

    func testSECT9_01_FinalArgumentSnapshot() throws {
        let environment = GitEnvironment(
            executable: URL(fileURLWithPath: "/usr/bin/git"),
            version: GitVersion(major: 2, minor: 50, patch: 1)
        )
        let common = GitEnvironment.commonArguments
        let expected: [[String]] = [
            ["version"],
            ["rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir", "--is-bare-repository"],
            ["config", "--list", "--show-scope", "-z", "--includes"],
            ["worktree", "list", "--porcelain", "-z"],
            [
                "status", "--porcelain=v2", "-z", "--branch", "--show-stash", "--untracked-files=all",
                "--ignore-submodules=dirty",
            ],
            [
                "for-each-ref",
                "--format=%(refname)%00%(objectname)%00%(*objectname)%00%(upstream)%00%(HEAD)%00%(committerdate:unix)%00%(symref)%00%(upstream:track,nobracket)",
                "refs/heads", "refs/remotes", "refs/tags",
            ],
            [
                "rev-list", "--left-right", "--count", "--end-of-options",
                "refs/remotes/origin/feat/12-x...refs/heads/feat/12-x",
            ],
            ["stash", "list", "-z", "--format=%gd%x00%H%x00%gs%x00%ct"],
            [
                "stash", "show", "--include-untracked", "--numstat", "-z", "--no-ext-diff", "--no-textconv",
                "--end-of-options", oid.hex,
            ],
            [
                "diff-tree", "-p", "-M", "--no-ext-diff", "--no-textconv", "--end-of-options", "\(oid.hex)^1", oid.hex,
                "--", "--output=x",
            ],
            [
                "diff-tree", "-p", "-M", "--no-ext-diff", "--no-textconv", "--root", "--end-of-options", "\(oid.hex)^3",
                "--", "new.txt",
            ],
            [
                "log", "--exclude=refs/stash", "--all", "--date-order", "-z", ReadOnlyGitCommand.logFormat,
                "--skip=500", "-n", "500",
            ],
            [
                "log", "-1", "-z", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%cn%x00%ce%x00%ct%x00%B",
                "--end-of-options", oid.hex,
            ],
            [
                "diff-tree", "-r", "-z", "--raw", "--numstat", "-M", "--no-ext-diff", "--no-textconv", "--no-commit-id",
                "--root", "--end-of-options", oid.hex,
            ],
            [
                "diff-tree", "-r", "-z", "--raw", "--numstat", "-M", "--no-ext-diff", "--no-textconv", "--no-commit-id",
                "--root", "--end-of-options", parent.hex, oid.hex,
            ],
            [
                "diff-tree", "-p", "-M", "--no-ext-diff", "--no-textconv", "--root", "--end-of-options", parent.hex,
                oid.hex, "--", "-x",
            ],
            ["diff", "--no-ext-diff", "--no-textconv", "-M", "--cached", "--", "a b.txt"],
            ["diff", "--no-ext-diff", "--no-textconv", "-M", "--", ":(exclude)x"],
            ["log", "--follow", "-z", ReadOnlyGitCommand.logFormat, "-n", "100", "--", "*"],
        ]
        XCTAssertEqual(allReadOnlyCommands.count, expected.count)
        for (command, subcommand) in zip(allReadOnlyCommands, expected) {
            XCTAssertEqual(environment.arguments(for: try command.subcommandArguments()), common + subcommand)
        }
        XCTAssertEqual(
            environment.arguments(
                for: FetchCommand.fetch(remote: RemoteName("origin")!).subcommandArguments(),
                fetchAuthentication: ["-c", "credential.helper="]
            ),
            common + [
                "-c", "credential.helper=", "fetch", "--prune", "--no-recurse-submodules", "--progress",
                "--upload-pack=git-upload-pack", "--end-of-options", "origin",
            ]
        )
    }

    func testLossyPathsAreRejected() {
        let lossy = GitPath(raw: Data([0x61, 0xFF]))
        for command in [
            ReadOnlyGitCommand.fileHistory(path: lossy, limit: 10),
            .worktreeDiff(path: lossy, staged: false),
        ] {
            XCTAssertThrowsError(try command.subcommandArguments()) {
                guard case .invalidArgument = $0 as? GitError else { return XCTFail("\($0)") }
            }
        }
    }

    func testLimitsAreClamped() throws {
        XCTAssertEqual(
            try ReadOnlyGitCommand.graphPage(skip: -5, limit: 0).subcommandArguments().suffix(3),
            ["--skip=0", "-n", "1"])
    }
}

/// GitClient against real repositories.
final class GitClientIntegrationTests: XCTestCase {
    private var repository: GitTestRepository!
    private var client: GitClient!
    private let inspected = RepoSafetyContext(
        inspectedNeutralization: [], fetchAuthentication: [], trustedSSHCommand: nil)

    override func setUp() async throws {
        repository = try await GitTestRepository.make()
        client = GitClient(environment: repository.environment)
    }

    override func tearDown() {
        repository.remove()
    }

    func testStatusAndWorktreeListSucceed() async throws {
        try repository.write("a.txt", "a\n")
        let status = try await client.run(.status, in: repository.root, safety: inspected)
        XCTAssertTrue(String(decoding: status.stdout, as: UTF8.self).contains("? a.txt"))
        let worktrees = try await client.run(.worktreeList, in: repository.root, safety: inspected)
        XCTAssertTrue(String(decoding: worktrees.stdout, as: UTF8.self).hasPrefix("worktree "))
        let version = try await client.run(.version, in: nil, safety: .preInspection)
        XCTAssertTrue(String(decoding: version.stdout, as: UTF8.self).hasPrefix("git version "))
    }

    func testUntrackedPreviewAcceptsExitCodeOne() async throws {
        try repository.write("new.txt", "hello\n")
        let file = try XCTUnwrap(PathValidator.worktreeFile(GitPath("new.txt"), in: repository.root))
        let output = try await client.run(.untrackedPreview(file), in: repository.root, safety: inspected)
        XCTAssertTrue(String(decoding: output.stdout, as: UTF8.self).contains("+hello"))
    }

    func testCommandsNeedInspectionFirst() async {
        do {
            _ = try await client.run(.status, in: repository.root, safety: .preInspection)
            XCTFail("status must not run before the configuration is inspected")
        } catch let error as GitError {
            guard case .configInspectionFailed = error else { return XCTFail("got \(error)") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testStashPatchForTrackedAndUntrackedFiles() async throws {
        try repository.write("tracked.txt", "v1\n")
        try await repository.git(["add", "tracked.txt"])
        try await repository.git(["commit", "-q", "-m", "base"])
        try repository.write("tracked.txt", "v2\n")
        try repository.write("untracked.txt", "fresh\n")
        try await repository.git(["stash", "push", "-q", "--include-untracked", "-m", "wip"])
        let listed = try await repository.git(["rev-parse", "stash@{0}"])
        let stash = try XCTUnwrap(
            ObjectID(String(decoding: listed.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)))

        let tracked = try await client.run(
            .stashPatch(stash, path: GitPath("tracked.txt"), fromUntracked: false), in: repository.root,
            safety: inspected
        )
        XCTAssertTrue(String(decoding: tracked.stdout, as: UTF8.self).contains("+v2"))
        let untracked = try await client.run(
            .stashPatch(stash, path: GitPath("untracked.txt"), fromUntracked: true), in: repository.root,
            safety: inspected
        )
        XCTAssertTrue(String(decoding: untracked.stdout, as: UTF8.self).contains("+fresh"))
    }

    func testNotARepositoryIsClassified() async throws {
        let plain = FileManager.default.temporaryDirectory.appendingPathComponent(
            "overgrove-plain-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: plain) }
        do {
            _ = try await client.run(.status, in: plain, safety: inspected)
            XCTFail("expected notARepository")
        } catch let error as GitError {
            guard case .notARepository = error else { return XCTFail("got \(error)") }
        }
    }

    func testMissingWorktreeIsClassified() async {
        do {
            _ = try await client.run(.status, in: URL(fileURLWithPath: "/nonexistent/worktree"), safety: inspected)
            XCTFail("expected worktreeMissing")
        } catch let error as GitError {
            XCTAssertEqual(error, .worktreeMissing(path: "/nonexistent/worktree"))
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    func testCancelledWaiterLeavesTheQueue() async throws {
        let client = GitClient(environment: repository.environment, maximumConcurrency: 1)
        let root = repository.root
        let safety = inspected
        // Occupy the only slot with a slow command, then cancel a queued one.
        let blocker = Task { try await client.run(.graphPage(skip: 0, limit: 1), in: root, safety: safety) }
        let queued = Task { try await client.run(.status, in: root, safety: safety) }
        queued.cancel()
        do {
            _ = try await queued.value
        } catch let error as GitError {
            XCTAssertEqual(error, .cancelled)
        }
        _ = try? await blocker.value
        let after = try await client.run(.status, in: root, safety: safety)
        XCTAssertNotNil(after, "the slot is not leaked")
    }

    func testConcurrencyIsCapped() async throws {
        let client = GitClient(environment: repository.environment, maximumConcurrency: 3)
        let root = repository.root
        let safety = inspected
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<16 {
                group.addTask { _ = try await client.run(.status, in: root, safety: safety) }
            }
            try await group.waitForAll()
        }
        let peak = await client.peakConcurrency
        XCTAssertLessThanOrEqual(peak, 3)
        XCTAssertGreaterThan(peak, 0)
    }
}

/// PathValidator.worktreeFile (T14, security review of #148).
final class WorktreeFileTests: XCTestCase {
    func testOnlyContainedRegularFilesAndLinksAreAccepted() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("overgrove-wtf-\(UUID().uuidString)")
        let outside = root.appendingPathComponent("outside")
        let worktree = root.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "x".write(to: worktree.appendingPathComponent("ok.txt"), atomically: true, encoding: .utf8)
        try "secret".write(to: outside.appendingPathComponent("secret"), atomically: true, encoding: .utf8)
        XCTAssertEqual(mkfifo(worktree.appendingPathComponent("pipe").path, 0o600), 0)
        try FileManager.default.createSymbolicLink(
            atPath: worktree.appendingPathComponent("link").path, withDestinationPath: "../outside/secret"
        )

        XCTAssertNotNil(PathValidator.worktreeFile(GitPath("ok.txt"), in: worktree))
        XCTAssertNotNil(PathValidator.worktreeFile(GitPath("link"), in: worktree), "links are shown as link text")
        XCTAssertNil(PathValidator.worktreeFile(GitPath("pipe"), in: worktree), "a FIFO would block git")
        XCTAssertNil(PathValidator.worktreeFile(GitPath("/etc/hosts"), in: worktree))
        XCTAssertNil(PathValidator.worktreeFile(GitPath("../outside/secret"), in: worktree))
        XCTAssertNil(PathValidator.worktreeFile(GitPath("missing.txt"), in: worktree))
        XCTAssertNil(PathValidator.worktreeFile(GitPath(raw: Data([0x61, 0xFF])), in: worktree))
    }
}

final class FetchBlockingTests: XCTestCase {
    func testFetchIsRefusedWhenTheRepositoryBlocksIt() async throws {
        let environment = try await GitEnvironment.discover()
        let client = GitClient(environment: environment)
        let safety = RepoSafetyContext(
            inspectedNeutralization: [],
            fetchAuthentication: [],
            trustedSSHCommand: nil,
            fetchBlockingReason: "local CA"
        )
        do {
            _ = try await client.fetch(
                .fetch(remote: RemoteName("origin")!),
                in: Repository(rootURL: nil, commonGitDirectoryURL: URL(fileURLWithPath: "/tmp"), isBare: true),
                safety: safety)
            XCTFail("expected configInspectionFailed")
        } catch let error as GitError {
            XCTAssertEqual(error, .configInspectionFailed(reason: "local CA"))
        }
    }
}
