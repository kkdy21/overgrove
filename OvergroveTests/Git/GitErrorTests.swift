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

    /// `GIT_ALLOW_PROTOCOL` and `protocol.<name>.allow=never` refusals (#161, T5). Real Apple Git 2.54.0 stderr.
    func testBlockedTransports() throws {
        for name in ["ext", "fd", "evilhelper", "codecommit", "file", "ftp", "Git-Remote+x.y", "1abc"] {
            let error = try XCTUnwrap(classify("fatal: transport '\(name)' not allowed\n"))
            guard case .transportNotAllowed(let transport, _) = error else { return XCTFail("\(name): got \(error)") }
            XCTAssertEqual(transport, name)
            XCTAssertTrue(error.message.contains("'\(name)'"), error.message)
            XCTAssertTrue(error.message.contains("https, ssh"), "the message says which transports work")
            XCTAssertFalse(error.isRetryable, "retrying cannot help until the remote changes")
            XCTAssertEqual(error.detail?.text, "fatal: transport '\(name)' not allowed\n")
        }
    }

    func testBlockedTransportNameIsSanitized() throws {
        // The name comes from repository configuration. Anything that is not a plain scheme name is not echoed.
        let hostile = [
            "fatal: transport 'a b' not allowed", "fatal: transport '' not allowed",
            "fatal: transport '\(String(repeating: "x", count: 65))' not allowed",
            "fatal: transport 'evil\u{1B}[31mred' not allowed", "fatal: transport '+x' not allowed",
            "fatal: transport 'évil' not allowed",
        ]
        for sample in hostile {
            let error = try XCTUnwrap(classify(sample))
            guard case .transportNotAllowed(nil, _) = error else { return XCTFail("\(sample): got \(error)") }
            XCTAssertFalse(error.message.contains("evil"), error.message)
            XCTAssertFalse(error.message.isEmpty)
        }
    }

    func testServerTextCannotPoseAsATransportBlock() {
        let spoofed = "remote: transport 'evil' not allowed\nfatal: unable to access 'https://example.com/r/': x\n"
        guard case .nonZeroExit = classify(spoofed) else { return XCTFail("only git's own fatal line counts") }
        // A sideband line that copies git's wording must not hide the real failure (security review of #191).
        let sideband = "remote: fatal: transport 'evil' not allowed\nfatal: Authentication failed for 'https://x/'\n"
        guard case .authenticationFailed = classify(sideband) else { return XCTFail("the real error must win") }
    }

    func testRefusalIsFoundAmongOtherLines() throws {
        let stderr = "warning: redirecting to https://example.com/r.git/\nfatal: transport 'hg' not allowed\n"
        guard case .transportNotAllowed("hg", _) = try XCTUnwrap(classify(stderr)) else { return XCTFail() }
    }

    func testRemoteHelperFailureIsNotATransportBlock() {
        // A helper that ran and failed (no GIT_ALLOW_PROTOCOL) must not be mistaken for a block.
        guard case .nonZeroExit = classify("fatal: remote helper 'evilhelper' aborted session\n") else {
            return XCTFail("only git's refusal counts as blocked")
        }
    }

    func testAuthenticationFailures() {
        // The first two are real Apple Git 2.54.0 output against a local HTTP server answering 401.
        let samples = [
            "fatal: could not read Username for 'http://127.0.0.1:18765': terminal prompts disabled\n",
            "fatal: Authentication failed for 'http://127.0.0.1:18765/401/r.git/'\n",
            "remote: Invalid username or password.\nfatal: Authentication failed for 'https://example.com/r.git/'",
        ]
        for sample in samples {
            guard case .authenticationFailed = classify(sample) else { return XCTFail(sample) }
        }
    }

    /// #78: SSH failures get their own cases, because the fix differs from an HTTPS password problem.
    func testSSHFailures() throws {
        let fatal =
            "fatal: Could not read from remote repository.\n\nPlease make sure you have the correct access "
            + "rights\nand the repository exists.\n"
        guard case .sshAuthenticationFailed = classify("git@example.com: Permission denied (publickey).\r\n" + fatal)
        else { return XCTFail("a rejected key is an SSH authentication failure") }
        guard case .hostKeyVerificationFailed(changed: false, _) = classify("Host key verification failed.\r\n" + fatal)
        else { return XCTFail("an unknown host key") }
        // OpenSSH's banner for a changed key, followed by the same final line.
        let changed = """
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
            @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
            IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
            Host key verification failed.

            """
        guard case .hostKeyVerificationFailed(changed: true, _) = classify(changed + fatal) else {
            return XCTFail("a changed host key must be told apart: it can mean interception")
        }
        // A local file error mentions "Permission denied" without an SSH method list.
        guard case .nonZeroExit = classify("error: cannot open '.git/FETCH_HEAD': Permission denied\n") else {
            return XCTFail("not an SSH failure")
        }
    }

    /// #78: real Apple Git 2.54.0 output (local HTTP server, local paths).
    func testAccessDeniedAndRemoteNotFound() {
        guard
            case .accessDenied = classify(
                "fatal: unable to access 'http://127.0.0.1:18765/403/r.git/': The requested URL returned error: 403\n")
        else { return XCTFail("HTTP 403") }
        let notFound = [
            "fatal: repository 'http://127.0.0.1:18765/404/r.git/' not found\n",
            "fatal: '/nonexistent/repo.git' does not appear to be a git repository\nfatal: Could not read from remote "
                + "repository.\n\nPlease make sure you have the correct access rights\nand the repository exists.\n",
            "fatal: 'origin' does not appear to be a git repository\nfatal: Could not read from remote repository.\n",
        ]
        for sample in notFound {
            guard case .remoteNotFound = classify(sample) else { return XCTFail(sample) }
        }
        guard
            case .nonZeroExit = classify(
                "fatal: unable to access 'http://127.0.0.1:18765/500/r.git/': The requested URL returned error: 500\n")
        else { return XCTFail("other HTTP errors stay unclassified") }
    }

    /// #78: only lines from local git and ssh count. Over HTTP the server's text arrives as `remote:` lines, and it
    /// must not be able to choose the guidance the user sees.
    func testServerLinesCannotChooseTheCategory() {
        let cases: [(String, String)] = [
            (
                "remote: fatal: Authentication failed for 'x'\nfatal: unable to access 'https://h/': The requested URL "
                    + "returned error: 403\n", "accessDenied"
            ),
            (
                "remote: Host key verification failed.\nfatal: unable to access 'https://h/': Failed to connect to h "
                    + "port 443 after 0 ms: Couldn't connect to server\n", "networkUnavailable"
            ),
            ("remote: Permission denied (publickey).\nfatal: the remote end hung up unexpectedly\n", "nonZeroExit"),
            ("remote: fatal: repository 'x' not found\nfatal: early EOF\n", "nonZeroExit"),
        ]
        for (stderr, expected) in cases {
            let error = classify(stderr)
            let name = error.map { String(describing: $0).prefix { $0 != "(" } } ?? "nil"
            XCTAssertEqual(String(name), expected, stderr)
        }
    }

    func testNetworkFailures() {
        let samples = [
            "fatal: unable to access 'https://nonexistent-host.invalid/x.git/': "
                + "Could not resolve host: nonexistent-host.invalid",
            "ssh: connect to host example.com port 22: Connection refused",
            "ssh: connect to host example.com port 22: Operation timed out",
            "fatal: unable to access 'https://h/': Failed to connect to h port 443: Network is unreachable",
            // Real Apple Git 2.54.0 output for https and ssh to a closed local port, then OpenSSH's wording for DNS
            // and routing failures (not captured: that needs a network).
            "fatal: unable to access 'https://127.0.0.1:1/r.git/': Failed to connect to 127.0.0.1 port 1 after 0 ms: "
                + "Couldn't connect to server\n",
            "ssh: connect to host 127.0.0.1 port 1: Connection refused\r\nfatal: Could not read from remote "
                + "repository.\n",
            "ssh: Could not resolve hostname nowhere.invalid: nodename nor servname provided, or not known\r\n",
            "ssh: connect to host 10.255.255.1 port 22: No route to host\r\n",
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
            .blockedBySecurityPolicy(detail: detail), .transportNotAllowed(transport: "hg", detail: detail),
            .transportNotAllowed(transport: nil, detail: detail), .timeout(seconds: 15), .outputTruncated,
            .authenticationFailed(detail: detail), .sshAuthenticationFailed(detail: detail),
            .hostKeyVerificationFailed(changed: false, detail: detail),
            .hostKeyVerificationFailed(changed: true, detail: detail), .accessDenied(detail: detail),
            .remoteNotFound(detail: detail), .networkUnavailable(detail: detail),
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
