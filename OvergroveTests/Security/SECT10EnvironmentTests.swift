import Foundation
import XCTest

@testable import Overgrove

/// T10 inherited environment on the app's real path (security-review.md §2 T10, #93): `GitClient` built with a hostile
/// parent environment still queries the right repository and runs nothing from that environment.
///
/// That each variable is absent from the child is unit-tested in `GitEnvironmentTests` (SEC-T10-01/02, `/usr/bin/env`)
/// and `GHClientTests` (SEC-T10-03). This test runs the real commands instead: it fails if the parent environment is
/// passed through, through `GIT_DIR`/`GIT_WORK_TREE` (wrong repository), `GIT_TRACE` (trace file), and
/// `GIT_SSH_COMMAND` (ssh fetch). Some other variables here could not act even if inherited, because the arguments
/// already block them (e.g. `GIT_EXTERNAL_DIFF` against `--no-ext-diff`); they stay as defense-in-depth canaries.
///
/// The ssh fetches go to a closed local port. OpenSSH reads `~/.ssh/config` from the account's home directory, not
/// `$HOME`, so an unusual user ssh configuration (for example a `ProxyCommand` for every host) could change the error.
final class SECT10EnvironmentTests: XCTestCase {
    private var executables: TestExecutables!
    private var target: GitTestRepository!
    private var decoy: GitTestRepository!
    private var canary: URL!

    private let inspected = RepoSafetyContext(
        inspectedNeutralization: [], fetchAuthentication: [], trustedSSHCommand: nil,
        fetchableRemotes: ["origin", "unreachable"])

    override func setUp() async throws {
        executables = try TestExecutables()
        canary = executables.directory.appendingPathComponent("canary", isDirectory: true)
        target = try await GitTestRepository.make()
        try target.write("target.txt", "v1\n")
        try await target.git(["add", "target.txt"])
        try await target.git(["commit", "-q", "-m", "target"])
        try target.write("target.txt", "v2\n")
        decoy = try await GitTestRepository.make()
        try decoy.write("decoy.txt", "decoy\n")
        try await decoy.git(["add", "decoy.txt"])
        try await decoy.git(["commit", "-q", "-m", "decoy"])
    }

    override func tearDown() {
        decoy?.remove()
        target?.remove()
        executables?.remove()
    }

    private func canaries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: canary.path)) ?? []).sorted()
    }

    /// Variables that redirect git or make it run programs, as another tool or a hostile launcher might set them.
    private func hostileParent(traceFile: URL) throws -> [String: String] {
        let program = { (name: String) in try self.executables.canaryProgram(named: name, canary: self.canary).path }
        let decoyGit = decoy.root.appendingPathComponent(".git").path
        return [
            "HOME": FileManager.default.temporaryDirectory.path,
            "GIT_DIR": decoyGit,
            "GIT_WORK_TREE": decoy.root.path,
            "GIT_INDEX_FILE": decoyGit + "/index",
            "GIT_OBJECT_DIRECTORY": decoyGit + "/objects",
            "GIT_CONFIG_PARAMETERS": "'core.fsmonitor=\(try program("fsmonitor"))'",
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "diff.external",
            "GIT_CONFIG_VALUE_0": try program("config-diff-external"),
            "GIT_EXTERNAL_DIFF": try program("external-diff"),
            "GIT_PAGER": try program("git-pager"),
            "PAGER": try program("pager"),
            "GIT_SSH_COMMAND": try program("ssh-command"),
            "GIT_ASKPASS": try program("askpass"),
            "SSH_ASKPASS": try program("ssh-askpass"),
            "GIT_ALLOW_PROTOCOL": "ext:fd:https:ssh:git:file:http",
            "GIT_TRACE": traceFile.path,
            "GIT_EXEC_PATH": "/nonexistent/overgrove-exec-path",
            "DYLD_INSERT_LIBRARIES": "/nonexistent/overgrove.dylib",
            "GH_TOKEN": "gho_" + String(repeating: "x", count: 36),
        ]
    }

    // MARK: - SEC-T10-01

    func testSECT10_01_HostileParentEnvironmentThroughGitClient() async throws {
        let trace = executables.directory.appendingPathComponent("trace.log")
        let client = GitClient(
            environment: target.environment.fetchingLocalRemotesForTesting,
            parentEnvironment: try hostileParent(traceFile: trace))

        // The target repository is queried, not the one GIT_DIR / GIT_WORK_TREE point at.
        let status = try await client.run(.status, in: target.root, safety: inspected)
        let statusText = String(decoding: status.stdout, as: UTF8.self)
        XCTAssertTrue(statusText.contains("target.txt"), statusText)
        XCTAssertFalse(statusText.contains("decoy.txt"), statusText)

        // No external diff, pager, or fsmonitor from the environment.
        let diff = try await client.run(
            .worktreeDiff(path: GitPath("target.txt"), staged: false), in: target.root, safety: inspected)
        XCTAssertTrue(String(decoding: diff.stdout, as: UTF8.self).contains("+v2"), "git's own diff ran")
        let graph = try await client.run(.graphPage(skip: 0, limit: 10), in: target.root, safety: inspected)
        XCTAssertEqual(try LogParser.parseGraph(graph.stdout).commits.map(\.subject), ["target"])

        // A local fetch, and an ssh fetch that would use GIT_SSH_COMMAND if it were inherited.
        let bare = executables.directory.appendingPathComponent("remote.git")
        try await decoy.git(["init", "-q", "--bare", bare.path])
        try await target.git(["push", "-q", bare.path, "HEAD:refs/heads/main"])
        try await target.git(["remote", "add", "origin", bare.path])
        try await target.git(["remote", "add", "unreachable", "ssh://127.0.0.1:1/x.git"])
        let repository = Repository(
            rootURL: target.root, commonGitDirectoryURL: target.root.appendingPathComponent(".git"), isBare: false)
        _ = try await client.fetch(.fetch(remote: RemoteName("origin")!), in: repository, safety: inspected)
        do {
            _ = try await client.fetch(.fetch(remote: RemoteName("unreachable")!), in: repository, safety: inspected)
            XCTFail("port 1 is closed")
        } catch let error as GitError {
            guard case .networkUnavailable = error else { return XCTFail("got \(error)") }
        }

        XCTAssertEqual(canaries(), [], "nothing from the parent environment may run")
        XCTAssertFalse(FileManager.default.fileExists(atPath: trace.path), "GIT_TRACE must not be inherited")
    }

    // MARK: - SEC-T10-02

    /// A hostile PATH puts its own `ssh` first. The child's PATH is fixed, so the system ssh runs instead.
    func testSECT10_02_ParentPATHCannotChooseSSH() async throws {
        let bin = executables.directory.appendingPathComponent("evil-bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let fakeSSH = try executables.canaryProgram(named: "ssh", canary: canary)
        try FileManager.default.copyItem(at: fakeSSH, to: bin.appendingPathComponent("ssh"))
        try await target.git(["remote", "add", "origin", "ssh://127.0.0.1:1/x.git"])
        let repository = Repository(
            rootURL: target.root, commonGitDirectoryURL: target.root.appendingPathComponent(".git"), isBare: false)
        let fetch = FetchCommand.fetch(remote: RemoteName("origin")!)

        // Control: with that PATH in the child, git runs the fake ssh, so the canary is reachable.
        var leaky = GitEnvironment.environment(parent: [:], allowsTransport: true)
        leaky["PATH"] = bin.path + ":" + GitEnvironment.path
        _ = try await ProcessRunner().run(
            ProcessRequest(
                executable: target.environment.executable,
                arguments: target.environment.arguments(for: fetch.subcommandArguments()),
                environment: leaky, currentDirectory: target.root, limits: .query))
        XCTAssertEqual(canaries(), ["ssh"], "control: the fake ssh must be reachable, or this test proves nothing")
        try FileManager.default.removeItem(at: canary.appendingPathComponent("ssh"))

        let client = GitClient(
            environment: target.environment,
            parentEnvironment: [
                "HOME": FileManager.default.temporaryDirectory.path, "PATH": bin.path + ":/usr/bin:/bin",
            ])
        do {
            _ = try await client.fetch(fetch, in: repository, safety: inspected)
            XCTFail("port 1 is closed")
        } catch let error as GitError {
            guard case .networkUnavailable = error else {
                return XCTFail("the system ssh should fail to connect: \(error)")
            }
        }
        XCTAssertEqual(canaries(), [], "the parent's PATH must not reach git")
    }
}
