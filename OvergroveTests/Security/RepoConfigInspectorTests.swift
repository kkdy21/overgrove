import Foundation
import XCTest

@testable import Overgrove

/// ADR-0009, security-review.md §3.3.
final class RepoConfigInspectorTests: XCTestCase {
    private func entry(
        _ scope: ConfigEntry.Scope,
        _ key: String,
        _ value: String? = "x"
    ) -> ConfigEntry {
        let first = key.firstIndex(of: ".")!
        let last = key.lastIndex(of: ".")!
        return ConfigEntry(
            scope: scope,
            section: String(key[..<first]),
            subsection: first == last ? nil : String(key[key.index(after: first)..<last]),
            variable: String(key[key.index(after: last)...]),
            value: value
        )
    }

    private func inspect(_ entries: [ConfigEntry], partial: Bool = false) -> RepoConfigInspection {
        RepoConfigInspector.inspect(ConfigParser.Listing(entries: entries, isPartial: partial))
    }

    func testLocalFilterDriversAreNeutralizedOnce() {
        let result = inspect([
            entry(.local, "filter.fixture.clean", "evil"), entry(.local, "filter.fixture.smudge", "evil"),
            entry(.global, "filter.lfs.clean", "git-lfs clean -- %f"),
        ])
        XCTAssertEqual(
            result.neutralization,
            [
                "-c", "filter.fixture.clean=", "-c", "filter.fixture.smudge=", "-c", "filter.fixture.process=",
                "-c", "filter.fixture.required=false",
            ],
            "trusted (global) drivers such as git-lfs stay untouched"
        )
        XCTAssertFalse(result.report.isBlocked)
    }

    func testSECT4_04_UnsafeDriverNameBlocks() {
        let result = inspect([entry(.local, "filter.Weird Name.clean", "evil")])
        XCTAssertTrue(result.report.isBlocked)
    }

    func testTruncatedListingBlocks() {
        XCTAssertTrue(inspect([], partial: true).report.isBlocked)
        XCTAssertNil(inspect([], partial: true).safetyContext, "a blocked report yields no safety context")
        XCTAssertNotNil(inspect([]).safetyContext)
    }

    func testCredentialHelpersAreResetAndTrustedOnesReinsertedInOrder() {
        let result = inspect([
            entry(.unknown, "credential.helper", "osxkeychain"),
            entry(.global, "credential.https://github.com.helper", ""),
            entry(.global, "credential.https://github.com.helper", "!/opt/homebrew/bin/gh auth git-credential"),
            entry(.local, "credential.helper", "!evil"),
            entry(.local, "credential.https://example.com.helper", "!evil2"),
        ])
        XCTAssertEqual(
            result.fetchAuthentication,
            [
                "-c", "credential.helper=",
                "-c", "credential.helper=osxkeychain",
                "-c", "credential.https://github.com.helper=",
                "-c", "credential.https://github.com.helper=!/opt/homebrew/bin/gh auth git-credential",
            ]
        )
    }

    func testNoResetWithoutUntrustedHelpers() {
        XCTAssertEqual(inspect([entry(.global, "credential.helper", "osxkeychain")]).fetchAuthentication, [])
    }

    func testSECT11_03_LocalSSLVerifyIsAlwaysForcedTrue() {
        // git reads 0k, 00, 0x0, -0, … as false, so every local sslVerify is overridden (review of #150).
        let result = inspect([
            entry(.local, "http.sslverify", "0k"), entry(.local, "http.https://example.com.sslverify", "true"),
            entry(.global, "http.https://intranet.example.sslverify", "false"),
        ])
        XCTAssertEqual(
            result.fetchAuthentication,
            ["-c", "http.sslverify=true", "-c", "http.https://example.com.sslverify=true"],
            "a user's own global choice is respected"
        )
    }

    func testLocalProxyIsReplacedWithTheTrustedValueOrNothing() {
        let result = inspect([
            entry(.global, "http.proxy", "http://corp-proxy:3128"), entry(.local, "http.proxy", "http://evil:8080"),
            entry(.local, "http.https://github.com.proxy", "http://evil:8080"),
        ])
        XCTAssertEqual(
            result.fetchAuthentication,
            ["-c", "http.proxy=http://corp-proxy:3128", "-c", "http.https://github.com.proxy="]
        )
    }

    func testLocalCertificateFilesBlockFetchOnly() {
        let result = inspect([entry(.local, "http.sslcainfo", "/tmp/evil-ca.pem")])
        XCTAssertFalse(result.report.isBlocked)
        XCTAssertNotNil(result.fetchBlockingReason)
        XCTAssertNotNil(result.safetyContext?.fetchBlockingReason)
    }

    func testKeysContainingEqualsBlock() {
        XCTAssertTrue(inspect([entry(.local, "http.https://example.com/a.b=c.sslverify", "false")]).report.isBlocked)
        XCTAssertTrue(inspect([entry(.local, "credential.https://x=y.helper", "!evil")]).report.isBlocked)
    }

    func testIncludeIfOnBranchIsNotCacheable() async {
        let inspection = inspect([entry(.local, "includeif.onbranch:evil.path", "evil.cfg")])
        XCTAssertFalse(inspection.isCacheable)
        let cache = RepoConfigInspectionCache()
        await cache.store(inspection, for: "repo", fingerprint: RepoConfigInspectionCache.Fingerprint.make([]))
        let hit = await cache.inspection(for: "repo", fingerprint: RepoConfigInspectionCache.Fingerprint.make([]))
        XCTAssertNil(hit)
    }

    func testTrustedSSHCommandIgnoresLocalValues() {
        let result = inspect([
            entry(.global, "core.sshcommand", "ssh -i ~/.ssh/work"), entry(.local, "core.sshcommand", "evil"),
        ])
        XCTAssertEqual(result.trustedSSHCommand, "ssh -i ~/.ssh/work")
        XCTAssertNil(inspect([entry(.local, "core.sshcommand", "evil")]).trustedSSHCommand)
    }

    func testReportHandling() {
        let samples: [(ConfigEntry, RepoSecurityReport.Handling)] = [
            (entry(.local, "core.fsmonitor", "x"), .reported), (entry(.local, "core.hookspath", "x"), .reported),
            (entry(.local, "core.askpass", "x"), .reported), (entry(.local, "core.gitproxy", "x"), .neutralized),
            (entry(.local, "remote.origin.uploadpack", "x"), .neutralized),
            (entry(.local, "remote.evil.url", "ext::sh -c x"), .reported),
            (entry(.local, "url.ext::sh -c x.insteadof", "https://a/"), .reported),
            (entry(.local, "diff.fixture.textconv", "x"), .reported), (entry(.local, "gpg.program", "x"), .reported),
            (entry(.local, "log.showsignature", "true"), .reported), (entry(.local, "core.worktree", "/"), .warned),
            (entry(.local, "http.proxy", "http://p"), .neutralized), (entry(.local, "http.sslcainfo", "x"), .warned),
            (entry(.local, "maintenance.auto", "true"), .reported),
            (entry(.local, "core.attributesfile", "/tmp/fifo"), .warned),
            (entry(.local, "diff.orderfile", "x"), .warned),
        ]
        for (entry, handling) in samples {
            let findings = inspect([entry]).report.findings
            XCTAssertEqual(findings.map(\.handling), [handling], entry.key)
        }
        XCTAssertTrue(
            inspect([entry(.local, "core.pager", "less"), entry(.local, "user.name", "me")]).report.findings.isEmpty)
        XCTAssertTrue(
            inspect([entry(.global, "core.fsmonitor", "x")]).report.findings.isEmpty, "trusted scopes are not reported")
    }

    /// A repository can make fetch run any installed `git-remote-<helper>`; `GIT_ALLOW_PROTOCOL` blocks it, and the
    /// report tells the user why (#161, T5).
    func testRemoteHelpersChosenByTheRepositoryAreReported() {
        let helperURLs = [
            "evilhelper::payload", "codecommit::us-east-1://repo", "hg::https://example.com/r", "ext::sh -c x",
            "fd::3", "Git-Remote+x.y::z", "C::x", "1abc::x", "::x",
            // An unknown `<scheme>://` also runs `git-remote-<scheme>` (security review of #191).
            "evilhelper://x", "EvilHelper://x", "codecommit://repo", "s3+https://bucket/r",
        ]
        for url in helperURLs {
            let findings = inspect([entry(.local, "remote.origin.url", url)]).report.findings
            XCTAssertEqual(findings.map(\.handling), [.reported], url)
            XCTAssertEqual(findings.map(\.threat), ["T5"], url)
        }
        let vcs = inspect([entry(.worktree, "remote.origin.vcs", "evilhelper")]).report.findings
        XCTAssertEqual(vcs.map(\.handling), [.reported])
        XCTAssertEqual(vcs.map(\.threat), ["T5"])

        // git only treats `<scheme chars>::` at the very start as a helper (transport.c: is_urlschemechar), and
        // handles these schemes itself or with its own bundled helpers.
        let ordinaryURLs = [
            "https://github.com/o/r.git", "HTTPS://github.com/o/r.git", "http://example.com/r", "git://example.com/r",
            "ssh://git@example.com/a::b", "git+ssh://example.com/r", "ssh+git://example.com/r", "ftp://example.com/r",
            "ftps://example.com/r", "file:///tmp/r", "git@github.com:o/r.git", "example.com:a://b", "/srv/repos/a::b",
            "../relative::x", "-x::y", "a b::c", "+x://y",
        ]
        for url in ordinaryURLs {
            XCTAssertTrue(inspect([entry(.local, "remote.origin.url", url)]).report.findings.isEmpty, url)
        }
        XCTAssertTrue(
            inspect([entry(.global, "remote.origin.url", "codecommit::us-east-1://repo")]).report.findings.isEmpty,
            "trusted scopes are not reported"
        )
    }

    func testRemotesAreMaskedAndValidated() {
        let secret = "s3" + "cr3t"
        let result = inspect([
            entry(.local, "remote.origin.url", "https://u:\(secret)@github.com/o/r.git"),
            entry(.local, "remote.-evil.url", "https://x/y"),
        ])
        XCTAssertEqual(result.remotes.map(\.name.value), ["origin"])
        XCTAssertEqual(result.remotes.first?.displayURL, "https://***@github.com/o/r.git")
    }

    func testCacheInvalidatesWhenAFileChanges() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("overgrove-cfg-\(UUID().uuidString)")
        try "a".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let cache = RepoConfigInspectionCache()
        let inspection = inspect([])
        let before = RepoConfigInspectionCache.Fingerprint.make([file])
        await cache.store(inspection, for: "repo", fingerprint: before)
        let hit = await cache.inspection(for: "repo", fingerprint: RepoConfigInspectionCache.Fingerprint.make([file]))
        XCTAssertEqual(hit, inspection)
        try "changed".write(to: file, atomically: true, encoding: .utf8)
        let miss = await cache.inspection(for: "repo", fingerprint: RepoConfigInspectionCache.Fingerprint.make([file]))
        XCTAssertNil(miss)
    }
}

/// End to end against the malicious fixture (docs/testing/fixtures.md §8): SEC-T4-01/02/03.
final class RepoConfigInspectorFixtureTests: XCTestCase {
    func testSECT4_FilterPayloadRunsWithoutNeutralizationAndNotWithIt() async throws {
        let fixture = try await makeFixture(malicious: true)
        let environment = try await GitEnvironment.discover()
        let client = GitClient(environment: environment, parentEnvironment: fixture.environment)
        let worktree = fixture.repository

        // Inspect the repository's own configuration.
        let config = try await client.run(.configList, in: worktree, safety: .preInspection)
        let inspection = RepoConfigInspector.inspect(try ConfigParser.parse(config.stdout))
        XCTAssertFalse(inspection.report.isBlocked)
        XCTAssertTrue(inspection.neutralization.contains("filter.fixture.clean="))
        XCTAssertTrue(inspection.report.findings.contains { $0.threat == "T6" })

        // With the neutralization arguments, status runs no payload at all.
        let safety = try XCTUnwrap(inspection.safetyContext)
        _ = try await client.run(.status, in: worktree, safety: safety)
        XCTAssertEqual(fixture.canaries(), [], "no repository-configured program may run")

        // Control: the common arguments alone do not stop the clean filter (T4), proving the test is meaningful.
        let unneutralized = RepoSafetyContext(
            inspectedNeutralization: [], fetchAuthentication: [], trustedSSHCommand: nil)
        _ = try await client.run(.status, in: worktree, safety: unneutralized)
        XCTAssertTrue(fixture.canaries().contains("T4-filter-clean"), "canaries: \(fixture.canaries())")
    }
}
