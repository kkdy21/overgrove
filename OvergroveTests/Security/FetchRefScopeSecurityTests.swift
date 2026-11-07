import Foundation
import XCTest

@testable import Overgrove

/// SEC-T13-04 (#209, security-review.md T13): repository configuration cannot make the app's fetch write outside
/// `refs/remotes/<remote>/*`.
///
/// Found in the security review of #206: a repository-local `remote.origin.fetch=+refs/heads/*:refs/heads/*` with a
/// detached HEAD made fetch delete local branches and force-move `main`, and `fetch.pruneTags=true` deleted a local
/// tag. The test plants those settings (plus `remote.<n>.pruneTags` and `tagOpt=--tags`), runs the app's fetch, and
/// then runs the same fetch without the pinning as a control, which must change the refs.
final class FetchRefScopeSecurityTests: XCTestCase {
    private var remote: URL!
    private var source: GitTestRepository!
    private var local: GitTestRepository!
    private var bundle: URL!

    override func setUp() async throws {
        source = try await GitTestRepository.make()
        try source.write("a.txt", "remote\n")
        try await source.git(["add", "a.txt"])
        try await source.git(["commit", "-q", "-m", "remote"])
        try await source.git(["tag", "r1"])
        remote = source.root.deletingLastPathComponent().appendingPathComponent("remote-\(UUID().uuidString).git")
        try await source.git(["init", "-q", "--bare", remote.path])
        try await source.git(["push", "-q", remote.path, "HEAD:refs/heads/main", "refs/tags/r1"])

        // A local repository with its own history: a commit on main, local-only branches, a local tag.
        local = try await GitTestRepository.make()
        try local.write("local.txt", "local\n")
        try await local.git(["add", "local.txt"])
        try await local.git(["commit", "-q", "-m", "local work"])
        try await local.git(["branch", "local-only-1"])
        try await local.git(["branch", "local-only-2"])
        try await local.git(["tag", "local-tag"])
        try await local.git(["checkout", "-q", "--detach"])  // git refuses to fetch into a checked-out branch
        try await local.git(["remote", "add", "origin", remote.path])

        // The hostile settings.
        try await local.git(["config", "--replace-all", "remote.origin.fetch", "+refs/heads/*:refs/heads/*"])
        try await local.git(["config", "fetch.pruneTags", "true"])
        try await local.git(["config", "remote.origin.pruneTags", "true"])
        try await local.git(["config", "remote.origin.tagOpt", "--tags"])
        // A bundle URI makes fetch download from another location and write refs/bundles/* (security review of #210).
        bundle = remote.deletingLastPathComponent().appendingPathComponent("evil-\(UUID().uuidString).bundle")
        // A branch, not HEAD: fetch unbundles refs/heads/* into refs/bundles/heads/*.
        try await source.git(["bundle", "create", bundle.path, "main"])
        try await local.git(["config", "fetch.bundleURI", bundle.absoluteURL.absoluteString])
    }

    override func tearDown() {
        local?.remove()
        source?.remove()
        if let remote { try? FileManager.default.removeItem(at: remote) }
        if let bundle { try? FileManager.default.removeItem(at: bundle) }
    }

    /// `refname objectname` for every ref outside `refs/remotes/`, plus HEAD.
    private func localRefs() async throws -> [String] {
        let refs = try await local.git(["for-each-ref", "--format=%(refname) %(objectname)"])
        let head = try await local.git(["rev-parse", "HEAD"])
        return String(decoding: refs.stdout, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { !$0.hasPrefix("refs/remotes/") }
            + ["HEAD " + String(decoding: head.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)]
    }

    func testSECT13_04_RepositoryConfigCannotWidenWhatFetchWrites() async throws {
        let before = try await localRefs()
        let client = GitClient(environment: local.environment)

        // The real flow: inspect, then fetch with the resulting context.
        let listing = try await client.run(.configList, in: local.root, safety: .preInspection)
        let inspection = RepoConfigInspector.inspect(try ConfigParser.parse(listing.stdout))
        XCTAssertEqual(
            Set(inspection.report.findings.filter { $0.threat == "T13" }.map(\.entry.key)),
            [
                "remote.origin.fetch", "fetch.prunetags", "remote.origin.prunetags", "remote.origin.tagopt",
                "fetch.bundleuri",
            ],
            "the settings are reported"
        )
        let safety = try XCTUnwrap(inspection.safetyContext)
        let repository = Repository(
            rootURL: local.root, commonGitDirectoryURL: local.root.appendingPathComponent(".git"), isBare: false)
        _ = try await client.fetch(.fetch(remote: RemoteName("origin")!), in: repository, safety: safety)

        let after = try await localRefs()
        XCTAssertEqual(after, before, "local branches, tags, bundles, and HEAD are untouched")
        let tracking = try await local.git(["for-each-ref", "--format=%(refname)", "refs/remotes/origin"])
        XCTAssertTrue(
            String(decoding: tracking.stdout, as: UTF8.self).contains("refs/remotes/origin/main"),
            "fetch still updates the remote-tracking branch")

        // Control: the subcommand as it was before #209, with the same common arguments and environment.
        let unpinned = [
            "fetch", "--prune", "--no-recurse-submodules", "--upload-pack=git-upload-pack", "--end-of-options",
            "origin",
        ]
        _ = try await ProcessRunner().run(
            ProcessRequest(
                executable: local.environment.executable,
                arguments: local.environment.arguments(for: unpinned, fetchAuthentication: safety.fetchAuthentication),
                environment: GitEnvironment.environment(parent: [:], allowsTransport: true),
                currentDirectory: local.root, limits: .fetch))
        let control = try await localRefs()
        XCTAssertFalse(control.contains { $0.hasPrefix("refs/heads/local-only-1 ") }, "control: branch deleted")
        XCTAssertFalse(control.contains { $0.hasPrefix("refs/tags/local-tag ") }, "control: tag pruned")
        XCTAssertNotEqual(
            control.first { $0.hasPrefix("refs/heads/main ") }, before.first { $0.hasPrefix("refs/heads/main ") },
            "control: main force-moved")
        XCTAssertTrue(control.contains { $0.hasPrefix("refs/bundles/") }, "control: the bundle URI wrote refs/bundles")
    }
}
