import Foundation
import XCTest

@testable import Overgrove

/// SEC-T13-07 (#195): a repository-local `transfer.bundleURI` is reported, and fetch does not follow bundle URIs the
/// server advertises. git reads the key only for clone (measured on 2.40.4, 2.45.1, Apple Git 2.54.0, Homebrew
/// 2.54.0); fetch also turns it off (`-c transfer.bundleURI=false`) in case a later git reads it.
final class TransferBundleURITests: XCTestCase {
    private var source: GitTestRepository!
    private var local: GitTestRepository!
    private var bundle: URL!

    override func setUp() async throws {
        source = try await GitTestRepository.make()
        try await source.git(["commit", "-q", "--allow-empty", "-m", "one"])
        bundle = source.root.deletingLastPathComponent().appendingPathComponent("adv-\(UUID().uuidString).bundle")
        try await source.git(["bundle", "create", "-q", bundle.path, "main"])
        // The server advertises a bundle list (protocol v2 `bundle-uri`).
        for (key, value) in [
            ("uploadpack.advertiseBundleURIs", "true"), ("bundle.version", "1"), ("bundle.mode", "all"),
            ("bundle.one.uri", bundle.absoluteURL.absoluteString),
        ] {
            try await source.git(["config", key, value])
        }
        local = try await GitTestRepository.make()
        try await local.git(["remote", "add", "origin", source.root.path])
        try await local.git(["config", "transfer.bundleURI", "true"])
    }

    override func tearDown() {
        local?.remove()
        source?.remove()
        if let bundle { try? FileManager.default.removeItem(at: bundle) }
    }

    private func bundleRefs(in root: URL) async throws -> String {
        let result = try await ProcessRunner().run(
            ProcessRequest(
                executable: local.environment.executable,
                arguments: local.environment.arguments(for: ["for-each-ref", "--format=%(refname)", "refs/bundles"]),
                environment: GitEnvironment.environment(parent: [:]), currentDirectory: root, limits: .query))
        return String(decoding: result.stdout, as: UTF8.self)
    }

    func testSECT13_07_TransferBundleURIIsReportedAndNotFollowedByFetch() async throws {
        let client = GitClient(environment: local.environment.fetchingLocalRemotesForTesting)
        let listing = try await client.run(.configList, in: local.root, safety: .preInspection)
        let inspection = RepoConfigInspector.inspect(try ConfigParser.parse(listing.stdout))
        let finding = try XCTUnwrap(inspection.report.findings.first { $0.entry.key == "transfer.bundleuri" })
        XCTAssertEqual(finding.threat, "T13")
        XCTAssertEqual(finding.handling, .neutralized)

        let repository = Repository(
            rootURL: local.root, commonGitDirectoryURL: local.root.appendingPathComponent(".git"), isBare: false)
        _ = try await client.fetch(
            .fetch(remote: RemoteName("origin")!), in: repository, safety: try XCTUnwrap(inspection.safetyContext))
        let afterApp = try await bundleRefs(in: local.root)
        // Today's git does not read the key for fetch, so this holds without the override too; the override is in
        // the argument snapshot (GitClientTests) as defense in depth.
        XCTAssertEqual(afterApp, "", "the app's fetch wrote no refs/bundles")

        // Measurement: plain fetch, without the override, does not follow the advertised bundles either. A new commit
        // first, so the fetch has objects to get.
        try await source.git(["commit", "-q", "--allow-empty", "-m", "two"])
        let tip = String(decoding: try await source.git(["rev-parse", "main"]).stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let plain = ["fetch", "--no-tags", "origin", "+refs/heads/*:refs/remotes/origin/*"]
        let plainRun = try await ProcessRunner().run(
            ProcessRequest(
                executable: local.environment.executable, arguments: local.environment.arguments(for: plain),
                environment: GitEnvironment.environment(parent: [:], allowsTransport: true),
                currentDirectory: local.root, limits: .fetch))
        XCTAssertEqual(
            plainRun.termination, .exited(code: 0), String(decoding: plainRun.stderr, as: UTF8.self))
        let fetched = String(
            decoding: try await local.git(["rev-parse", "refs/remotes/origin/main"]).stdout, as: UTF8.self
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(fetched, tip, "the plain fetch got the new commit")
        let afterPlain = try await bundleRefs(in: local.root)
        XCTAssertEqual(afterPlain, "", "git's fetch does not read transfer.bundleURI")

        // Control: clone does follow them, so the server's bundle list is live.
        let clone = local.root.deletingLastPathComponent().appendingPathComponent("clone-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: clone) }
        let cloneRun = try await ProcessRunner().run(
            ProcessRequest(
                executable: local.environment.executable,
                arguments: local.environment.arguments(
                    for: ["clone", "-q", "--no-local", source.root.path, clone.path],
                    neutralization: ["-c", "transfer.bundleURI=true"]),
                environment: GitEnvironment.environment(parent: [:], allowsTransport: true),
                currentDirectory: local.root.deletingLastPathComponent(), limits: .fetch))
        guard local.environment.version >= GitVersion(major: 2, minor: 40, patch: 0) else {
            throw XCTSkip("the clone control needs git 2.40+ (found \(local.environment.version))")
        }
        XCTAssertEqual(cloneRun.termination, .exited(code: 0), String(decoding: cloneRun.stderr, as: UTF8.self))
        let cloned = try await bundleRefs(in: clone)
        XCTAssertTrue(cloned.contains("refs/bundles/"), "control: clone followed the advertised bundle (\(cloned))")
    }
}
