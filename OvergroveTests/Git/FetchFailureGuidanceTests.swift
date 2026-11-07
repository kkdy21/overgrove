import Foundation
import XCTest

@testable import Overgrove

/// FetchFailureGuidance (#78, interaction.md §4.2): what a failed fetch means and what the user can do.
final class FetchFailureGuidanceTests: XCTestCase {
    private let origin = RemoteName("origin")!
    private let secret = "s3" + "cr3t"

    private func detail(_ text: String = "fatal: x") -> MaskedText { MaskedText(masking: text) }

    private func guidance(_ error: GitError, host: String? = nil) throws -> FetchFailureGuidance {
        try XCTUnwrap(FetchFailureGuidance(error: error, remote: origin, host: host))
    }

    // MARK: - Categories (interaction.md: authentication, network, timeout, other)

    func testEveryReasonMapsToOneOfTheFourCategories() throws {
        let expectations: [(GitError, FetchFailureGuidance.Reason, FetchFailureGuidance.Category)] = [
            (.authenticationFailed(detail: detail()), .credentialsRejected, .authentication),
            (.sshAuthenticationFailed(detail: detail()), .sshKeyRejected, .authentication),
            (.hostKeyVerificationFailed(changed: false, detail: detail()), .hostKeyNotTrusted, .authentication),
            (.hostKeyVerificationFailed(changed: true, detail: detail()), .hostKeyChanged, .authentication),
            (.accessDenied(detail: detail()), .accessDenied, .authentication),
            (.networkUnavailable(detail: detail()), .hostUnreachable, .network),
            (.timeout(seconds: 120), .timedOut(seconds: 120), .timeout),
            (.remoteNotFound(detail: detail()), .remoteNotFound, .other),
            (.transportNotAllowed(transport: "hg", detail: detail()), .transportNotAllowed, .other),
            (
                .configInspectionFailed(
                    reason: "This repository sets its own TLS certificate files; fetching is disabled."),
                .blockedByConfiguration, .other
            ),
            (.nonZeroExit(code: 128, detail: detail()), .unknown, .other),
            (.worktreeMissing(path: "/x"), .unknown, .other),
        ]
        for (error, reason, category) in expectations {
            let result = try guidance(error)
            XCTAssertEqual(result.reason, reason, "\(error)")
            XCTAssertEqual(result.category, category, "\(error)")
            XCTAssertFalse(result.summary.isEmpty, "\(error)")
            XCTAssertFalse(result.guidance.isEmpty, "\(error)")
            XCTAssertEqual(result.remote, origin)
        }
    }

    func testCancellationIsNotAFailure() {
        // interaction.md: Stop returns to Idle with "Fetch cancelled", not to the Failed state.
        XCTAssertNil(FetchFailureGuidance(error: .cancelled, remote: origin))
    }

    // MARK: - Texts and commands

    func testAuthenticationSendsTheUserToTerminal() throws {
        let result = try guidance(.authenticationFailed(detail: detail()))
        XCTAssertEqual(result.summary, "Authentication failed for origin")
        XCTAssertTrue(result.guidance.contains("does not prompt for passwords"), result.guidance)
        XCTAssertEqual(result.commands, ["git fetch origin"])
    }

    func testHostKeyIsNeverAcceptedOnTheUsersBehalf() throws {
        let unknown = try guidance(.hostKeyVerificationFailed(changed: false, detail: detail()), host: "example.com")
        XCTAssertEqual(unknown.summary, "The SSH host key of example.com is not trusted yet")
        XCTAssertTrue(unknown.guidance.contains("fingerprint"), unknown.guidance)
        XCTAssertEqual(unknown.commands, ["git fetch origin"])

        let changed = try guidance(.hostKeyVerificationFailed(changed: true, detail: detail()), host: "example.com")
        XCTAssertEqual(changed.summary, "The SSH host key of example.com has changed")
        XCTAssertTrue(changed.guidance.contains("intercept"), changed.guidance)
        XCTAssertEqual(changed.commands, ["ssh-keygen -F example.com"], "read-only lookup, never ssh-keygen -R")
        XCTAssertEqual(
            try guidance(.hostKeyVerificationFailed(changed: true, detail: detail())).commands, [],
            "no host, no command")
    }

    func testNetworkNamesTheHostWhenKnown() throws {
        XCTAssertEqual(
            try guidance(.networkUnavailable(detail: detail()), host: "github.com").summary,
            "Could not reach github.com")
        XCTAssertEqual(
            try guidance(.networkUnavailable(detail: detail())).summary,
            "Could not reach the remote of origin")
    }

    func testTimeoutAndOthers() throws {
        XCTAssertEqual(try guidance(.timeout(seconds: 120)).summary, "Fetch timed out after 120 s")
        XCTAssertEqual(try guidance(.remoteNotFound(detail: detail())).commands, ["git remote -v"])
        let transport = try guidance(.transportNotAllowed(transport: "codecommit", detail: detail()))
        XCTAssertTrue(transport.guidance.contains("'codecommit'"), transport.guidance)
        let unknown = try guidance(.nonZeroExit(code: 128, detail: detail()))
        XCTAssertEqual(unknown.summary, "Fetch failed")
        XCTAssertEqual(unknown.commands, ["git fetch origin"])
    }

    func testNoRemotes() {
        let result = FetchFailureGuidance.noRemotes
        XCTAssertEqual(result.summary, "No remotes configured")
        XCTAssertNil(result.remote)
        XCTAssertEqual(result.category, .other)
        XCTAssertEqual(result.commands, [])
    }

    func testCommandsUseOnlyTheValidatedRemoteName() throws {
        // RemoteName allows only [A-Za-z0-9._/-], so the copied command needs no shell quoting.
        let remote = try XCTUnwrap(RemoteName("team/fork.v2"))
        let result = try XCTUnwrap(FetchFailureGuidance(error: .timeout(seconds: 120), remote: remote))
        XCTAssertEqual(result.commands, ["git fetch team/fork.v2"])
    }

    // MARK: - Details

    func testDetailTailKeepsTheLastLinesOfMaskedStderr() throws {
        let stderr = (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n\n"
        let result = try guidance(.nonZeroExit(code: 1, detail: detail(stderr)))
        XCTAssertEqual(result.detailTail, (8...12).map { "line \($0)" }.joined(separator: "\n"))
        XCTAssertNil(try guidance(.timeout(seconds: 120)).detailTail)
    }

    // MARK: - Security (T11, T16)

    func testSECT11_02_NoCredentialReachesTheGuidance() throws {
        let stderr =
            "warning: redirecting to https://alice:\(secret)@example.com/r.git/\n"
            + "fatal: unable to access 'https://alice:\(secret)@example.com/r.git/': Could not resolve host: x\n"
        let error = try XCTUnwrap(
            GitError.classify(
                exitCode: 128, signal: nil, timedOut: false, outputTruncated: false, timeoutSeconds: 120,
                stderr: Data(stderr.utf8)))
        let host = FetchFailureGuidance.host(fromRemoteURL: "https://alice:\(secret)@example.com/r.git")
        let result = try guidance(error, host: host)
        let everything =
            [result.summary, result.guidance, result.detail?.text ?? "", result.detailTail ?? ""]
            + result.commands
        for text in everything {
            XCTAssertFalse(text.contains(secret), text)
            XCTAssertFalse(text.contains("alice"), text)
        }
        XCTAssertEqual(result.summary, "Could not reach example.com")
    }

    func testHostFromRemoteURL() {
        let cases: [(String, String?)] = [
            ("https://github.com/o/r.git", "github.com"),
            ("https://alice:\(secret)@GitHub.com:8443/o/r.git", "GitHub.com"),
            ("ssh://git@example.com:2222/o/r.git", "example.com"),
            ("git+ssh://example.com/o/r", "example.com"),
            ("git://example.com/r", "example.com"),
            ("git@github.com:o/r.git", "github.com"),
            ("example.com:o/r.git", "example.com"),
            ("/srv/repos/r.git", nil),
            ("../relative/r.git", nil),
            ("file:///tmp/r", nil),
            ("evilhelper::payload", nil),
            ("https://evil;touch x/r", nil),
            ("https://[::1]/r", nil),
            ("git@-oProxyCommand=x:r", nil),
            ("", nil),
        ]
        for (url, expected) in cases {
            XCTAssertEqual(FetchFailureGuidance.host(fromRemoteURL: url), expected, url)
        }
    }
}
