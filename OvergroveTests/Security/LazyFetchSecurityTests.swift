import Foundation
import XCTest

@testable import Overgrove

/// SEC-T5-16, SEC-T6-04 (#212, security-review.md T5/T6): in a partial clone, a read-only query that needs a missing
/// object makes git lazy-fetch it from the promisor remote. Without protection that runs the repository's own
/// `remote.<n>.uploadpack`, or its credential helper over https, just by looking at a diff.
///
/// The repository here is already partial (`clone --filter=blob:none`), as one shipped to the user could be. Each test
/// runs a control first: the same query with the pre-#212 environment runs the canary.
final class LazyFetchSecurityTests: XCTestCase {
    private var executables: TestExecutables!
    private var source: GitTestRepository!
    private var partial: GitTestRepository!
    private var bare: URL!
    private var canary: URL!
    private var latest: CommitNode!

    private let safety = RepoSafetyContext(inspectedNeutralization: [], fetchAuthentication: [], trustedSSHCommand: nil)

    override func setUp() async throws {
        executables = try TestExecutables()
        canary = executables.directory.appendingPathComponent("canary", isDirectory: true)
        source = try await GitTestRepository.make()
        try source.write("a.txt", "one\n")
        try await source.git(["add", "a.txt"])
        try await source.git(["commit", "-q", "-m", "one"])
        try await source.git(["mv", "a.txt", "b.txt"])
        try source.write("b.txt", "two\n")
        try await source.git(["add", "b.txt"])
        try await source.git(["commit", "-q", "-m", "two"])

        bare = executables.directory.appendingPathComponent("remote.git")
        try await source.git(["clone", "-q", "--bare", source.root.path, bare.path])
        try await source.git(["-C", bare.path, "config", "uploadpack.allowFilter", "true"])
        let clone = executables.directory.appendingPathComponent("partial", isDirectory: true)
        try await source.git(["clone", "-q", "--filter=blob:none", "--no-checkout", "file://" + bare.path, clone.path])
        partial = GitTestRepository(root: clone, environment: source.environment)

        let graph = try await GitClient(environment: partial.environment)
            .run(.graphPage(skip: 0, limit: 10), in: partial.root, safety: safety)
        latest = try XCTUnwrap(try LogParser.parseGraph(graph.stdout).commits.first)
    }

    override func tearDown() {
        source?.remove()
        executables?.remove()
    }

    private func canaries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: canary.path)) ?? []).sorted()
    }

    /// Queries that read file contents, so they need blobs the partial clone does not have.
    private var blobReadingQueries: [ReadOnlyGitCommand] {
        [
            .commitPatch(latest.oid, parent: latest.parents.first, path: GitPath("b.txt")),
            .commitFiles(latest.oid, firstParent: latest.parents.first),
            .fileHistory(path: GitPath("b.txt"), limit: 10),
        ]
    }

    /// The pre-#212 query environment: the fetch allow list and no GIT_NO_LAZY_FETCH.
    private func unprotectedQuery(_ command: ReadOnlyGitCommand) async throws {
        var environment = GitEnvironment.environment(parent: [:], allowsTransport: true)
        environment["GIT_NO_LAZY_FETCH"] = nil
        _ = try await ProcessRunner().run(
            ProcessRequest(
                executable: partial.environment.executable,
                arguments: partial.environment.arguments(for: try command.subcommandArguments()),
                environment: environment, currentDirectory: partial.root, limits: .query))
    }

    // MARK: - SEC-T5-16

    func testSECT5_16_QueriesNeverRunTheRepositoryUploadPack() async throws {
        let uploadPack = try executables.canaryProgram(named: "uploadpack", canary: canary)
        try await partial.git(["config", "remote.origin.uploadpack", uploadPack.path])

        // Control: without the protection, reading a diff runs the repository's uploadpack.
        try await unprotectedQuery(blobReadingQueries[0])
        XCTAssertEqual(canaries(), ["uploadpack"], "control: the lazy fetch must be reachable, or this proves nothing")
        try FileManager.default.removeItem(at: canary.appendingPathComponent("uploadpack"))

        let client = GitClient(environment: partial.environment)
        for command in blobReadingQueries {
            do {
                _ = try await client.run(command, in: partial.root, safety: safety)
            } catch let error as GitError {
                // The missing blob cannot be read: an error that says so is the expected, safe outcome.
                guard case .partialCloneObjectMissing = error else { return XCTFail("\(command): \(error)") }
            }
            XCTAssertEqual(canaries(), [], "\(command) must not lazy-fetch")
        }
    }

    /// git 2.36–2.43 ignore GIT_NO_LAZY_FETCH. The empty transport list alone must already block the lazy fetch.
    func testSECT5_16_EmptyTransportListAloneBlocksLazyFetch() async throws {
        let uploadPack = try executables.canaryProgram(named: "uploadpack", canary: canary)
        try await partial.git(["config", "remote.origin.uploadpack", uploadPack.path])
        var environment = GitEnvironment.environment(parent: [:], allowsTransport: false)
        environment["GIT_NO_LAZY_FETCH"] = nil
        let result = try await ProcessRunner().run(
            ProcessRequest(
                executable: partial.environment.executable,
                arguments: partial.environment.arguments(for: try blobReadingQueries[0].subcommandArguments()),
                environment: environment, currentDirectory: partial.root, limits: .query))
        XCTAssertEqual(canaries(), [], "the transport is refused before uploadpack runs")
        XCTAssertTrue(String(decoding: result.stderr, as: UTF8.self).contains("transport 'file' not allowed"))
        let error = GitError.classify(
            exitCode: result.termination.exitCode, signal: nil, timedOut: false, outputTruncated: false,
            timeoutSeconds: 15, stderr: result.stderr)
        guard case .partialCloneObjectMissing = error else { return XCTFail("got \(String(describing: error))") }
    }

    // MARK: - SEC-T6-04

    func testSECT6_04_LazyFetchOverHTTPSRunsNoCredentialHelper() async throws {
        let server = try await LocalHTTPAuthServer.start()
        defer { server.stop() }
        let helper = try executables.canaryProgram(named: "credential-helper", canary: canary)
        try await partial.git(["remote", "set-url", "origin", server.url()])
        try await partial.git(["config", "credential.helper", "!" + helper.path])

        // Control: without the protection, the lazy fetch reaches the server, gets 401, and asks the helper.
        try await unprotectedQuery(blobReadingQueries[0])
        XCTAssertTrue(
            canaries().contains("credential-helper"), "control: \(canaries()), requests: \(server.requestCount)")
        try FileManager.default.removeItem(at: canary.appendingPathComponent("credential-helper"))
        let requestsBefore = server.requestCount

        for command in blobReadingQueries {
            _ = try? await GitClient(environment: partial.environment).run(command, in: partial.root, safety: safety)
        }
        XCTAssertEqual(canaries(), [], "no credential helper may run for a query")
        XCTAssertEqual(server.requestCount, requestsBefore, "a query must not contact the remote at all")
    }

    // MARK: - Fetch (security review of #213)

    /// During fetch, a lazy fetch for a missing delta base would run the repository's uploadpack, and only git 2.44+
    /// can turn it off. On older git the app refuses to fetch a partial clone at all.
    func testOldGitRefusesToFetchAPartialClone() async throws {
        let uploadPack = try executables.canaryProgram(named: "uploadpack", canary: canary)
        try await partial.git(["config", "remote.origin.uploadpack", uploadPack.path])
        let listing = try await GitClient(environment: partial.environment)
            .run(.configList, in: partial.root, safety: .preInspection)
        let inspection = RepoConfigInspector.inspect(try ConfigParser.parse(listing.stdout))
        XCTAssertTrue(inspection.isPartialClone)
        let inspected = try XCTUnwrap(inspection.safetyContext)
        XCTAssertTrue(inspected.isPartialClone)
        let repository = Repository(
            rootURL: partial.root, commonGitDirectoryURL: partial.root.appendingPathComponent(".git"), isBare: false)

        let oldGit = GitEnvironment(
            executable: partial.environment.executable, version: GitVersion(major: 2, minor: 43, patch: 9))
        do {
            _ = try await GitClient(environment: oldGit).fetch(
                .fetch(remote: RemoteName("origin")!), in: repository, safety: inspected)
            XCTFail("git 2.43 cannot turn off lazy fetching, so fetch must be refused")
        } catch let error as GitError {
            guard case .configInspectionFailed(let reason) = error else { return XCTFail("got \(error)") }
            XCTAssertTrue(reason.contains("partial clone"), reason)
        }
        XCTAssertEqual(canaries(), [])

        // With a git that honors GIT_NO_LAZY_FETCH, fetch runs; its own upload-pack is pinned.
        XCTAssertGreaterThanOrEqual(partial.environment.version, GitEnvironment.lazyFetchControlVersion)
        _ = try await GitClient(environment: partial.environment).fetch(
            .fetch(remote: RemoteName("origin")!), in: repository, safety: inspected)
        XCTAssertEqual(canaries(), [], "the repository's uploadpack does not run")
    }

    // MARK: - Unaffected

    func testQueriesThatNeedNoMissingObjectStillWork() async throws {
        let client = GitClient(environment: partial.environment)
        let graph = try await client.run(.graphPage(skip: 0, limit: 10), in: partial.root, safety: safety)
        XCTAssertEqual(try LogParser.parseGraph(graph.stdout).commits.map(\.subject), ["two", "one"])
        let meta = try await client.run(.commitMeta(latest.oid), in: partial.root, safety: safety)
        XCTAssertEqual(try LogParser.parseCommitMeta(meta.stdout).message, "two\n")
    }
}
