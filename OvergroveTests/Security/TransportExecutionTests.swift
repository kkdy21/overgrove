import Foundation
import XCTest

@testable import Overgrove

/// SEC-T5-01…07: transport-layer programs planted in the `--malicious` fixture's configuration
/// (security-review.md T5, fixtures.md §8.1). SEC-T5-08…15 (remote helpers) are in `RemoteTransportSecurityTests`.
///
/// Every test fetches with the app's real path and then runs the vector with plain git as a negative control. Tests
/// that add configuration inspect the repository again, as the app does when configuration changes.
final class TransportExecutionTests: XCTestCase {
    private func harness() async throws -> CanaryHarness {
        try await CanaryHarness.make(fixture: try await makeFixture(malicious: true))
    }

    private func fetchQuery(_ remote: String, _ harness: CanaryHarness) throws -> CanaryHarness.Query {
        CanaryHarness.Query(
            kind: .fetch(.fetch(remote: try XCTUnwrap(RemoteName(remote)))),
            directory: harness.fixture.repository,
            label: "fetch \(remote)"
        )
    }

    /// The app's fetch, which is expected to fail. Returns the classified error.
    private func failingAppFetch(_ remote: String, _ harness: CanaryHarness) async throws -> GitError {
        let started = ContinuousClock.now
        do {
            try await harness.runHardened(try fetchQuery(remote, harness))
        } catch let error as GitError {
            XCTAssertLessThan(ContinuousClock.now - started, .seconds(60), "fetch \(remote) must fail, not hang")
            return error
        }
        XCTFail("fetch \(remote) unexpectedly succeeded")
        return .cancelled
    }

    private func assertTransportRefused(
        _ error: GitError, _ transport: String, file: StaticString = #filePath, line: UInt = #line
    ) {
        guard case .transportNotAllowed(let refused, _) = error else {
            return XCTFail("expected transportNotAllowed(\(transport)), got \(error)", file: file, line: line)
        }
        XCTAssertEqual(refused, transport, file: file, line: line)
    }

    private func config(_ harness: CanaryHarness, _ key: String, _ value: String) async throws {
        _ = try await harness.runPlainSetup(["config", key, value])
    }

    /// The app inspects again after configuration changes; tests that add configuration do the same.
    private func reinspected(_ harness: CanaryHarness) async throws -> CanaryHarness {
        try await CanaryHarness.make(fixture: harness.fixture)
    }

    /// The fetch reached the ref update (refs/remotes/origin/feat/remote-only exists only after a fetch of origin).
    private func assertOriginFetched(_ harness: CanaryHarness, file: StaticString = #filePath, line: UInt = #line)
        async
    {
        do {
            try await harness.runHardenedSetup(["rev-parse", "--verify", "refs/remotes/origin/feat/remote-only"])
        } catch {
            XCTFail("the app's fetch of origin did not update refs: \(error)", file: file, line: line)
        }
    }

    private func assertControlFired(
        _ id: String, _ harness: CanaryHarness, file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(
            harness.fixture.canaries().contains(id), "control: \(id) should run, got \(harness.fixture.canaries())",
            file: file, line: line)
    }

    /// SEC-T5-01: a repository-local `core.sshCommand` never runs: the app sets `GIT_SSH_COMMAND` from the trusted
    /// scope. A recording `core.sshCommand` in the isolated global configuration proves the transport step was
    /// reached with the trusted command (and keeps the runner's own ssh configuration and the network out of it).
    /// Covers the direct ssh remote and an https remote rewritten to ssh by `insteadOf`.
    func testSECT5_01_LocalSSHCommandDoesNotRun() async throws {
        let executables = try TestExecutables()
        addTeardownBlock { executables.remove() }
        let trustedRecords = executables.directory.appendingPathComponent("trusted", isDirectory: true)
        let trustedSSH = try executables.canaryPayload("trusted-ssh", canary: trustedRecords, tail: "exit 1")
        var harness = try await harness()
        _ = try await harness.runPlainSetup(["config", "--global", "core.sshCommand", trustedSSH.path])
        harness = try await reinspected(harness)
        XCTAssertEqual(harness.safety.trustedSSHCommand, trustedSSH.path)

        for remote in ["sshremote", "redirected"] {
            try? FileManager.default.removeItem(at: trustedRecords.appendingPathComponent("trusted-ssh"))
            _ = try await failingAppFetch(remote, harness)
            harness.fixture.assertNoCanaries(after: "app fetch \(remote)")
            XCTAssertTrue(
                FileManager.default.fileExists(atPath: trustedRecords.appendingPathComponent("trusted-ssh").path),
                "app fetch \(remote) must reach ssh with the trusted command")
        }
        for remote in ["sshremote", "redirected"] {
            try harness.fixture.clearCanaries()
            _ = try await harness.runPlain(try fetchQuery(remote, harness))
            assertControlFired("T5-sshCommand", harness)
        }
    }

    /// SEC-T5-02: the local `remote.origin.uploadpack` override does not run on a local-path remote fetch.
    func testSECT5_02_LocalUploadPackDoesNotRun() async throws {
        let harness = try await harness()
        let origin = try fetchQuery("origin", harness)
        try await harness.runHardened(origin)
        harness.fixture.assertNoCanaries(after: "app fetch origin")
        await assertOriginFetched(harness)

        try await harness.forgetRemoteOnlyBranch()
        _ = try await harness.runPlain(origin, dropping: ["--upload-pack=git-upload-pack"])
        assertControlFired("T5-uploadpack", harness)
    }

    /// SEC-T5-03: an `ext::` remote is refused even when the repository sets `protocol.ext.allow=always`.
    func testSECT5_03_ExtTransportIsRefused() async throws {
        var harness = try await harness()
        try await config(harness, "protocol.ext.allow", "always")
        harness = try await reinspected(harness)
        assertTransportRefused(try await failingAppFetch("extremote", harness), "ext")
        harness.fixture.assertNoCanaries(after: "app fetch extremote")

        _ = try await harness.runPlain(try fetchQuery("extremote", harness))
        assertControlFired("T5-ext-transport", harness)
    }

    /// SEC-T5-04: an ordinary-looking https remote rewritten to `ext::` by `url.<base>.insteadOf` is refused.
    func testSECT5_04_InsteadOfToExtIsRefused() async throws {
        var harness = try await harness()
        let canary = harness.fixture.canary.appendingPathComponent("T5-ext-transport").path
        try await config(harness, "protocol.ext.allow", "always")
        // The whole URL is rewritten, so nothing is appended to the canary path.
        try await config(harness, "url.ext::sh -c touch% \(canary).insteadOf", "https://swap.invalid/overgrove.git")
        try await config(harness, "remote.swapped.url", "https://swap.invalid/overgrove.git")
        try await config(harness, "remote.swapped.fetch", "+refs/heads/*:refs/remotes/swapped/*")
        harness = try await reinspected(harness)

        assertTransportRefused(try await failingAppFetch("swapped", harness), "ext")
        harness.fixture.assertNoCanaries(after: "app fetch swapped")

        _ = try await harness.runPlain(try fetchQuery("swapped", harness))
        assertControlFired("T5-ext-transport", harness)
    }

    /// SEC-T5-05: a repository-local `core.gitProxy` does not run for a `git://` remote (`GIT_PROXY_COMMAND` is empty).
    func testSECT5_05_LocalGitProxyDoesNotRun() async throws {
        let harness = try await harness()
        // With `GIT_PROXY_COMMAND` empty, git connects directly and fails at name resolution: it reached the
        // transport step (anything earlier would be classified differently).
        let error = try await failingAppFetch("gitremote", harness)
        guard case .networkUnavailable = error else { return XCTFail("expected networkUnavailable, got \(error)") }
        harness.fixture.assertNoCanaries(after: "app fetch gitremote")

        _ = try await harness.runPlain(try fetchQuery("gitremote", harness))
        assertControlFired("T5-gitProxy", harness)
    }

    /// SEC-T5-06: an `fd::` remote is refused immediately instead of stalling the fetch, even when the repository
    /// sets `protocol.fd.allow=always`. Without the hardening, git waits on the descriptor until killed.
    func testSECT5_06_FDTransportIsRefusedWithoutStalling() async throws {
        var harness = try await harness()
        try await config(harness, "protocol.fd.allow", "always")
        try await config(harness, "remote.fdremote.url", "fd::7")
        try await config(harness, "remote.fdremote.fetch", "+refs/heads/*:refs/remotes/fdremote/*")
        harness = try await reinspected(harness)

        let started = ContinuousClock.now
        assertTransportRefused(try await failingAppFetch("fdremote", harness), "fd")
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(10), "refused, not stalled")

        var limits = ProcessLimits.fetch
        limits.timeout = .seconds(3)
        limits.terminationGracePeriod = .milliseconds(500)
        let control = try await harness.runPlain(try fetchQuery("fdremote", harness), limits: limits)
        XCTAssertTrue(control.timedOut, "control: plain fetch of fd:: should stall (\(control.termination))")
    }

    /// SEC-T5-07: `core.alternateRefsCommand` does not run when fetching into a repository with alternates.
    func testSECT5_07_AlternateRefsCommandDoesNotRun() async throws {
        let harness = try await harness()
        let origin = try fetchQuery("origin", harness)
        try await harness.runHardened(origin)
        harness.fixture.assertNoCanaries(after: "app fetch origin")
        await assertOriginFetched(harness)

        try await harness.forgetRemoteOnlyBranch()
        _ = try await harness.runPlain(origin)
        assertControlFired("T5-alternateRefsCommand", harness)
    }
}
