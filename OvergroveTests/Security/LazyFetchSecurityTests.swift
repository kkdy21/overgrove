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

    /// Older git (e.g. 2.36) ignores GIT_NO_LAZY_FETCH. The empty transport list alone must already block the lazy
    /// fetch.
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

    /// During fetch, a lazy fetch for a missing delta base would run the repository's uploadpack, and only
    /// GIT_NO_LAZY_FETCH can turn it off. On older git the app refuses to fetch a partial clone at all (SEC-T5-18).
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

/// SEC-T5-18 (#317, security review of #213): during fetch, received objects that use a blob the partial clone lacks
/// as a delta base make git lazy-fetch that blob. The lazy fetch does not get the app's pinned `--upload-pack`, so it
/// runs the repository's own `remote.<n>.uploadpack`. Only a git whose `GIT_NO_LAZY_FETCH` covers this path stops it,
/// so the app fetches a partial clone only from `GitEnvironment.lazyFetchControlVersion` on.
///
/// The clone here keeps `remote.origin.promisor` but no filter, and the new blob on the remote is stored as a delta
/// against the blob the clone never received. git resolves it in `unpack-objects` for a small pack and in `index-pack`
/// once the repository's own `fetch.unpackLimit` is low; both paths are run. Run with `OVERGROVE_TEST_GIT` set to git
/// 2.36, 2.44.0, or 2.45.0 to exercise the refusal with a real git; with a newer git, the fetch runs and fails safely.
final class PartialCloneFetchSecurityTests: XCTestCase {
    private var executables: TestExecutables!
    private var source: GitTestRepository!
    private var bare: URL!
    private var canary: URL!

    override func setUp() async throws {
        executables = try TestExecutables()
        canary = executables.directory.appendingPathComponent("canary", isDirectory: true)
        source = try await GitTestRepository.make()
        // The first version is the larger one, so git stores the second as a delta against it.
        try source.write("a.txt", (1...3200).map(String.init).joined(separator: "\n") + "\n")
        try await source.git(["add", "a.txt"])
        try await source.git(["commit", "-q", "-m", "one"])
        bare = executables.directory.appendingPathComponent("remote.git")
        try await source.git(["init", "-q", "--bare", "-b", "main", bare.path])
        try await source.git(["-C", bare.path, "config", "uploadpack.allowFilter", "true"])
        try await source.git(["push", "-q", bare.path, "main"])
        // "two" goes to another branch, so every clone of `main` alone starts from "one" and fetch must bring "two".
        try source.write("a.txt", (1...3000).map(String.init).joined(separator: "\n") + "\n")
        try await source.git(["commit", "-q", "-am", "two"])
        try await source.git(["push", "-q", bare.path, "HEAD:refs/heads/next"])
        try await source.git(["-C", bare.path, "repack", "-q", "-a", "-d", "-f"])
    }

    override func tearDown() {
        source?.remove()
        executables?.remove()
    }

    /// A fresh partial clone of "one" (promisor, no filter, local uploadpack canary). On the remote, "two" (branch
    /// `next`) stores its blob as a delta against the blob the clone lacks. Every fetch attempt gets its own clone: a failed fetch can leave the
    /// commit and tree behind, and the next fetch would then finish without resolving the delta at all.
    private func freshPartialClone(
        _ name: String, unpackLimit: String?, filterOnly: Bool = false
    ) async throws -> PartialClone {
        let clone = executables.directory.appendingPathComponent(name, isDirectory: true)
        try await source.git([
            "clone", "-q", "--filter=blob:none", "--no-checkout", "--single-branch", "--branch", "main",
            "file://" + bare.path, clone.path,
        ])
        let repository = GitTestRepository(root: clone, environment: source.environment)
        if filterOnly {
            // No promisor key: a filter alone makes git treat the remote as a promisor (#317). A filter that sends
            // blobs lets the new blob arrive as a delta.
            try await repository.git(["config", "--unset", "remote.origin.promisor"])
            try await repository.git(["config", "--unset-all", "extensions.partialclone"], allowFailure: true)
            try await repository.git(["config", "remote.origin.partialclonefilter", "blob:limit=1m"])
        } else {
            try await repository.git(["config", "--unset", "remote.origin.partialclonefilter"])
        }
        if let unpackLimit { try await repository.git(["config", "fetch.unpackLimit", unpackLimit]) }
        let uploadPack = try executables.canaryProgram(named: "uploadpack", canary: canary)
        try await repository.git(["config", "remote.origin.uploadpack", uploadPack.path])

        let listing = try await GitClient(environment: repository.environment)
            .run(.configList, in: clone, safety: .preInspection)
        let safety = try XCTUnwrap(RepoConfigInspector.inspect(try ConfigParser.parse(listing.stdout)).safetyContext)
        XCTAssertTrue(safety.isPartialClone)
        return PartialClone(git: repository, safety: safety, before: try await trackingRefs(repository))
    }

    private struct PartialClone {
        let git: GitTestRepository
        let safety: RepoSafetyContext
        let before: String
        var repository: Repository {
            Repository(
                rootURL: git.root, commonGitDirectoryURL: git.root.appendingPathComponent(".git"), isBare: false)
        }
    }

    /// `refname objectname` of every remote-tracking ref: only `origin/main` until a fetch brings `next`.
    private func trackingRefs(_ repository: GitTestRepository) async throws -> String {
        let result = try await repository.git(["for-each-ref", "--format=%(refname) %(objectname)", "refs/remotes"])
        return String(decoding: result.stdout, as: UTF8.self)
    }

    private func canaries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: canary.path)) ?? []).sorted()
    }

    private func clearCanaries() throws {
        for name in canaries() { try FileManager.default.removeItem(at: canary.appendingPathComponent(name)) }
    }

    private let fetch = FetchCommand.fetch(remote: RemoteName("origin")!)

    /// The app's fetch arguments with the fetch environment minus GIT_NO_LAZY_FETCH, as git without the variable runs.
    private func fetchWithoutLazyFetchControl(_ clone: PartialClone) async throws -> ProcessResult {
        var environment = GitEnvironment.environment(parent: [:], allowsTransport: true)
        environment["GIT_NO_LAZY_FETCH"] = nil
        return try await ProcessRunner().run(
            ProcessRequest(
                executable: clone.git.environment.executable,
                arguments: clone.git.environment.arguments(
                    for: fetch.subcommandArguments(), neutralization: clone.safety.neutralization,
                    fetchOverrides: fetch.configurationOverrides()),
                environment: environment, currentDirectory: clone.git.root, limits: .fetch))
    }

    /// Control on one fresh clone, the app's fetch on another.
    private func assertFetchRunsNoUploadPack(
        unpackLimit: String?, path: String, filterOnly: Bool = false
    ) async throws {
        let control = try await freshPartialClone("control", unpackLimit: unpackLimit, filterOnly: filterOnly)
        let result = try await fetchWithoutLazyFetchControl(control)
        XCTAssertEqual(canaries(), ["uploadpack"], "control (\(path)): the fetch must lazy-fetch")
        XCTAssertNotEqual(result.termination, .exited(code: 0), "control (\(path)) cannot finish the fetch")
        let afterControl = try await trackingRefs(control.git)
        XCTAssertEqual(afterControl, control.before, "control (\(path)) leaves the repository as it was")
        try clearCanaries()

        let app = try await freshPartialClone("app", unpackLimit: unpackLimit, filterOnly: filterOnly)
        let version = app.git.environment.version
        do {
            _ = try await GitClient(environment: app.git.environment).fetch(
                fetch, in: app.repository, safety: app.safety)
            XCTFail("git \(version) (\(path)): fetch must be refused, or fail on the unresolved delta")
        } catch let error as GitError {
            if version < GitEnvironment.lazyFetchControlVersion {
                guard case .configInspectionFailed(let reason) = error else { return XCTFail("got \(error)") }
                XCTAssertTrue(reason.contains("partial clone"), reason)
            } else {
                // The fetch reached the delta and failed on it instead of lazy-fetching: the safe outcome.
                switch error {
                case .nonZeroExit, .partialCloneObjectMissing: break
                default: XCTFail("got \(error)")
                }
            }
        }
        XCTAssertEqual(canaries(), [], "git \(version) (\(path)): the repository's uploadpack does not run")
        let afterApp = try await trackingRefs(app.git)
        XCTAssertEqual(afterApp, app.before)
    }

    /// A small pack: git resolves the delta in `unpack-objects`.
    func testSECT5_18_FetchRunsNoRepositoryUploadPack_unpackObjects() async throws {
        try await assertFetchRunsNoUploadPack(unpackLimit: nil, path: "unpack-objects")
    }

    /// The repository's own `fetch.unpackLimit` sends every pack through `index-pack`, which looks up delta bases in
    /// another way.
    func testSECT5_18_FetchRunsNoRepositoryUploadPack_indexPack() async throws {
        try await assertFetchRunsNoUploadPack(unpackLimit: "1", path: "index-pack")
    }

    /// #317: a clone whose remote is a promisor only through its filter is a partial clone too.
    func testSECT5_18_FetchRunsNoRepositoryUploadPack_filterOnly() async throws {
        try await assertFetchRunsNoUploadPack(unpackLimit: nil, path: "filter only, unpack-objects", filterOnly: true)
        try clearCanaries()
        for name in ["control", "app"] {
            try FileManager.default.removeItem(at: executables.directory.appendingPathComponent(name))
        }
        try await assertFetchRunsNoUploadPack(unpackLimit: "1", path: "filter only, index-pack", filterOnly: true)
    }

    /// #317, defense in depth: a `.promisor` pack marks a partial clone even when no setting git reads names a promisor
    /// remote, so the gate does not depend only on following git's list of promisor settings.
    func testSECT5_18_PromisorPackAloneClosesTheGate() async throws {
        let plain = try await GitTestRepository.make()
        defer { plain.remove() }
        try plain.write("a.txt", "a\n")
        try await plain.git(["add", "a.txt"])
        try await plain.git(["commit", "-q", "-m", "one"])
        let repository = Repository(
            rootURL: plain.root, commonGitDirectoryURL: plain.root.appendingPathComponent(".git"), isBare: false)
        let listing = try await GitClient(environment: plain.environment)
            .run(.configList, in: plain.root, safety: .preInspection)
        let safety = try XCTUnwrap(RepoConfigInspector.inspect(try ConfigParser.parse(listing.stdout)).safetyContext)
        XCTAssertFalse(safety.isPartialClone, "no promisor setting")
        XCTAssertFalse(GitClient.hasPromisorPack(commonDirectory: repository.commonGitDirectoryURL))

        let pack = repository.commonGitDirectoryURL.appendingPathComponent("objects/pack", isDirectory: true)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try Data().write(to: pack.appendingPathComponent("pack-\(String(repeating: "0", count: 40)).promisor"))
        XCTAssertTrue(GitClient.hasPromisorPack(commonDirectory: repository.commonGitDirectoryURL))

        let old = GitEnvironment(
            executable: plain.environment.executable, version: GitVersion(major: 2, minor: 45, patch: 0))
        do {
            _ = try await GitClient(environment: old).fetch(fetch, in: repository, safety: safety)
            XCTFail("a promisor pack must close the gate on git 2.45.0")
        } catch let error as GitError {
            guard case .configInspectionFailed(let reason) = error else { return XCTFail("got \(error)") }
            XCTAssertTrue(reason.contains("partial clone"), reason)
        }
    }

    /// What cannot be listed without following a link, or past the scan limit, counts as a promisor pack (fail closed).
    func testPromisorPackScanFailsClosed() throws {
        let root = executables.directory.appendingPathComponent("scan", isDirectory: true)
        let elsewhere = executables.directory.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)

        XCTAssertFalse(
            GitClient.hasPromisorPack(commonDirectory: root), "no objects directory: nothing to fetch lazily")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("objects"), withDestinationURL: elsewhere)
        XCTAssertTrue(GitClient.hasPromisorPack(commonDirectory: root), "a linked objects directory is not followed")

        try FileManager.default.removeItem(at: root.appendingPathComponent("objects"))
        let objects = root.appendingPathComponent("objects", isDirectory: true)
        try FileManager.default.createDirectory(at: objects, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: objects.appendingPathComponent("pack"), withDestinationURL: elsewhere)
        XCTAssertTrue(GitClient.hasPromisorPack(commonDirectory: root), "a linked pack directory is not followed")
        try FileManager.default.removeItem(at: objects.appendingPathComponent("pack"))
        XCTAssertFalse(GitClient.hasPromisorPack(commonDirectory: root), "no pack directory: no pack")
        try Data().write(to: objects.appendingPathComponent("pack"))
        XCTAssertTrue(GitClient.hasPromisorPack(commonDirectory: root), "a pack that is not a directory")

        try FileManager.default.removeItem(at: objects.appendingPathComponent("pack"))
        let pack = objects.appendingPathComponent("pack", isDirectory: true)
        try FileManager.default.createDirectory(at: pack, withIntermediateDirectories: true)
        try Data().write(to: pack.appendingPathComponent("pack-a.pack"))
        try Data().write(to: pack.appendingPathComponent("pack-a.idx"))
        XCTAssertFalse(GitClient.hasPromisorPack(commonDirectory: root))
        XCTAssertTrue(GitClient.hasPromisorPack(commonDirectory: root, scanLimit: 1), "past the scan limit")
        try Data().write(to: pack.appendingPathComponent("pack-a.PROMISOR"))
        XCTAssertTrue(GitClient.hasPromisorPack(commonDirectory: root), "case-insensitive, as git finds it on APFS")
    }

    /// The May 2024 security releases made GIT_NO_LAZY_FETCH stop this lazy fetch: 2.45.1 and 2.44.1, with backports
    /// to 2.39.4, 2.40.2, 2.41.1, 2.42.2, and 2.43.4. 2.44.0 predates the variable, and 2.45.0 has it only for other
    /// lazy fetches. Comparing versions, the newest-line release 2.45.1 is the threshold; older fixed releases are
    /// refused too, on the safe side.
    func testSECT5_18_ControlVersionBoundary() async throws {
        let clone = try await freshPartialClone("boundary", unpackLimit: nil)
        let (safety, repository) = (clone.safety, clone.repository)
        XCTAssertEqual(GitEnvironment.lazyFetchControlVersion, GitVersion(major: 2, minor: 45, patch: 1))
        let refused = [
            GitVersion(major: 2, minor: 45, patch: 0), GitVersion(major: 2, minor: 44, patch: 1),
            GitVersion(major: 2, minor: 44, patch: 0), GitVersion(major: 2, minor: 43, patch: 4),
        ]
        for version in refused {
            let stand = GitEnvironment(executable: clone.git.environment.executable, version: version)
            do {
                _ = try await GitClient(environment: stand).fetch(fetch, in: repository, safety: safety)
                XCTFail("git \(version): fetch must be refused")
            } catch let error as GitError {
                guard case .configInspectionFailed(let reason) = error else { return XCTFail("got \(error)") }
                XCTAssertTrue(reason.contains("2.45.1"), reason)
            }
        }
        XCTAssertEqual(canaries(), [], "a refused fetch starts no git")

        // 2.45.1 passes the gate (it may still fail later, which is the safe outcome on a missing delta base).
        let allowed = GitEnvironment(
            executable: clone.git.environment.executable, version: GitVersion(major: 2, minor: 45, patch: 1))
        do {
            _ = try await GitClient(environment: allowed).fetch(fetch, in: repository, safety: safety)
        } catch GitError.configInspectionFailed(let reason) {
            XCTFail("git 2.45.1 must not be refused: \(reason)")
        } catch is GitError {}
        // Only a git that really is that new can show that no uploadpack ran through the open gate.
        if clone.git.environment.version >= GitEnvironment.lazyFetchControlVersion {
            XCTAssertEqual(canaries(), [])
        }
    }
}
