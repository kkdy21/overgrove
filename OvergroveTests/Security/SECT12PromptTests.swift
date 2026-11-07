import Foundation
import XCTest

@testable import Overgrove

/// T12 credential prompts on the app's real path (security-review.md §2 T12, #93): a fetch that needs credentials
/// fails fast instead of waiting for input, and a repository's own `core.askPass` never runs.
///
/// The remote is a loopback HTTP server that answers every request with 401 (`LocalHTTPAuthServer`), so git really
/// reaches the point where it looks for credentials. No network.
///
/// On the app path, trusted credential helpers stay active (Apple's `osxkeychain` from the Xcode gitconfig), so
/// "no helper" means "no stored credential": the server's random port matches no keychain entry. A machine whose
/// system or global config sets an interactive helper could show UI here.
final class SECT12PromptTests: XCTestCase {
    private var executables: TestExecutables!
    private var server: LocalHTTPAuthServer!
    private var repository: GitTestRepository!
    private var canary: URL!

    /// Far below the 120 s fetch timeout: a prompt that waited would hit the timeout instead.
    private let fast: Duration = .seconds(15)
    /// Shorter than the app's 120 s, so a regression fails in seconds instead of minutes (security review of #204).
    private var fetchLimits: ProcessLimits {
        var limits = ProcessLimits.fetch
        limits.timeout = .seconds(20)
        return limits
    }

    override func setUp() async throws {
        executables = try TestExecutables()
        canary = executables.directory.appendingPathComponent("canary", isDirectory: true)
        server = try await LocalHTTPAuthServer.start()
        repository = try await GitTestRepository.make()
    }

    override func tearDown() {
        server?.stop()
        repository?.remove()
        executables?.remove()
    }

    private var target: Repository {
        Repository(
            rootURL: repository.root, commonGitDirectoryURL: repository.root.appendingPathComponent(".git"),
            isBare: false)
    }

    private func canaries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: canary.path)) ?? []).sorted()
    }

    /// Inspects the repository's configuration and fetches `origin` the way the app does; returns the error.
    private func appFetch() async throws -> (GitError, Duration) {
        let client = GitClient(
            environment: repository.environment,
            parentEnvironment: [
                "HOME": executables.directory.path, "TMPDIR": FileManager.default.temporaryDirectory.path,
            ],
            fetchLimits: fetchLimits
        )
        let listing = try await client.run(.configList, in: repository.root, safety: .preInspection)
        let safety = try XCTUnwrap(RepoConfigInspector.inspect(try ConfigParser.parse(listing.stdout)).safetyContext)
        let started = ContinuousClock.now
        do {
            _ = try await client.fetch(.fetch(remote: RemoteName("origin")!), in: target, safety: safety)
        } catch let error as GitError {
            return (error, ContinuousClock.now - started)
        }
        XCTFail("a fetch from a server that always answers 401 cannot succeed")
        throw CancellationError()
    }

    // MARK: - SEC-T12-01

    func testSECT12_01_RepositoryAskPassNeverRuns() async throws {
        let askPass = try executables.canaryProgram(named: "askpass", canary: canary, stdout: "not-a-password")
        try await repository.git(["remote", "add", "origin", server.url(userInfo: "alice")])
        try await repository.git(["config", "core.askPass", askPass.path])

        // Control: plain git with prompts disabled still runs the repository's askPass (security-review.md T12).
        _ = try await ProcessRunner().run(
            ProcessRequest(
                executable: repository.environment.executable,
                arguments: ["-c", "credential.helper=", "fetch", "origin"],
                environment: [
                    "HOME": executables.directory.path, "PATH": GitEnvironment.path, "GIT_TERMINAL_PROMPT": "0",
                ],
                currentDirectory: repository.root, limits: .query))
        XCTAssertEqual(canaries(), ["askpass"], "control: the askPass must be reachable, or this test proves nothing")
        try FileManager.default.removeItem(at: canary.appendingPathComponent("askpass"))

        let (error, elapsed) = try await appFetch()
        guard case .authenticationFailed = error else { return XCTFail("got \(error)") }
        XCTAssertEqual(canaries(), [], "the repository's core.askPass must not run")
        XCTAssertLessThan(elapsed, fast)
        XCTAssertGreaterThan(server.requestCount, 0, "git reached the server and asked for credentials")
    }

    // MARK: - SEC-T12-02

    func testSECT12_02_MissingCredentialsFailFastAsAuthentication() async throws {
        for url in [server.url(), server.url(userInfo: "alice")] {
            _ = try await repository.git(["remote", "remove", "origin"], allowFailure: true)
            try await repository.git(["remote", "add", "origin", url])
            let requestsBefore = server.requestCount
            let (error, elapsed) = try await appFetch()
            XCTAssertGreaterThan(server.requestCount, requestsBefore, "\(url): git reached the server")
            guard case .authenticationFailed = error else { return XCTFail("\(url): got \(error)") }
            XCTAssertLessThan(elapsed, fast, url)
            let guidance = try XCTUnwrap(
                FetchFailureGuidance(
                    error: error, remote: RemoteName("origin")!,
                    report: RepoSecurityReport(findings: [], blockingReason: nil)))
            XCTAssertEqual(guidance.reason, .credentialsRejected, url)
        }
    }
}
