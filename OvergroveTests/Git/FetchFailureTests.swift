import Foundation
import XCTest

@testable import Overgrove

/// Fetch failures end to end (#78): real `git fetch` through `GitClient`, classified into `GitError` and turned into
/// `FetchFailureGuidance`. No network: local paths, a closed local port, and a fake trusted `core.sshCommand` that
/// fails the way OpenSSH does (git's own `fatal:` lines around it are real).
final class FetchFailureTests: XCTestCase {
    private var executables: TestExecutables!
    private var local: GitTestRepository!
    private let secret = "s3" + "cr3t"

    override func setUp() async throws {
        executables = try TestExecutables()
        local = try await GitTestRepository.make()
    }

    override func tearDown() {
        local?.remove()
        executables?.remove()
    }

    private var origin: RemoteName { RemoteName("origin")! }

    private var repository: Repository {
        Repository(
            rootURL: local.root,
            commonGitDirectoryURL: local.root.appendingPathComponent(".git", isDirectory: true),
            isBare: false
        )
    }

    /// Fetches `origin` and returns the error with its guidance; fails the test if the fetch succeeds.
    private func failedFetch(
        url: String,
        sshCommand: URL? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> (GitError, FetchFailureGuidance) {
        try await local.git(["remote", "add", "origin", url])
        let safety = RepoSafetyContext(
            inspectedNeutralization: [], fetchAuthentication: [], trustedSSHCommand: sshCommand?.path,
            fetchableRemotes: ["origin"])
        do {
            _ = try await GitClient(environment: local.environment.fetchingLocalRemotesForTesting).fetch(
                .fetch(remote: origin), in: repository, safety: safety)
        } catch let error as GitError {
            // The local repository's own configuration is clean: no findings.
            let report = RepoSecurityReport(findings: [], blockingReason: nil)
            let endpoint = FetchFailureGuidance.Endpoint(remoteURL: url)
            let guidance = try XCTUnwrap(
                FetchFailureGuidance(
                    error: error, remote: origin, endpoint: endpoint, report: report, hookExecutables: []), file: file,
                line: line)
            return (error, guidance)
        }
        XCTFail("the fetch was expected to fail", file: file, line: line)
        throw CancellationError()
    }

    func testMissingLocalRepositoryIsRemoteNotFound() async throws {
        let (error, guidance) = try await failedFetch(url: local.root.appendingPathComponent("missing.git").path)
        guard case .remoteNotFound = error else { return XCTFail("got \(error)") }
        XCTAssertEqual(guidance.reason, .remoteNotFound)
        XCTAssertEqual(guidance.commands, ["git --no-pager remote -v"])
    }

    func testSECT11_02_ClosedPortWithCredentialsIsNetworkAndMasked() async throws {
        let (error, guidance) = try await failedFetch(url: "https://alice:\(secret)@127.0.0.1:1/r.git")
        guard case .networkUnavailable = error else { return XCTFail("got \(error)") }
        XCTAssertEqual(guidance.category, .network)
        XCTAssertEqual(guidance.summary, "Could not reach 127.0.0.1")
        let everything =
            [guidance.summary, guidance.guidance, guidance.detail?.text ?? "", guidance.detailTail ?? ""]
            + guidance.commands + [error.message, error.detail?.text ?? ""]
        for text in everything {
            XCTAssertFalse(text.contains(secret), text)
        }
    }

    func testSSHFailuresAreToldApart() async throws {
        let banner = """
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
            Host key verification failed.\r

            """
        let cases: [(String, FetchFailureGuidance.Reason)] = [
            ("Host key verification failed.\r\n", .hostKeyNotTrusted),
            (banner, .hostKeyChanged),
            ("git@example.com: Permission denied (publickey).\r\n", .sshKeyRejected),
            (
                "ssh: Could not resolve hostname example.com: nodename nor servname provided, or not known\r\n",
                .hostUnreachable
            ),
        ]
        for (stderr, reason) in cases {
            local.remove()
            local = try await GitTestRepository.make()
            let ssh = try executables.failingSSH(stderr: stderr)
            let (error, guidance) = try await failedFetch(url: "git@example.com:o/r.git", sshCommand: ssh)
            XCTAssertEqual(guidance.reason, reason, "\(error)")
            XCTAssertTrue(guidance.detail?.text.contains("fatal: Could not read from remote repository.") ?? false)
        }
    }

    func testServerTextOverSSHIsTheOneSpoofableChannel() async throws {
        // Over ssh the server's stderr reaches us without a `remote:` prefix, so a hostile server can pick a
        // category. It can only choose among Overgrove's own texts: nothing it writes is shown outside Details.
        // An unclassified failure must not echo the first stderr line either.
        for stderr in ["Host key verification failed.\nOVERGROVE-SERVER-TEXT\n", "OVERGROVE-SERVER-TEXT\n"] {
            local.remove()
            local = try await GitTestRepository.make()
            let ssh = try executables.failingSSH(stderr: stderr)
            let (_, guidance) = try await failedFetch(url: "git@example.com:o/r.git", sshCommand: ssh)
            for text in [guidance.summary, guidance.guidance] + guidance.commands {
                XCTAssertFalse(text.contains("OVERGROVE-SERVER-TEXT"), text)
            }
            XCTAssertTrue(guidance.detail?.text.contains("OVERGROVE-SERVER-TEXT") ?? false, "it stays in Details")
        }
    }
}
