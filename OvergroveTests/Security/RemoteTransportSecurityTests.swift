import Foundation
import XCTest

@testable import Overgrove

/// SEC-T5-08…15: remote helpers chosen by repository configuration (#161, security-review.md T5).
///
/// A canary `git-remote-evilhelper` stands in for a helper the user installed (`git-remote-hg`, `-gcrypt`,
/// `-codecommit`, …). Each case first runs the app's fetch **without** `GIT_ALLOW_PROTOCOL` to prove the helper is
/// reachable and runs, then with the app's environment to prove it does not.
final class RemoteTransportSecurityTests: XCTestCase {
    private var executables: TestExecutables!
    private var repository: GitTestRepository!
    private var canary: URL!
    private var helperDirectory: URL!

    private let helper = "evilhelper"
    private var origin: RemoteName { RemoteName("origin")! }

    override func setUp() async throws {
        executables = try TestExecutables()
        repository = try await GitTestRepository.make()
        canary = executables.directory.appendingPathComponent("canary", isDirectory: true)
        helperDirectory = try executables.canaryRemoteHelper(named: helper, canary: canary)
    }

    override func tearDown() {
        repository?.remove()
        executables?.remove()
    }

    // MARK: - Helpers

    /// The app's fetch (`GitEnvironment` arguments and environment), with the canary helper on PATH as if the user
    /// had installed it next to Homebrew's tools.
    private func fetch(allowList: Bool, extraArguments: [String] = []) async throws -> ProcessResult {
        var environment = GitEnvironment.environment(parent: ProcessInfo.processInfo.environment, allowsTransport: true)
        environment["PATH"] = helperDirectory.path + ":" + GitEnvironment.path
        if !allowList { environment["GIT_ALLOW_PROTOCOL"] = nil }
        let arguments = repository.environment.arguments(
            for: FetchCommand.fetch(remote: origin).subcommandArguments(),
            neutralization: extraArguments
        )
        return try await ProcessRunner().run(
            ProcessRequest(
                executable: repository.environment.executable,
                arguments: arguments,
                environment: environment,
                currentDirectory: repository.root,
                limits: .fetch
            )
        )
    }

    private var helperRan: Bool {
        FileManager.default.fileExists(atPath: canary.appendingPathComponent("\(helper)-ran").path)
    }

    private func resetCanary() throws {
        try? FileManager.default.removeItem(at: canary)
        try FileManager.default.createDirectory(at: canary, withIntermediateDirectories: true)
    }

    private func classify(_ result: ProcessResult) -> GitError? {
        GitError.classify(
            exitCode: result.termination.exitCode,
            signal: result.termination.signal,
            timedOut: result.timedOut,
            outputTruncated: false,
            timeoutSeconds: 60,
            stderr: result.stderr
        )
    }

    /// Control run without the allow list (helper runs), then the app's environment (blocked, nothing runs).
    private func assertHelperRunsOnlyWithoutAllowList(
        extraArguments: [String] = [],
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        _ = try await fetch(allowList: false, extraArguments: extraArguments)
        XCTAssertTrue(
            helperRan, "control: the canary helper must be reachable, or this test proves nothing", file: file,
            line: line)

        try resetCanary()
        let result = try await fetch(allowList: true, extraArguments: extraArguments)
        XCTAssertFalse(helperRan, "GIT_ALLOW_PROTOCOL must stop the helper", file: file, line: line)
        XCTAssertEqual(
            classify(result),
            .transportNotAllowed(transport: helper, detail: MaskedText(masking: result.stderr)),
            file: file,
            line: line
        )
    }

    // MARK: - Blocked (issue #161 table rows 1–5)

    func testSECT5_08_HelperURLDoesNotRun() async throws {
        try await repository.git(["remote", "add", "origin", "\(helper)::payload"])
        try await assertHelperRunsOnlyWithoutAllowList()
    }

    func testSECT5_09_RepositoryCannotAllowItsOwnHelper() async throws {
        try await repository.git(["remote", "add", "origin", "\(helper)::payload"])
        try await repository.git(["config", "protocol.\(helper).allow", "always"])
        try await assertHelperRunsOnlyWithoutAllowList()
    }

    func testSECT5_10_InsteadOfCannotSwapInAHelper() async throws {
        try await repository.git(["remote", "add", "origin", "https://github.com/example/repo.git"])
        try await repository.git(["config", "url.\(helper)::x.insteadOf", "https://github.com/"])
        try await assertHelperRunsOnlyWithoutAllowList()
    }

    func testSECT5_11_RemoteVCSDoesNotRun() async throws {
        try await repository.git(["remote", "add", "origin", "https://127.0.0.1:1/example.git"])
        try await repository.git(["config", "remote.origin.vcs", helper])
        try await assertHelperRunsOnlyWithoutAllowList()
    }

    func testSECT5_12_CommandLineProtocolAllowNeverIsNotEnough() async throws {
        // A name-specific local key beats a generic command-line key, so only the environment variable works.
        try await repository.git(["remote", "add", "origin", "\(helper)::payload"])
        try await repository.git(["config", "protocol.\(helper).allow", "always"])
        try await assertHelperRunsOnlyWithoutAllowList(extraArguments: ["-c", "protocol.allow=never"])
    }

    func testSECT5_15_UnknownSchemeURLDoesNotRun() async throws {
        // `<scheme>://` with a scheme git does not handle itself also runs `git-remote-<scheme>`.
        try await repository.git(["remote", "add", "origin", "\(helper)://payload"])
        try await assertHelperRunsOnlyWithoutAllowList()
    }

    // MARK: - Still allowed (rows 6 and 8)

    func testSECT5_13_LocalPathRemoteStillFetches() async throws {
        let source = try await GitTestRepository.make()
        defer { source.remove() }
        try await source.git(["commit", "-q", "--allow-empty", "-m", "fixture"])
        try await repository.git(["remote", "add", "origin", source.root.path])

        let result = try await fetch(allowList: true)
        XCTAssertNil(classify(result), String(decoding: result.stderr, as: UTF8.self))
        let refs = try await repository.git(["for-each-ref", "--format=%(refname)", "refs/remotes/origin"])
        // git 2.48+ also creates refs/remotes/origin/HEAD on fetch, so check for the branch only.
        let names = String(decoding: refs.stdout, as: UTF8.self).split(separator: "\n")
        XCTAssertTrue(names.contains("refs/remotes/origin/main"), "\(names)")
    }

    func testSECT5_14_HTTPSIsNotRefusedAsATransport() async throws {
        // Port 1 refuses the connection, so this needs no network: the failure must come from curl, not the policy.
        try await repository.git(["remote", "add", "origin", "https://127.0.0.1:1/example.git"])
        let result = try await fetch(allowList: true)
        let stderr = String(decoding: result.stderr, as: UTF8.self)
        XCTAssertFalse(stderr.contains("not allowed"), stderr)
        XCTAssertTrue(stderr.contains("127.0.0.1"), stderr)
        XCTAssertFalse(helperRan)
    }

    // MARK: - Through the real client

    func testGitClientFetchReportsTheBlockedTransport() async throws {
        try await repository.git(["remote", "add", "origin", "\(helper)::payload"])
        let client = GitClient(environment: repository.environment)
        // Past the remote form check (#350, SEC-T5-20), so the refusal comes from GIT_ALLOW_PROTOCOL.
        let safety = RepoSafetyContext(
            inspectedNeutralization: [], fetchAuthentication: [], trustedSSHCommand: nil, fetchableRemotes: ["origin"])
        do {
            let target = Repository(
                rootURL: repository.root, commonGitDirectoryURL: repository.root.appendingPathComponent(".git"),
                isBare: false)
            _ = try await client.fetch(.fetch(remote: origin), in: target, safety: safety)
            XCTFail("fetch must fail")
        } catch let error as GitError {
            // Without the allow list git would say "unable to find remote helper" (the helper is not on the fixed
            // PATH); the refusal proves GitClient passes GIT_ALLOW_PROTOCOL.
            guard case .transportNotAllowed(helper, _) = error else { return XCTFail("got \(error)") }
            XCTAssertTrue(error.message.contains("'\(helper)'"))
        }
    }
}
