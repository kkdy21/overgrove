import Darwin
import Foundation
import XCTest

@testable import Overgrove

/// Repository settings that newer git reads, on the app's real path (#356, found by the #353 release-note scan).
///
/// Each test first shows the setting taking effect with plain git (the control), then that the app's command does not
/// let it.
final class NewerGitSettingsSecurityTests: XCTestCase {
    private var repository: GitTestRepository!
    private var scratch: URL!

    override func setUp() async throws {
        repository = try await GitTestRepository.make()
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("overgrove-356-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try await repository.git(["commit", "-q", "--allow-empty", "-m", "one"])
    }

    override func tearDown() {
        repository?.remove()
        try? FileManager.default.removeItem(at: scratch)
    }

    private var target: Repository {
        Repository(
            rootURL: repository.root, commonGitDirectoryURL: repository.root.appendingPathComponent(".git"),
            isBare: false)
    }

    private var client: GitClient {
        GitClient(
            environment: repository.environment,
            parentEnvironment: ["HOME": scratch.path, "TMPDIR": FileManager.default.temporaryDirectory.path])
    }

    /// Appends raw lines to the repository's config file, so git never has to run on a half-configured repository.
    private func appendConfig(_ text: String) throws {
        let file = repository.root.appendingPathComponent(".git/config")
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// Plain git with only a HOME, a PATH, and no prompts: the control.
    @discardableResult
    private func plainGit(_ arguments: [String], timeout: Duration = .seconds(15)) async throws -> ProcessResult {
        var limits = ProcessLimits.query
        limits.timeout = timeout
        return try await ProcessRunner().run(
            ProcessRequest(
                executable: repository.environment.executable, arguments: arguments,
                environment: [
                    "HOME": scratch.path, "PATH": GitEnvironment.path, "GIT_TERMINAL_PROMPT": "0",
                    "GIT_ALLOW_PROTOCOL": GitEnvironment.allowedProtocols,
                ],
                currentDirectory: repository.root, limits: limits))
    }

    /// The configuration inspection the app runs first, or `nil` when it fails (git refused the repository).
    private func inspect() async -> RepoConfigInspection? {
        guard let listing = try? await client.run(.configList, in: repository.root, safety: .preInspection),
            let parsed = try? ConfigParser.parse(listing.stdout)
        else { return nil }
        return RepoConfigInspector.inspect(parsed)
    }

    // MARK: - SEC-T13-06

    /// `extensions.refStorage` with a location (git 2.54) makes fetch write refs and reflogs outside the repository.
    /// The app reports it and does not fetch; older git refuses such a repository by itself.
    func testSECT13_06_RefStorageOutsideTheRepositoryIsNotFetched() async throws {
        // Older git either does not know a location here or ignores the whole git directory; the classification is
        // covered by unit tests (`RepoConfigInspectorTests`).
        try XCTSkipIf(
            repository.environment.version < GitVersion(major: 2, minor: 54, patch: 0),
            "a ref store location needs git 2.54+ (found \(repository.environment.version))")
        let upstream = try await GitTestRepository.make()
        defer { upstream.remove() }
        try await upstream.git(["commit", "-q", "--allow-empty", "-m", "upstream"])
        try await repository.git(["remote", "add", "origin", upstream.root.path])
        let outside = scratch.appendingPathComponent("refs-elsewhere", isDirectory: true)
        try appendConfig(
            "[core]\n\trepositoryformatversion = 1\n[extensions]\n\trefStorage = files://\(outside.path)\n")
        func outsideFiles() -> [String] {
            (FileManager.default.enumerator(atPath: outside.path)?.allObjects as? [String]) ?? []
        }

        try await plainGit(["fetch", "origin"])
        XCTAssertFalse(outsideFiles().isEmpty, "control: plain git writes refs outside the repository")
        try FileManager.default.removeItem(at: outside)

        let inspection = try XCTUnwrap(await inspect())
        XCTAssertTrue(inspection.report.findings.contains { $0.entry.key == "extensions.refstorage" })
        XCTAssertNotNil(inspection.fetchBlockingReason)
        let safety = try XCTUnwrap(inspection.safetyContext, "queries go on")
        do {
            _ = try await client.fetch(.fetch(remote: RemoteName("origin")!), in: target, safety: safety)
            XCTFail("the app must not fetch")
        } catch let error as GitError {
            guard case .configInspectionFailed = error else { return XCTFail("got \(error)") }
        }
        XCTAssertEqual(outsideFiles(), [], "nothing is written outside the repository")
    }

    // MARK: - SEC-T6-05

    /// A remote URL with a password: git would send it and, after a successful fetch, ask the trusted helper to store
    /// it under a host the repository chose. The app refuses the remote before git starts, on every supported git
    /// (`transfer.credentialsInUrl=die` covers 2.37+, the inspection covers older git and rewrites).
    func testSECT6_05_RemoteWithAPasswordIsRefusedBeforeGitStarts() async throws {
        let server = try await LocalHTTPAuthServer.start()
        defer { server.stop() }
        for (url, rewrite) in [
            (server.url(userInfo: "alice:secret"), nil),
            ("https://example.invalid/r.git", "http://alice:secret@127.0.0.1:\(server.port)/"),
        ] {
            _ = try await repository.git(["remote", "remove", "origin"], allowFailure: true)
            try await repository.git(["remote", "add", "origin", url])
            if let rewrite {
                try await repository.git(["config", "url.\(rewrite).insteadOf", "https://example.invalid/"])
            }

            let before = server.requestCount
            try await plainGit(["-c", "credential.helper=", "fetch", "origin"])
            XCTAssertGreaterThan(server.requestCount, before, "\(url) control: plain git uses the URL")
            // The pinned argument alone stops git 2.37+ before it connects (older git ignores it).
            if repository.environment.version >= GitVersion(major: 2, minor: 37, patch: 0) {
                let pinned = server.requestCount
                try await plainGit([
                    "-c", "credential.helper=", "-c", "transfer.credentialsInUrl=die", "fetch", "origin",
                ])
                XCTAssertEqual(server.requestCount, pinned, "\(url): transfer.credentialsInUrl=die refuses the URL")
            }

            let inspected = await inspect()
            let inspection = try XCTUnwrap(inspected)
            let safety = try XCTUnwrap(inspection.safetyContext)
            let contacted = server.requestCount
            do {
                _ = try await client.fetch(.fetch(remote: RemoteName("origin")!), in: target, safety: safety)
                XCTFail("\(url): the app must not fetch")
            } catch let error as GitError {
                guard case .configInspectionFailed(let reason) = error else { return XCTFail("\(url): got \(error)") }
                XCTAssertTrue(reason.contains("password"), reason)
            }
            XCTAssertEqual(server.requestCount, contacted, "\(url): refused before git starts")
            if let rewrite {
                try await repository.git(["config", "--unset", "url.\(rewrite).insteadOf"])
            }
        }
    }

    // MARK: - SEC-T15-18

    /// A repository's `mailmap.file` naming a FIFO stalls `git log` until the timeout. The app's queries do not read
    /// a mailmap at all.
    func testSECT15_18_MailmapFIFODoesNotStallQueries() async throws {
        let fifo = scratch.appendingPathComponent("mailmap")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        try await repository.git(["config", "mailmap.file", fifo.path])

        let control = try await plainGit(["log", "-1", "--format=%an"], timeout: .seconds(3))
        XCTAssertTrue(control.timedOut, "control: plain git waits on the FIFO")

        let inspected = await inspect()
        let inspection = try XCTUnwrap(inspected)
        let safety = try XCTUnwrap(inspection.safetyContext)
        let started = ContinuousClock.now
        _ = try await client.run(.graphPage(skip: 0, limit: 10), in: repository.root, safety: safety)
        _ = try await client.run(.fileHistory(path: GitPath("x"), limit: 10), in: repository.root, safety: safety)
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "the queries do not open the FIFO")
        XCTAssertTrue(inspection.report.findings.contains { $0.entry.key == "mailmap.file" })
    }
}
