import Foundation
import XCTest

@testable import Overgrove

/// T11 credential exposure and TLS downgrade on the app's real path (security-review.md §2 T11, #93).
///
/// Elsewhere: SEC-T11-01 `CredentialMaskerTests`, SEC-T11-02 `FetchFailureGuidanceTests`/`FetchFailureTests`,
/// SEC-T11-03 unit `RepoConfigInspectorTests`, SEC-T11-05 `GHClientTests`.
final class SECT11CredentialTests: XCTestCase {
    // MARK: - SEC-T11-03

    /// A repository that turns TLS verification off, generically and per URL, gets it back on for fetch. Checked with
    /// git's own URL matching on the exact arguments `GitClient.fetch` uses.
    func testSECT11_03_LocalSSLVerifyFalseIsTrueForFetch() async throws {
        let repository = try await GitTestRepository.make()
        defer { repository.remove() }
        try await repository.git(["config", "http.sslVerify", "false"])
        try await repository.git(["config", "http.https://example.com/.sslVerify", "0"])
        let client = GitClient(environment: repository.environment)
        let listing = try await client.run(.configList, in: repository.root, safety: .preInspection)
        let safety = try XCTUnwrap(RepoConfigInspector.inspect(try ConfigParser.parse(listing.stdout)).safetyContext)

        func effectiveSSLVerify(fetchAuthentication: [String]) async throws -> String {
            let arguments = repository.environment.arguments(
                for: ["config", "--type=bool", "--get-urlmatch", "http.sslverify", "https://example.com/o/r.git"],
                neutralization: safety.neutralization,
                fetchAuthentication: fetchAuthentication
            )
            let result = try await ProcessRunner().run(
                ProcessRequest(
                    executable: repository.environment.executable, arguments: arguments,
                    environment: GitEnvironment.environment(parent: [:]), currentDirectory: repository.root,
                    limits: .query))
            return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let restored = try await effectiveSSLVerify(fetchAuthentication: safety.fetchAuthentication)
        XCTAssertEqual(restored, "true", "fetch arguments: \(safety.fetchAuthentication)")
        let unrestored = try await effectiveSSLVerify(fetchAuthentication: [])
        XCTAssertEqual(unrestored, "false", "control: the repository really turns verification off")
    }

    // MARK: - SEC-T11-04

    /// The fixture's `mirror` remote carries a user name and password in its URL (fixtures.md §3). What the UI shows
    /// (S-05 remote list, status bar, fetch guidance) is masked; the raw URL stays inside the inspection. The screens
    /// themselves do not exist yet, so this checks the model they will render.
    func testSECT11_04_RemoteURLShownWithoutCredentials() async throws {
        let fixture = try await makeFixture()
        let environment = try await GitEnvironment.discoverForTesting()
        let client = GitClient(environment: environment, parentEnvironment: fixture.environment)
        let listing = try await client.run(.configList, in: fixture.repository, safety: .preInspection)
        let inspection = RepoConfigInspector.inspect(try ConfigParser.parse(listing.stdout))

        let mirror = try XCTUnwrap(inspection.remotes.first { $0.name.value == "mirror" })
        let rawUserInfo = try XCTUnwrap(
            URLComponents(string: mirror.url).flatMap { components in
                components.password.map { "\(components.user ?? ""):\($0)" }
            },
            "the fixture's mirror URL must contain credentials, or this test proves nothing"
        )
        XCTAssertFalse(mirror.displayURL.contains(rawUserInfo), mirror.displayURL)
        XCTAssertTrue(mirror.displayURL.hasPrefix("https://***@example.invalid/"), mirror.displayURL)
        for remote in inspection.remotes {
            XCTAssertNil(URLComponents(string: remote.displayURL)?.password, remote.displayURL)
        }
        let endpoint = FetchFailureGuidance.Endpoint(remoteURL: mirror.url)
        XCTAssertEqual(endpoint?.host, "example.invalid", "guidance names the host only")
    }
}
