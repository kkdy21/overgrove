import Foundation
import XCTest

@testable import Overgrove

/// GitError classification (git-command-catalog.md §6) and message rules (overview.md §6.2).
/// Stderr samples are real `LC_ALL=C` output of git 2.50.1 unless noted.
final class GitErrorTests: XCTestCase {
    private func classify(
        exit: Int32? = 128,
        signal: Int32? = nil,
        timedOut: Bool = false,
        truncated: Bool = false,
        _ stderr: String = ""
    ) -> GitError? {
        GitError.classify(
            exitCode: exit,
            signal: signal,
            timedOut: timedOut,
            outputTruncated: truncated,
            timeoutSeconds: 15,
            stderr: Data(stderr.utf8)
        )
    }

    private let secret = "s3" + "cr3t"

    func testSuccessIsNil() {
        XCTAssertNil(classify(exit: 0))
    }

    func testTimeoutAndTruncationComeFirst() {
        XCTAssertEqual(classify(exit: nil, signal: SIGTERM, timedOut: true, "anything"), .timeout(seconds: 15))
        XCTAssertEqual(classify(exit: nil, signal: SIGTERM, truncated: true), .outputTruncated)
        XCTAssertTrue(GitError.outputTruncated.isWarning)
    }

    func testNotARepository() {
        let error = classify("fatal: not a git repository (or any of the parent directories): .git\n")
        guard case .notARepository = error else { return XCTFail("got \(String(describing: error))") }
    }

    func testDubiousOwnershipNeverSuggestsBypass() throws {
        // Format of git's safe.directory refusal.
        let stderr = """
            fatal: detected dubious ownership in repository at '/srv/shared/repo'
            To add an exception for this directory, call:

            \tgit config --global --add safe.directory /srv/shared/repo
            """
        let error = try XCTUnwrap(classify(stderr))
        guard case .dubiousOwnership = error else { return XCTFail("got \(error)") }
        XCTAssertTrue(error.message.contains("does not bypass"))
        XCTAssertFalse(error.suggestedCommand?.contains("--add safe.directory") ?? false)
    }

    func testBlockedTransports() {
        guard case .blockedBySecurityPolicy = classify("fatal: transport 'ext' not allowed\n") else {
            return XCTFail("ext:: must be classified as blocked")
        }
        guard case .blockedBySecurityPolicy = classify("fatal: transport 'fd' not allowed") else {
            return XCTFail("fd:: must be classified as blocked")
        }
    }

    func testAuthenticationFailures() {
        let samples = [
            "fatal: could not read Username for 'https://github.com': terminal prompts disabled",
            "remote: Invalid username or password.\nfatal: Authentication failed for 'https://example.com/r.git/'",
            "git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository.",
            "Host key verification failed.\nfatal: Could not read from remote repository.",
        ]
        for sample in samples {
            guard case .authenticationFailed = classify(sample) else { return XCTFail(sample) }
        }
    }

    func testNetworkFailures() {
        let samples = [
            "fatal: unable to access 'https://nonexistent-host.invalid/x.git/': "
                + "Could not resolve host: nonexistent-host.invalid",
            "ssh: connect to host example.com port 22: Connection refused",
            "ssh: connect to host example.com port 22: Operation timed out",
            "fatal: unable to access 'https://h/': Failed to connect to h port 443: Network is unreachable",
        ]
        for sample in samples {
            guard case .networkUnavailable = classify(sample) else { return XCTFail(sample) }
        }
    }

    func testClassificationRunsOnMaskedStderr() throws {
        let error = try XCTUnwrap(
            classify("fatal: Authentication failed for 'https://alice:\(secret)@example.com/r.git/'")
        )
        let detail = try XCTUnwrap(error.detail)
        XCTAssertFalse(detail.text.contains(secret))
        XCTAssertTrue(detail.text.contains("https://***@example.com/r.git/"))
    }

    func testOtherFailuresUseAMaskedSummary() throws {
        let error = try XCTUnwrap(
            classify(exit: 1, "\n\nerror: pathspec 'x' did not match https://u:\(secret)@h/\nmore")
        )
        guard case .nonZeroExit(let code, _) = error else { return XCTFail("got \(error)") }
        XCTAssertEqual(code, 1)
        XCTAssertEqual(error.message, "error: pathspec 'x' did not match https://***@h/")
        XCTAssertTrue(error.isRetryable)
    }

    func testSignalWithoutTimeoutIsReportedLikeAShell() {
        guard case .nonZeroExit(let code, _) = classify(exit: nil, signal: SIGKILL) else {
            return XCTFail("expected nonZeroExit")
        }
        XCTAssertEqual(code, 128 + SIGKILL)
    }

    func testMaskedTextStripsControlCharactersAndLimitsLength() {
        let text = MaskedText(masking: "a\u{1B}[31mred\u{07}\tok\nline2")
        XCTAssertEqual(text.text, "a[31mred\tok\nline2")
        let long = MaskedText(masking: String(repeating: "x", count: 300))
        XCTAssertEqual(long.summary.count, MaskedText.summaryLength)
        XCTAssertTrue(long.summary.hasSuffix("…"))
        let huge = MaskedText(masking: String(repeating: "y", count: MaskedText.maximumLength + 10))
        XCTAssertEqual(huge.text.count, MaskedText.maximumLength)
    }

    func testParseErrorMapping() {
        let error = GitError(ParseError(parser: "ConfigParser", offset: 42, reason: "unknown scope"))
        XCTAssertEqual(error, .parseFailed(parser: "ConfigParser", offset: 42))
        XCTAssertTrue(error.message.contains("report"))
    }

    func testEveryCaseHasAMessageExceptCancellation() {
        let detail = MaskedText(masking: "x")
        let old = GitVersion(major: 2, minor: 30, patch: 0)
        let cases: [GitError] = [
            .executableNotFound(path: "/usr/bin/git"), .launchFailed(errno: 13), .unsupportedVersion(found: old),
            .notARepository(detail: detail), .dubiousOwnership(detail: detail), .worktreeMissing(path: "/x"),
            .configInspectionFailed(reason: "r"), .invalidArgument(reason: "r"),
            .blockedBySecurityPolicy(detail: detail), .timeout(seconds: 15), .outputTruncated,
            .authenticationFailed(detail: detail), .networkUnavailable(detail: detail),
            .nonZeroExit(code: 1, detail: detail), .parseFailed(parser: "p", offset: 0),
        ]
        for error in cases {
            XCTAssertFalse(error.message.isEmpty, "\(error)")
            XCTAssertFalse(error.isSilent)
        }
        XCTAssertTrue(GitError.cancelled.isSilent)
        XCTAssertTrue(GitError.unsupportedVersion(found: old).message.contains("2.36.0"))
    }
}
