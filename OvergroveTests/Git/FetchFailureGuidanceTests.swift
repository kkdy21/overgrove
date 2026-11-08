import Foundation
import XCTest

@testable import Overgrove

/// FetchFailureGuidance (#78, interaction.md §4.2): what a failed fetch means and what the user can do.
final class FetchFailureGuidanceTests: XCTestCase {
    private let origin = RemoteName("origin")!
    private let secret = "s3" + "cr3t"
    private let clean = RepoSecurityReport(findings: [], blockingReason: nil)
    /// A repository with its own `core.sshCommand`: Terminal git would run it.
    private let risky = RepoSecurityReport(
        findings: [
            RepoSecurityReport.Finding(
                entry: ConfigEntry(
                    scope: .local, section: "core", subsection: nil, variable: "sshcommand", value: "evil"),
                threat: "T5", handling: .neutralized)
        ],
        blockingReason: nil
    )

    private func detail(_ text: String = "fatal: x") -> MaskedText { MaskedText(masking: text) }

    private func guidance(
        _ error: GitError,
        url: String? = nil,
        report: RepoSecurityReport? = nil
    ) throws -> FetchFailureGuidance {
        let endpoint = url.flatMap { FetchFailureGuidance.Endpoint(remoteURL: $0) }
        return try XCTUnwrap(
            FetchFailureGuidance(
                error: error, remote: origin, endpoint: endpoint, report: report ?? clean, hookExecutables: []))
    }

    private var everyError: [GitError] {
        [
            .authenticationFailed(detail: detail()), .sshAuthenticationFailed(detail: detail()),
            .hostKeyVerificationFailed(changed: false, detail: detail()),
            .hostKeyVerificationFailed(changed: true, detail: detail()), .accessDenied(detail: detail()),
            .networkUnavailable(detail: detail()), .timeout(seconds: 120), .remoteNotFound(detail: detail()),
            .transportNotAllowed(transport: "hg", detail: detail()),
            .configInspectionFailed(
                reason: "This repository sets its own TLS certificate files; fetching is disabled."),
            .nonZeroExit(code: 128, detail: detail()), .worktreeMissing(path: "/x"),
        ]
    }

    // MARK: - Categories (interaction.md: authentication, network, timeout, other)

    func testEveryReasonMapsToOneOfTheFourCategories() throws {
        let expected: [(FetchFailureGuidance.Reason, FetchFailureGuidance.Category)] = [
            (.credentialsRejected, .authentication), (.sshKeyRejected, .authentication),
            (.hostKeyNotTrusted, .authentication), (.hostKeyChanged, .authentication),
            (.accessDenied, .authentication), (.hostUnreachable, .network), (.timedOut(seconds: 120), .timeout),
            (.remoteNotFound, .other), (.transportNotAllowed, .other), (.blockedByConfiguration, .other),
            (.unknown, .other), (.unknown, .other),
        ]
        for (error, (reason, category)) in zip(everyError, expected) {
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
        XCTAssertNil(FetchFailureGuidance(error: .cancelled, remote: origin, report: clean, hookExecutables: []))
    }

    // MARK: - Terminal git (security review of #200)

    func testGitCommandsOnlyForACleanRepository() throws {
        for error in everyError {
            let safe = try guidance(error, report: clean)
            if safe.commands.contains(where: { $0.hasPrefix("git ") }) {
                XCTAssertTrue(safe.guidance.contains("only for a repository you trust"), safe.guidance)
            }
            // A hostile repository could fail a fetch on purpose to get its payload pasted into Terminal.
            let hostile = try guidance(error, url: "ssh://git@example.com/o/r.git", report: risky)
            XCTAssertFalse(hostile.commands.contains { $0.hasPrefix("git ") }, "\(error): \(hostile.commands)")
            XCTAssertFalse(hostile.guidance.contains("Run \"git"), hostile.guidance)
        }
        let hostile = try guidance(.authenticationFailed(detail: detail()), report: risky)
        XCTAssertTrue(hostile.guidance.contains("security report"), hostile.guidance)
    }

    /// #354: an executable in the hooks directory, or a config-defined hook, withholds the git command too: Terminal
    /// git would run either (as the slow status hint, #168).
    func testHooksWithholdTheGitCommand() throws {
        let configHook = RepoSecurityReport(
            findings: [
                RepoSecurityReport.Finding(
                    entry: ConfigEntry(
                        scope: .local, section: "hook", subsection: "x", variable: "command", value: "y"),
                    threat: "T2", handling: .neutralized)
            ], blockingReason: nil)
        for error in everyError {
            let hooked = try XCTUnwrap(
                FetchFailureGuidance(error: error, remote: origin, report: clean, hookExecutables: ["hooks/pre-commit"])
            )
            XCTAssertFalse(hooked.commands.contains { $0.hasPrefix("git ") }, "\(error): \(hooked.commands)")
            XCTAssertFalse(hooked.guidance.contains("Run \"git"), hooked.guidance)
            let configured = try guidance(error, report: configHook)
            XCTAssertFalse(configured.commands.contains { $0.hasPrefix("git ") }, "\(error): \(configured.commands)")
        }
        let hooked = try XCTUnwrap(
            FetchFailureGuidance(
                error: .authenticationFailed(detail: detail()), remote: origin, report: clean,
                hookExecutables: ["hooks/pre-commit"]))
        XCTAssertTrue(hooked.guidance.contains("settings or hooks"), hooked.guidance)
    }

    func testOnlyReadOnlyCommandsAreOffered() throws {
        let allowed = ["git fetch origin", "git --no-pager remote -v", "ssh-add -l", "ssh-keyscan", "ssh-keygen -F"]
        for error in everyError {
            for command in try guidance(error, url: "ssh://git@example.com:2222/o/r.git").commands {
                XCTAssertTrue(allowed.contains { command.hasPrefix($0) }, command)
                XCTAssertFalse(command.contains("ssh-keygen -R"), command)
            }
        }
    }

    // MARK: - Texts and commands

    func testAuthentication() throws {
        let result = try guidance(.authenticationFailed(detail: detail()))
        XCTAssertEqual(result.summary, "Authentication failed for origin")
        XCTAssertTrue(result.guidance.contains("does not prompt for passwords"), result.guidance)
        XCTAssertEqual(result.commands, ["git fetch origin"])
        XCTAssertEqual(
            try guidance(.sshAuthenticationFailed(detail: detail())).commands, ["ssh-add -l", "git fetch origin"])
        XCTAssertEqual(try guidance(.sshAuthenticationFailed(detail: detail()), report: risky).commands, ["ssh-add -l"])
    }

    func testHostKeyIsNeverAcceptedOnTheUsersBehalf() throws {
        let unknown = try guidance(
            .hostKeyVerificationFailed(changed: false, detail: detail()), url: "git@example.com:o/r")
        XCTAssertEqual(unknown.summary, "The SSH host key of example.com is not trusted yet")
        XCTAssertTrue(unknown.guidance.contains("fingerprint"), unknown.guidance)
        XCTAssertEqual(unknown.commands, ["ssh-keyscan example.com | ssh-keygen -lf -", "git fetch origin"])

        let changed = try guidance(
            .hostKeyVerificationFailed(changed: true, detail: detail()), url: "git@example.com:o/r")
        XCTAssertEqual(changed.summary, "The SSH host key of example.com has changed")
        XCTAssertTrue(changed.guidance.contains("intercept"), changed.guidance)
        XCTAssertEqual(changed.commands, ["ssh-keygen -F example.com", "ssh-keyscan example.com | ssh-keygen -lf -"])
        XCTAssertEqual(try guidance(.hostKeyVerificationFailed(changed: true, detail: detail())).commands, [])
    }

    func testNonDefaultSSHPort() throws {
        let changed = try guidance(
            .hostKeyVerificationFailed(changed: true, detail: detail()), url: "ssh://git@example.com:2222/o/r.git")
        XCTAssertEqual(
            changed.commands,
            ["ssh-keygen -F '[example.com]:2222'", "ssh-keyscan -p 2222 example.com | ssh-keygen -lf -"]
        )
    }

    func testNetworkNamesTheHostWhenKnown() throws {
        XCTAssertEqual(
            try guidance(.networkUnavailable(detail: detail()), url: "https://github.com/o/r").summary,
            "Could not reach github.com")
        XCTAssertEqual(
            try guidance(.networkUnavailable(detail: detail())).summary, "Could not reach the remote of origin")
    }

    func testTimeoutAndOthers() throws {
        XCTAssertEqual(try guidance(.timeout(seconds: 120)).summary, "Fetch timed out after 120 s")
        XCTAssertEqual(try guidance(.remoteNotFound(detail: detail())).commands, ["git --no-pager remote -v"])
        let transport = try guidance(.transportNotAllowed(transport: "codecommit", detail: detail()))
        XCTAssertTrue(transport.guidance.contains("'codecommit'"), transport.guidance)
        let unknown = try guidance(.nonZeroExit(code: 128, detail: detail("SERVER TEXT")))
        XCTAssertEqual(unknown.summary, "Fetch failed")
        XCTAssertFalse(unknown.guidance.contains("SERVER TEXT"), "the first stderr line is not echoed")
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
        let result = try XCTUnwrap(
            FetchFailureGuidance(error: .timeout(seconds: 120), remote: remote, report: clean, hookExecutables: []))
        XCTAssertEqual(result.commands, ["git fetch team/fork.v2"])
    }

    // MARK: - Details

    func testDetailTailKeepsTheLastLinesOfMaskedStderr() throws {
        let stderr = (1...12).map { "line \($0)" }.joined(separator: "\n") + "\n\n"
        let result = try guidance(.nonZeroExit(code: 1, detail: detail(stderr)))
        XCTAssertEqual(result.detailTail, (8...12).map { "line \($0)" }.joined(separator: "\n"))
        XCTAssertNil(try guidance(.timeout(seconds: 120)).detailTail)
    }

    /// #362: `--progress` rewrites a line with `\r`. Only the last state of each line is kept, as a terminal shows it,
    /// so a server cannot turn one progress line into a long run of escaped segments.
    func testDetailTailKeepsOnlyTheLastStateOfARewrittenLine() throws {
        let stderr =
            "Receiving objects:   1% (1/100)\rReceiving objects:  50% (50/100)\rReceiving objects: 100% (100/100)\r\n"
            + "Resolving deltas: 0%\rResolving deltas: 100%\r\n"
            + "fatal: early EOF\r\n" + "trailing\r"
        let result = try guidance(.nonZeroExit(code: 1, detail: detail(stderr)))
        XCTAssertEqual(
            result.detailTail,
            ["Receiving objects: 100% (100/100)", "Resolving deltas: 100%", "fatal: early EOF", "trailing"]
                .joined(separator: "\n"))
    }

    /// #362: every line is capped, counted in Unicode scalars (a grapheme cluster can be any length).
    func testDetailTailCapsEachLine() throws {
        let cap = FetchFailureGuidance.maximumDetailLineScalars
        let long = String(repeating: "x", count: cap * 4)
        let combining = "a" + String(repeating: "\u{301}", count: cap * 4)
        let result = try guidance(.nonZeroExit(code: 1, detail: detail(long + "\n" + combining + "\nshort")))
        let lines = try XCTUnwrap(result.detailTail).components(separatedBy: "\n")
        XCTAssertEqual(lines.count, 3)
        for line in lines.prefix(2) {
            XCTAssertEqual(line.unicodeScalars.count, cap + 1, "capped, with an ellipsis")
            XCTAssertTrue(line.hasSuffix("…"))
        }
        XCTAssertEqual(lines.last, "short")

        let rewritten = String(repeating: "\(long)\r", count: 50) + "done"
        XCTAssertEqual(try guidance(.nonZeroExit(code: 1, detail: detail(rewritten))).detailTail, "done")
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
        let result = try guidance(error, url: "https://alice:\(secret)@example.com/r.git")
        let everything =
            [result.summary, result.guidance, result.detail?.text ?? "", result.detailTail ?? ""]
            + result.commands
        for text in everything {
            XCTAssertFalse(text.contains(secret), text)
            XCTAssertFalse(text.contains("alice"), text)
        }
        XCTAssertEqual(result.summary, "Could not reach example.com")
    }

    func testEndpointFromRemoteURL() {
        let cases: [(String, String?, Int?)] = [
            ("https://github.com/o/r.git", "github.com", nil),
            ("https://alice:\(secret)@GitHub.com:8443/o/r.git", "GitHub.com", 8443),
            ("https://alice:p@ss@example.com/r", "example.com", nil),
            ("ssh://git@example.com:2222/o/r.git", "example.com", 2222),
            ("ssh://git@example.com:22/o/r.git", "example.com", nil),
            ("git+ssh://example.com/o/r", "example.com", nil),
            ("git://example.com/r", "example.com", nil),
            ("git@github.com:o/r.git", "github.com", nil),
            ("example.com:o/r.git", "example.com", nil),
            // The authority ends at `?` and `#` too, as curl reads it (security review of #200).
            ("https://host.example?x@evil.example/r", "host.example", nil),
            ("https://host.example#@evil.example/", "host.example", nil),
            ("/srv/repos/r.git", nil, nil),
            ("../relative/r.git", nil, nil),
            ("file:///tmp/r", nil, nil),
            ("evilhelper::payload", nil, nil),
            ("https://evil;touch x/r", nil, nil),
            ("https://[::1]/r", nil, nil),
            ("git@-oProxyCommand=x:r", nil, nil),
            ("ssh://example.com:99999/r", nil, nil),
            ("ssh://example.com:2x/r", nil, nil),
            ("", nil, nil),
        ]
        for (url, host, port) in cases {
            let endpoint = FetchFailureGuidance.Endpoint(remoteURL: url)
            XCTAssertEqual(endpoint?.host, host, url)
            XCTAssertEqual(endpoint?.port, port, url)
        }
    }
}
