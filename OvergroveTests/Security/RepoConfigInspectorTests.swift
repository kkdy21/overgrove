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

    /// A repository's proxy is replaced by what the trusted scopes give for the same URL (#150, #355): the user's
    /// company proxy keeps working, and the repository's value is gone.
    func testLocalProxyIsReplacedWithTheTrustedEffectiveValue() {
        let result = inspect([
            entry(.global, "http.proxy", "http://corp-proxy:3128"), entry(.local, "http.proxy", "http://evil:8080"),
            entry(.local, "http.https://github.com.proxy", "http://evil:8080"),
        ])
        XCTAssertEqual(
            result.fetchAuthentication,
            ["-c", "http.proxy=http://corp-proxy:3128", "-c", "http.https://github.com.proxy=http://corp-proxy:3128"]
        )
        XCTAssertEqual(
            inspect([entry(.local, "http.https://github.com.proxy", "http://evil:8080")]).fetchAuthentication,
            ["-c", "http.https://github.com.proxy="], "no trusted proxy: none")
    }

    /// The most specific trusted URL key that matches wins (git's urlmatch order: host, then path, then user); a
    /// trusted key for another host or scheme does not apply.
    func testTheMostSpecificTrustedProxyForTheURLIsUsed() {
        let result = inspect([
            entry(.global, "http.proxy", "http://generic.invalid"),
            entry(.global, "http.https://*.corp.invalid.proxy", "http://wildcard.invalid"),
            entry(.global, "http.https://git.corp.invalid.proxy", "http://host.invalid"),
            entry(.global, "http.https://git.corp.invalid/team.proxy", "http://path.invalid"),
            entry(.global, "http.http://git.corp.invalid.proxy", "http://other-scheme.invalid"),
            entry(.local, "http.https://git.corp.invalid/team/repo.git.proxy", "http://evil.invalid"),
            entry(.local, "http.https://git.corp.invalid:443/other.proxy", "http://evil.invalid"),
            entry(.local, "http.https://ci.corp.invalid.proxy", "http://evil.invalid"),
            entry(.local, "http.https://elsewhere.invalid.proxy", "http://evil.invalid"),
        ])
        XCTAssertEqual(
            result.fetchAuthentication,
            [
                "-c", "http.https://git.corp.invalid/team/repo.git.proxy=http://path.invalid",
                "-c", "http.https://git.corp.invalid:443/other.proxy=http://host.invalid",
                "-c", "http.https://ci.corp.invalid.proxy=http://wildcard.invalid",
                "-c", "http.https://elsewhere.invalid.proxy=http://generic.invalid",
            ])
    }

    func testLocalCertificateFilesBlockFetchOnly() {
        let result = inspect([entry(.local, "http.sslcainfo", "/tmp/evil-ca.pem")])
        XCTAssertFalse(result.report.isBlocked)
        XCTAssertNotNil(result.fetchBlockingReason)
        XCTAssertNotNil(result.safetyContext?.fetchBlockingReason)
    }

    // MARK: - Settings from newer git (#356)

    /// The switches that turn off git's credential CVE fixes are forced on under their own key for fetch (the generic
    /// keys are also pinned by `FetchCommand`), since a URL-specific key would win over the generic one.
    func testSECT6_06_CredentialProtectionSwitchesAreForcedOn() {
        let result = inspect([
            entry(.local, "credential.protectprotocol", "false"),
            entry(.local, "credential.https://x.invalid.sanitizeprompt", "false"),
            entry(.global, "credential.https://y.invalid.protectprotocol", "false"),
        ])
        XCTAssertEqual(
            result.fetchAuthentication,
            ["-c", "credential.protectprotocol=true", "-c", "credential.https://x.invalid.sanitizeprompt=true"])
        XCTAssertEqual(result.report.findings.map(\.threat), ["T6", "T6"])
        XCTAssertTrue(
            FetchCommand.fetch(remote: RemoteName("origin")!).configurationOverrides().contains(
                "credential.protectProtocol=true"))
    }

    func testPasswordsInRemoteURLsAreFound() {
        XCTAssertTrue(RepoConfigInspector.hasPassword(Array("https://a:b@h/r".utf8)))
        XCTAssertTrue(RepoConfigInspector.hasPassword(Array("ssh://a:@h/r".utf8)))
        XCTAssertFalse(RepoConfigInspector.hasPassword(Array("https://alice@h/r".utf8)))
        XCTAssertFalse(
            RepoConfigInspector.hasPassword(Array("https://h/a:b@c".utf8)), "an @ in the path is not userinfo")
        XCTAssertFalse(
            RepoConfigInspector.hasPassword(Array("git@github.com:o/r.git".utf8)), "scp form has no password")
        XCTAssertFalse(RepoConfigInspector.hasPassword([]))

        let result = inspect([
            entry(.local, "remote.plain.url", "https://h.invalid/r"),
            entry(.local, "remote.direct.url", "https://u:p@h.invalid/r"),
            entry(.local, "remote.rewritten.url", "corp:r"),
            entry(.global, "url.https://u:p@corp.invalid/.insteadof", "corp:"),
        ])
        XCTAssertEqual(
            result.remotes.filter(\.hasPasswordInURL).map(\.name.value), ["direct", "rewritten"],
            "a rewrite that adds a password counts")
        XCTAssertEqual(result.safetyContext?.remotesWithPassword, ["direct", "rewritten"])
    }

    func testRefStorageWithALocationIsReportedAndBlocksFetch() {
        for plain in ["files", "reftable", "REFTABLE"] {
            let result = inspect([entry(.local, "extensions.refstorage", plain)])
            XCTAssertTrue(result.report.findings.isEmpty, plain)
            XCTAssertNil(result.fetchBlockingReason, plain)
        }
        let result = inspect([entry(.local, "extensions.refstorage", "files:///tmp/elsewhere")])
        XCTAssertEqual(result.report.findings.map(\.threat), ["T13"])
        XCTAssertNotNil(result.fetchBlockingReason)
        XCTAssertNotNil(result.safetyContext, "queries go on")
    }

    func testProxyTLSFilesAndPinnedAddressesBlockFetchOnly() {
        for key in [
            "http.proxysslcainfo", "http.https://x.invalid.proxysslcert", "http.proxysslkey",
            "http.curloptresolve", "http.https://x.invalid.curloptresolve",
        ] {
            let result = inspect([entry(.local, key, "/tmp/x")])
            XCTAssertEqual(result.report.findings.map(\.handling), [.warned], key)
            XCTAssertNotNil(result.fetchBlockingReason, key)
            XCTAssertNotNil(result.safetyContext, key)
        }
    }

    func testNewerExecutionAndFileSettingsAreReported() {
        let result = inspect([
            entry(.local, "gc.recentobjectshook", "touch x"), entry(.local, "mailmap.file", "/tmp/fifo"),
            entry(.local, "mailmap.blob", "HEAD:.mailmap"), entry(.local, "log.mailmap", "true"),
            entry(.local, "promisor.acceptfromserver", "all"),
        ])
        XCTAssertEqual(result.report.findings.map(\.threat), ["T14", "T15", "T15", "T15", "T5"])
        XCTAssertEqual(result.report.findings.first?.handling, .reported, "Terminal git would run it")
    }

    func testKeysContainingEqualsBlock() {
        XCTAssertTrue(inspect([entry(.local, "http.https://example.com/a.b=c.sslverify", "false")]).report.isBlocked)
        XCTAssertTrue(inspect([entry(.local, "credential.https://x=y.helper", "!evil")]).report.isBlocked)
        // `-c remote.a=b.proxy=` would set `remote.a` instead (#355).
        XCTAssertTrue(inspect([entry(.local, "remote.a=b.proxy", "http://evil.invalid")]).report.isBlocked)
        XCTAssertFalse(inspect([entry(.local, "remote.a=b.url", "https://x.invalid/r")]).report.isBlocked)
    }

    /// #355 review: invalid UTF-8 in a subsection is decoded as U+FFFD, so `-c <that key>=…` would not reach the key git
    /// reads. Parsed from bytes, as `config --list -z` gives them.
    func testKeysThatAreNotValidUTF8Block() throws {
        func listing(_ key: [UInt8]) throws -> RepoConfigInspection {
            let record = Array("local\0".utf8) + key + Array("\nhttp://evil.invalid\0".utf8)
            return RepoConfigInspector.inspect(try ConfigParser.parse(Data(record)))
        }
        for (prefix, variable) in [
            ("http.https://x.invalid/", ".proxy"), ("http.https://x.invalid/", ".sslverify"),
            ("credential.https://x.invalid/", ".helper"), ("remote.o", ".proxy"),
        ] {
            let key = Array(prefix.utf8) + [0xFF] + Array(variable.utf8)
            XCTAssertTrue(try listing(key).report.isBlocked, prefix + variable)
        }
        XCTAssertFalse(
            try listing(Array("remote.o".utf8) + [0xFF] + Array(".url".utf8)).report.isBlocked,
            "a key the app never overrides is only listed")
    }

    /// #355: `remote.<name>.proxy` wins over `http.proxy` for that remote, so a repository's value is reset the same
    /// way: to the trusted value for the same key, else to nothing.
    func testLocalRemoteProxyIsReplacedWithTheTrustedEffectiveValue() {
        let result = inspect([
            entry(.global, "remote.origin.proxy", "http://corp-proxy:3128"),
            entry(.global, "http.https://git.corp.invalid.proxy", "http://host.invalid"),
            entry(.local, "remote.origin.url", "https://github.invalid/o/r.git"),
            entry(.local, "remote.origin.proxy", "http://evil.invalid:8080"),
            entry(.local, "remote.fork.url", "https://git.corp.invalid/o/r.git"),
            entry(.local, "remote.fork.proxy", "http://evil.invalid:8080"),
            entry(.local, "remote.gone.proxy", "http://evil.invalid:8080"),
        ])
        XCTAssertEqual(
            result.fetchAuthentication,
            [
                // The trusted value of the same key first, then the trusted proxy for the remote's URL, else none.
                "-c", "remote.origin.proxy=http://corp-proxy:3128", "-c", "remote.fork.proxy=http://host.invalid",
                "-c", "remote.gone.proxy=",
            ])
        XCTAssertEqual(result.report.findings.map(\.threat), ["T11", "T11", "T11"])
        XCTAssertEqual(result.report.findings.map(\.handling), [.neutralized, .neutralized, .neutralized])
        XCTAssertTrue(result.neutralization.isEmpty, "queries open no connection")
    }

    /// #367: how fetch authenticates to the user's proxy is not the repository's choice. `proxyAuthMethod=basic` would
    /// send the proxy password in the clear where the proxy offers Digest, and `proxySSLCertPasswordProtected` makes git
    /// ask the trusted helper for a certificate password. Each key (generic, per URL, per remote) is reset under its own
    /// key to the trusted value, else to git's default.
    func testLocalProxyAuthSettingsAreReplacedWithTrustedValues() {
        let result = inspect([
            entry(.global, "http.proxyauthmethod", "negotiate"),
            entry(.global, "http.https://git.corp.invalid.proxyauthmethod", "ntlm"),
            entry(.local, "remote.origin.url", "https://git.corp.invalid/o/r.git"),
            entry(.local, "http.proxyauthmethod", "basic"),
            entry(.local, "http.https://elsewhere.invalid.proxyauthmethod", "basic"),
            entry(.local, "remote.origin.proxyauthmethod", "basic"),
            entry(.local, "remote.gone.proxyauthmethod", "basic"),
            entry(.local, "http.proxysslcertpasswordprotected", "true"),
            entry(.local, "http.https://x.invalid.proxysslcertpasswordprotected", "true"),
        ])
        XCTAssertEqual(
            result.fetchAuthentication,
            [
                "-c", "http.proxyauthmethod=negotiate",
                "-c", "http.https://elsewhere.invalid.proxyauthmethod=negotiate",
                "-c", "remote.origin.proxyauthmethod=ntlm",
                "-c", "remote.gone.proxyauthmethod=negotiate",
                "-c", "http.proxysslcertpasswordprotected=false",
                "-c", "http.https://x.invalid.proxysslcertpasswordprotected=false",
            ])
        XCTAssertEqual(Set(result.report.findings.map(\.threat)), ["T11"])
        XCTAssertEqual(Set(result.report.findings.map(\.handling)), [.neutralized])
        XCTAssertNil(result.fetchBlockingReason)
        XCTAssertTrue(result.neutralization.isEmpty, "queries open no connection")
    }

    /// #367: without trusted values, the authentication method falls back to git's own default (`anyauth`, written out
    /// so git prints no "unsupported method" warning).
    func testLocalProxyAuthMethodWithoutTrustedValueIsAnyauth() {
        XCTAssertEqual(
            inspect([
                entry(.local, "remote.o.proxyauthmethod", "basic"), entry(.local, "http.proxyauthmethod", "basic"),
            ])
            .fetchAuthentication,
            ["-c", "remote.o.proxyauthmethod=anyauth", "-c", "http.proxyauthmethod=anyauth"])
    }

    /// #367 review: `sslCertPasswordProtected` (the remote certificate's twin) makes git ask the trusted helper too.
    func testLocalSSLCertPasswordProtectedIsReplacedWithTrustedValue() {
        XCTAssertEqual(
            inspect([
                entry(.global, "http.sslcertpasswordprotected", "true"),
                entry(.local, "http.sslcertpasswordprotected", "false"),
                entry(.local, "http.https://x.invalid.sslcertpasswordprotected", "true"),
            ]).fetchAuthentication,
            [
                "-c", "http.sslcertpasswordprotected=true",
                "-c", "http.https://x.invalid.sslcertpasswordprotected=true",
            ])
        XCTAssertEqual(
            inspect([entry(.local, "http.sslcertpasswordprotected", "true")]).fetchAuthentication,
            ["-c", "http.sslcertpasswordprotected=false"])
        // A trusted key written without `=` is true for git; the override must not turn it into `-c key=` (false).
        XCTAssertEqual(
            inspect([
                entry(.global, "http.proxysslcertpasswordprotected", nil),
                entry(.local, "http.proxysslcertpasswordprotected", "false"),
            ]).fetchAuthentication,
            ["-c", "http.proxysslcertpasswordprotected=true"])
    }

    /// #367: Kerberos ticket forwarding is pinned off for fetch (`FetchCommand`), and a repository's URL-specific
    /// `http.<url>.delegation` (which would win over the pin) is reset to `none` under its own key. A user's own stays.
    func testLocalDelegationIsTurnedOffUnderItsOwnKey() {
        let result = inspect([
            entry(.local, "http.delegation", "always"),
            entry(.local, "http.https://x.invalid.delegation", "always"),
            entry(.global, "http.https://corp.invalid.delegation", "policy"),
        ])
        XCTAssertEqual(result.fetchAuthentication, ["-c", "http.https://x.invalid.delegation=none"])
        XCTAssertEqual(result.report.findings.map(\.threat), ["T11", "T11"])
        XCTAssertEqual(result.report.findings.map(\.handling), [.neutralized, .neutralized])
        XCTAssertNil(result.fetchBlockingReason)
    }

    /// #367: `-c remote.a=b.proxyauthmethod=` would set `remote.a` instead.
    func testRemoteProxyAuthMethodKeyContainingEqualsBlocks() {
        XCTAssertTrue(inspect([entry(.local, "remote.a=b.proxyauthmethod", "basic")]).report.isBlocked)
    }

    /// #355: a repository's cookie file would be read (and with `saveCookies`, written) by fetch. A URL-specific key
    /// wins over the generic `-c http.cookieFile=` that fetch pins, so each one is reset under its own key.
    func testLocalCookieSettingsAreTurnedOffUnderTheirOwnKeys() {
        let result = inspect([
            entry(.local, "http.cookiefile", "/tmp/cookies.txt"),
            entry(.local, "http.https://x.invalid.cookiefile", "/tmp/cookies.txt"),
            entry(.worktree, "http.https://x.invalid.savecookies", "true"),
            entry(.global, "http.https://y.invalid.cookiefile", "/tmp/trusted.txt"),
        ])
        XCTAssertEqual(
            result.fetchAuthentication,
            [
                "-c", "http.cookiefile=", "-c", "http.https://x.invalid.cookiefile=",
                "-c", "http.https://x.invalid.savecookies=false",
            ],
            "a user's own (global) setting is left alone")
        XCTAssertEqual(result.report.findings.map(\.threat), ["T11", "T11", "T11"])
        XCTAssertNil(result.fetchBlockingReason)
    }

    /// #355: git keeps canonically equivalent subsections apart (bytes), but Swift `String` equality would fold them,
    /// so one of two such keys could be left out of the reset. Compared as bytes here for the same reason.
    func testCanonicallyEquivalentURLKeysAreEachReset() {
        let composed = "https://caf\u{E9}.invalid"
        let decomposed = "https://cafe\u{301}.invalid"
        let result = inspect([
            entry(.local, "http.\(composed).sslverify", "false"),
            entry(.local, "http.\(decomposed).sslverify", "false"),
            entry(.local, "http.\(composed).proxy", "http://evil.invalid"),
            entry(.local, "http.\(decomposed).proxy", "http://evil.invalid"),
            entry(.global, "http.\(decomposed).proxy", "http://trusted.invalid"),
            entry(.local, "http.\(composed).cookiefile", "/tmp/c"),
            entry(.local, "http.\(decomposed).cookiefile", "/tmp/c"),
        ])
        let expected = [
            "-c", "http.\(composed).sslverify=true", "-c", "http.\(decomposed).sslverify=true",
            "-c", "http.\(composed).proxy=", "-c", "http.\(decomposed).proxy=http://trusted.invalid",
            "-c", "http.\(composed).cookiefile=", "-c", "http.\(decomposed).cookiefile=",
        ]
        XCTAssertEqual(result.fetchAuthentication.map { Array($0.utf8) }, expected.map { Array($0.utf8) })
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

    /// #209 (T13): settings that would widen what fetch writes are reported; the pinned fetch arguments override them.
    func testFetchScopeSettingsAreReported() {
        let neutralized = [
            entry(.local, "remote.origin.fetch", "+refs/heads/*:refs/heads/*"),
            entry(.local, "remote.origin.fetch", "+refs/*:refs/*"),
            entry(.local, "remote.origin.fetch", "refs/heads/main:refs/remotes/upstream/main"),
            entry(.local, "fetch.prunetags", "true"),
            entry(.local, "fetch.bundleuri", "file:///tmp/evil.bundle"),
            entry(.local, "remote.origin.prunetags", "true"),
            entry(.local, "remote.origin.tagopt", "--tags"),
        ]
        for sample in neutralized {
            let findings = inspect([sample]).report.findings
            XCTAssertEqual(findings.map(\.handling), [.neutralized], "\(sample.key)=\(sample.value ?? "")")
            XCTAssertEqual(findings.map(\.threat), ["T13"], sample.key)
        }
        let mirror = inspect([entry(.local, "remote.origin.mirror", "true")]).report.findings
        XCTAssertEqual(mirror.map(\.handling), [.reported])
        XCTAssertEqual(mirror.map(\.threat), ["T13"])

        // The default refspec, extra refspecs that stay inside the remote's namespace, and FETCH_HEAD-only refspecs.
        let ordinary = [
            "+refs/heads/*:refs/remotes/origin/*", "refs/heads/*:refs/remotes/origin/*",
            "+refs/pull/*/head:refs/remotes/origin/pr/*", "refs/heads/main", "^refs/heads/skip",
        ]
        for refspec in ordinary {
            XCTAssertTrue(inspect([entry(.local, "remote.origin.fetch", refspec)]).report.findings.isEmpty, refspec)
        }
        XCTAssertTrue(
            inspect([entry(.global, "remote.origin.fetch", "+refs/heads/*:refs/heads/*")]).report.findings.isEmpty,
            "trusted scopes are not reported")
    }

    /// #212 (T5): partial clone settings make reads lazy-fetch from a promisor remote. Queries allow no transport.
    func testPartialCloneIsDetectedInAnyScope() {
        XCTAssertFalse(inspect([]).isPartialClone)
        XCTAssertTrue(inspect([entry(.local, "remote.origin.promisor", "true")]).isPartialClone)
        XCTAssertTrue(inspect([entry(.local, "remote.origin.promisor", nil)]).isPartialClone, "valueless means true")
        XCTAssertTrue(inspect([entry(.global, "remote.origin.promisor", "yes")]).isPartialClone, "any scope")
        XCTAssertTrue(inspect([entry(.local, "extensions.partialclone", "origin")]).isPartialClone)
        XCTAssertFalse(inspect([entry(.local, "remote.origin.promisor", "false")]).isPartialClone)
        // git registers a promisor remote for a filter alone, and for an empty extensions.partialclone (#317).
        XCTAssertTrue(inspect([entry(.local, "remote.origin.partialclonefilter", "blob:limit=1m")]).isPartialClone)
        XCTAssertTrue(inspect([entry(.global, "remote.other.partialclonefilter", nil)]).isPartialClone, "any value")
        XCTAssertTrue(
            inspect([
                entry(.local, "remote.origin.promisor", "false"), entry(.local, "remote.origin.partialclonefilter", ""),
            ]).isPartialClone, "a filter makes the remote a promisor even when promisor is false")
        XCTAssertTrue(inspect([entry(.local, "extensions.partialclone", "")]).isPartialClone)
        XCTAssertTrue(inspect([entry(.local, "extensions.partialclone", nil)]).isPartialClone)
        XCTAssertEqual(
            inspect([entry(.local, "remote.origin.promisor", "true")]).safetyContext?.isPartialClone, true)
    }

    func testPartialCloneSettingsAreReported() {
        let samples = [
            entry(.local, "remote.origin.promisor", "true"),
            entry(.local, "remote.origin.partialclonefilter", "blob:none"),
            entry(.local, "extensions.partialclone", "origin"),
        ]
        for sample in samples {
            let findings = inspect([sample]).report.findings
            XCTAssertEqual(findings.map(\.handling), [.neutralized], sample.key)
            XCTAssertEqual(findings.map(\.threat), ["T5"], sample.key)
        }
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
        XCTAssertTrue(inspect([entry(.local, "user.name", "me")]).report.findings.isEmpty)
        XCTAssertTrue(
            inspect([entry(.global, "core.fsmonitor", "x")]).report.findings.isEmpty, "trusted scopes are not reported")
    }

    /// SEC-T14-10: keys only a git typed by the user runs (pager, editor, `!` aliases) are reported, so Open in Terminal
    /// confirms first (#278). The app never runs them, so they change none of its arguments.
    func testSECT14_10_TerminalOnlyCommandKeysAreReported() {
        let commands = [
            entry(.local, "core.pager", "sh -c x"), entry(.local, "pager.log", "sh -c x"),
            entry(.worktree, "core.editor", "x"), entry(.local, "sequence.editor", "x"),
            entry(.local, "alias.st", "!sh -c x"),
        ]
        for command in commands {
            let inspection = inspect([command])
            XCTAssertEqual(inspection.report.findings.map(\.threat), ["T14"], command.key)
            XCTAssertEqual(inspection.report.findings.map(\.handling), [.reported], command.key)
            XCTAssertEqual(inspection.neutralization, [], "the app's own commands are unchanged")
            XCTAssertFalse(inspection.report.isBlocked)
        }
        for harmless in [
            entry(.local, "pager.log", "false"), entry(.local, "pager.diff", "true"), entry(.local, "pager.show", nil),
            entry(.local, "alias.st", "status -sb"), entry(.global, "core.pager", "sh -c x"),
            entry(.global, "alias.x", "!x"),
        ] {
            XCTAssertTrue(inspect([harmless]).report.findings.isEmpty, "\(harmless.key)=\(harmless.value ?? "nil")")
        }
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

    /// #489: every `remote.<name>` section is a remote-tracking namespace, so its name is matched against
    /// `refs/remotes/` even when `RemoteName` refuses it (a hand-edited config can hold `+`, `@`, or non-ASCII). Only
    /// valid names become `remotes`, the ones passed to git. Names compare in bytes: NFC and NFD are two remotes.
    func testEveryRemoteSectionNameIsKeptForMatching() {
        let result = inspect([
            entry(.local, "remote.gh.url", "https://github.com/o/r.git"),
            entry(.local, "remote.gh/fork+1.url", "https://example.invalid/r.git"),
            entry(.local, "remote.caf\u{E9}.url", "https://example.invalid/a.git"),
            entry(.local, "remote.cafe\u{301}.url", "https://example.invalid/b.git"),
            entry(.local, "remote.me@host.fetch", "+refs/heads/*:refs/remotes/me@host/*"),
            entry(.local, "remote.gh.fetch", "+refs/heads/*:refs/remotes/gh/*"),
            entry(.local, "remote.-evil.url", "https://x/y"),
            // Longer than any valid ref could start with (T15): left out.
            entry(.local, "remote.\(String(repeating: "x", count: 1_010)).url", "https://x/y"),
            entry(.local, "remote.\(String(repeating: "y", count: 1_009)).url", "https://x/y"),
        ])
        XCTAssertEqual(result.remotes.map(\.name.value), ["gh"])
        XCTAssertEqual(
            result.remoteNames.map { Array($0.utf8) },
            ["gh", "gh/fork+1", "caf\u{E9}", "cafe\u{301}", "me@host", "-evil", String(repeating: "y", count: 1_009)]
                .map { Array($0.utf8) })
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

    // MARK: - Bounded work on huge listings (#262, T15)

    private func local(_ section: String, _ subsection: String?, _ variable: String, _ value: String) -> ConfigEntry {
        ConfigEntry(scope: .local, section: section, subsection: subsection, variable: variable, value: value)
    }

    /// SEC-T15-12. A repository chooses its `config --list` output up to the stdout cap. 100,000 remotes (plus as many repeats)
    /// and 100,000 URL-specific TLS and proxy keys must not cost quadratic time: before #262 the remote, TLS, and
    /// proxy de-duplication and the trusted-proxy lookup each scanned what came before.
    func testSECT15_12_HugeListingIsInspectedInLinearTime() {
        var entries: [ConfigEntry] = []
        for index in 0..<100_000 {
            entries.append(local("remote", "r\(index)", "url", "https://example.invalid/\(index).git"))
            entries.append(local("remote", "r0", "url", "https://example.invalid/again.git"))
            entries.append(local("http", "https://h\(index).invalid/", "sslverify", "false"))
            entries.append(local("http", "https://p\(index).invalid/", "proxy", "http://proxy.invalid"))
        }
        let clock = ContinuousClock()
        let started = clock.now
        let result = inspect(entries)
        let elapsed = clock.now - started

        // Linear code takes ~1.5 s in a local Debug build and ~3 s on a busy CI runner; the quadratic code this guards
        // against took minutes. 20 s separates the two without failing on runner variance (#279).
        XCTAssertLessThan(elapsed, .seconds(20), "400,000 entries took \(elapsed)")
        XCTAssertEqual(result.remotes.count, RepoConfigInspector.maximumRemotes)
        XCTAssertEqual(result.remotes.first?.name.value, "r0")
        XCTAssertEqual(result.omittedRemotes, 100_000 - RepoConfigInspector.maximumRemotes)
        XCTAssertEqual(result.remoteNames.count, RepoConfigInspector.maximumRemotes, "matching names are bounded too")
        XCTAssertEqual(result.report.findings.count, RepoConfigInspector.maximumFindings)
        XCTAssertEqual(result.report.omittedFindings, 200_000 - RepoConfigInspector.maximumFindings)
        XCTAssertNotNil(result.fetchBlockingReason, "too many URL overrides: fetch is disabled")
        XCTAssertFalse(result.report.isBlocked, "queries still run: nothing here needs neutralizing")
    }

    func testTooManyFilterDriversStopQueries() {
        func drivers(_ count: Int) -> [ConfigEntry] {
            (0..<count).map { local("filter", "d\($0)", "clean", "evil") }
        }
        let atLimit = inspect(drivers(RepoConfigInspector.maximumNeutralizedDrivers))
        XCTAssertFalse(atLimit.report.isBlocked)
        XCTAssertEqual(atLimit.neutralization.count, RepoConfigInspector.maximumNeutralizedDrivers * 8)

        let over = inspect(drivers(RepoConfigInspector.maximumNeutralizedDrivers + 1))
        XCTAssertTrue(over.report.isBlocked, "every driver must be neutralized, or nothing runs (fail closed)")
        XCTAssertNil(over.safetyContext)
    }

    func testTooManyFetchOverridesDisableFetchOnly() {
        func keys(_ count: Int) -> [ConfigEntry] {
            (0..<count).map { local("http", "https://h\($0).invalid/", "sslverify", "false") }
        }
        XCTAssertNil(inspect(keys(RepoConfigInspector.maximumFetchOverrides)).fetchBlockingReason)
        let over = inspect(keys(RepoConfigInspector.maximumFetchOverrides + 1))
        XCTAssertNotNil(over.fetchBlockingReason)
        XCTAssertNotNil(over.safetyContext, "queries are unaffected")
    }

    func testProxyIsStillResetToTheLastTrustedValue() {
        let result = inspect([
            entry(.global, "http.proxy", "http://first.invalid"), entry(.local, "http.proxy", "http://evil.invalid"),
            entry(.global, "http.proxy", "http://trusted.invalid"),
            entry(.local, "http.https://x.invalid/.proxy", "http://evil.invalid"),
        ])
        XCTAssertEqual(
            result.fetchAuthentication,
            ["-c", "http.proxy=http://trusted.invalid", "-c", "http.https://x.invalid/.proxy=http://trusted.invalid"])
    }

    // MARK: - Result cache hardening (#88)

    /// A repository-controlled include can point at a file the fingerprint does not stamp (even a tracked file in the
    /// worktree, which a checkout changes), so the inspection is never cached (fail closed). Trusted includes only
    /// bring trusted values.
    func testRepositoryControlledIncludesMakeTheInspectionUncacheable() {
        XCTAssertFalse(inspect([entry(.local, "include.path", "../shared.cfg")]).isCacheable)
        XCTAssertFalse(inspect([entry(.worktree, "includeif.gitdir:~/x/.path", "x.cfg")]).isCacheable)
        XCTAssertFalse(inspect([entry(.local, "INCLUDE.PATH", "x.cfg")]).isCacheable, "keys are lowercased by git")
        XCTAssertTrue(inspect([entry(.global, "include.path", "~/.gitconfig-work")]).isCacheable)
        XCTAssertTrue(inspect([entry(.global, "includeif.gitdir:~/work/.path", "~/.gitconfig-work")]).isCacheable)
    }

    private func temporaryFile(_ contents: String) throws -> URL {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("overgrove-fp-\(UUID().uuidString)")
        try contents.write(to: file, atomically: false, encoding: .utf8)
        return file
    }

    private func fileStatus(_ file: URL) throws -> stat {
        var info = stat()
        guard stat(file.path, &info) == 0 else { throw POSIXError(.ENOENT) }
        return info
    }

    /// The modification time can be set back (`touch -m`, archive extraction); the status change time cannot.
    func testFingerprintSeesARewriteThatRestoresSizeAndModificationTime() async throws {
        let file = try temporaryFile("[core]\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let original = try fileStatus(file)
        let before = RepoConfigInspectionCache.Fingerprint.make([file])

        try await Task.sleep(for: .milliseconds(20))  // a later status change time
        let handle = try FileHandle(forWritingTo: file)
        try handle.write(contentsOf: Data("[evil]\n".utf8))  // same size
        try handle.close()
        let times = [original.st_atimespec, original.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, file.path, times, 0), 0)

        let restored = try fileStatus(file)
        XCTAssertEqual(restored.st_size, original.st_size, "control: same size")
        XCTAssertEqual(restored.st_mtimespec.tv_sec, original.st_mtimespec.tv_sec, "control: same modification time")
        XCTAssertEqual(restored.st_mtimespec.tv_nsec, original.st_mtimespec.tv_nsec, "control: same modification time")
        XCTAssertNotEqual(RepoConfigInspectionCache.Fingerprint.make([file]), before)
    }

    func testFingerprintSeesAFileReplacedByAnother() throws {
        let file = try temporaryFile("[core]\n")
        defer { try? FileManager.default.removeItem(at: file) }
        let before = RepoConfigInspectionCache.Fingerprint.make([file])
        let replacement = try temporaryFile("[core]\n")
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        try FileManager.default.setAttributes(
            [.modificationDate: try XCTUnwrap(attributes[.modificationDate] as? Date)], ofItemAtPath: replacement.path)
        XCTAssertEqual(rename(replacement.path, file.path), 0)

        XCTAssertNotEqual(RepoConfigInspectionCache.Fingerprint.make([file]), before, "another inode")
    }

    func testFingerprintRecordsMissingFiles() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("overgrove-fp-\(UUID().uuidString)")
        let absent = RepoConfigInspectionCache.Fingerprint.make([file])
        XCTAssertEqual(RepoConfigInspectionCache.Fingerprint.make([file]), absent)
        try "".write(to: file, atomically: false, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        XCTAssertNotEqual(RepoConfigInspectionCache.Fingerprint.make([file]), absent, "creating a file invalidates")
    }

    func testInspectionCacheIsBoundedAndForgetsARepositoryAtOnce() async {
        let cache = RepoConfigInspectionCache(capacity: 2)
        let inspection = inspect([])
        let fingerprint = RepoConfigInspectionCache.Fingerprint.make([])
        await cache.store(inspection, for: "r1\u{0}/a", fingerprint: fingerprint)
        await cache.store(inspection, for: "r1\u{0}/b", fingerprint: fingerprint)
        await cache.store(inspection, for: "r2\u{0}/a", fingerprint: fingerprint)
        let evicted = await cache.inspection(for: "r1\u{0}/a", fingerprint: fingerprint)
        XCTAssertNil(evicted, "the least recently used entry is evicted")

        await cache.invalidate(keysWithPrefix: "r1\u{0}")
        let forgotten = await cache.inspection(for: "r1\u{0}/b", fingerprint: fingerprint)
        let kept = await cache.inspection(for: "r2\u{0}/a", fingerprint: fingerprint)
        XCTAssertNil(forgotten)
        XCTAssertEqual(kept, inspection)
    }
}

/// End to end against the malicious fixture (docs/testing/fixtures.md §8): SEC-T4-01/02/03.
final class RepoConfigInspectorFixtureTests: XCTestCase {
    func testSECT4_FilterPayloadRunsWithoutNeutralizationAndNotWithIt() async throws {
        let fixture = try await makeFixture(malicious: true)
        let environment = try await GitEnvironment.discoverForTesting()
        let client = GitClient(environment: environment, parentEnvironment: fixture.environment)
        let worktree = fixture.repository
        // Make the `*.md` files stat-dirty so every status re-reads them through `filter.fixtureproc.process`. A fresh
        // fixture is only sometimes racily clean, which made the control below flaky (#273).
        let later = Date().addingTimeInterval(5)
        for name in ["README.md", "docs/manual.md"] {
            try FileManager.default.setAttributes(
                [.modificationDate: later], ofItemAtPath: worktree.appendingPathComponent(name).path)
        }

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

        // Control: without its own neutralization, the clean filter (T4) runs, proving the test is meaningful. Only
        // the `fixture` driver's clean and process overrides are dropped (an empty `process=` would still take over
        // from `clean`). The fixture's `filter.fixtureproc.process` exits before answering git's handshake,
        // so leaving it on makes status die with "the remote end hung up unexpectedly" whenever an `*.md` file is
        // re-read (#273: GIT_TRACE_PACKET shows `git> git-filter-client`, `version=2`, then EOF).
        let unneutralized = RepoSafetyContext(
            inspectedNeutralization: Self.dropping(
                ["filter.fixture.clean=", "filter.fixture.process="], from: inspection.neutralization),
            fetchAuthentication: [], trustedSSHCommand: nil)
        _ = try await client.run(.status, in: worktree, safety: unneutralized)
        XCTAssertTrue(fixture.canaries().contains("T4-filter-clean"), "canaries: \(fixture.canaries())")
        XCTAssertFalse(fixture.canaries().contains("T4-filter-process"), "only the clean filter is left on")
    }

    /// `neutralization` without the `-c <key>` pairs.
    private static func dropping(_ keys: Set<String>, from neutralization: [String]) -> [String] {
        var result: [String] = []
        var index = neutralization.startIndex
        while index < neutralization.endIndex {
            if neutralization[index] == "-c", index + 1 < neutralization.endIndex,
                keys.contains(neutralization[index + 1])
            {
                index += 2
                continue
            }
            result.append(neutralization[index])
            index += 1
        }
        XCTAssertEqual(result.count, neutralization.count - 2 * keys.count, "\(keys) were in the neutralization")
        return result
    }
}
