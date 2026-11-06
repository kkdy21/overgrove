import Foundation
import XCTest

@testable import Overgrove

/// SEC-T11-01: credentials never survive `CredentialMasker.mask` (docs/design/security-review.md T11).
final class CredentialMaskerTests: XCTestCase {
    // Token-shaped strings are assembled at runtime so the source never contains one (gitleaks, push protection).
    private let classicToken = "gh" + "p_" + String(repeating: "Ab1", count: 12)
    private let fineGrainedToken = "github" + "_pat_" + String(repeating: "Cd2_", count: 10)
    private let secret = "s3" + "cr3t-value"

    func testSECT11_01_URLUserinfoIsMasked() {
        XCTAssertEqual(
            CredentialMasker.mask("https://alice:\(secret)@github.com/org/repo.git"),
            "https://***@github.com/org/repo.git"
        )
        XCTAssertEqual(
            CredentialMasker.mask("https://\(classicToken)@github.com/org/repo.git"),
            "https://***@github.com/org/repo.git"
        )
        XCTAssertEqual(
            CredentialMasker.mask("ssh://git:\(secret)@example.com:2222/repo"),
            "ssh://***@example.com:2222/repo"
        )
        XCTAssertEqual(
            CredentialMasker.mask("https://user:p@ss@host.example/path"),
            "https://***@host.example/path",
            "an unescaped @ in the password must not leak the rest"
        )
    }

    func testSECT11_01_GitStderrIsMasked() {
        let stderr = """
            fatal: unable to access 'https://x-access-token:\(classicToken)@github.com/org/repo.git/': \
            The requested URL returned error: 403
            """
        let masked = CredentialMasker.mask(stderr)
        XCTAssertFalse(masked.contains(classicToken))
        XCTAssertFalse(masked.contains("x-access-token"))
        XCTAssertTrue(masked.contains("https://***@github.com/org/repo.git/"))
    }

    func testSECT11_01_TokenQueryParametersAreMasked() {
        XCTAssertEqual(
            CredentialMasker.mask("https://host/repo.git?access_token=\(secret)&ref=main"),
            "https://host/repo.git?access_token=***&ref=main"
        )
        XCTAssertEqual(CredentialMasker.mask("GET /a?TOKEN=\(secret)"), "GET /a?TOKEN=***")
    }

    func testSECT11_01_BareGitHubTokensAreMasked() {
        XCTAssertEqual(CredentialMasker.mask("token is \(classicToken) ok"), "token is *** ok")
        XCTAssertEqual(CredentialMasker.mask("pat=\(fineGrainedToken)"), "pat=***")
        for prefix in ["gho", "ghu", "ghs", "ghr"] {
            let token = prefix + "_" + String(repeating: "Zz9", count: 12)
            XCTAssertEqual(CredentialMasker.mask(token), "***", prefix)
        }
    }

    func testSECT11_01_AuthorizationHeadersAreMasked() {
        let trace =
            "> GET /info/refs HTTP/1.1\n> Authorization: Bearer \(secret)\n> proxy-authorization: Basic \(secret)"
        let masked = CredentialMasker.mask(trace)
        XCTAssertFalse(masked.contains(secret))
        XCTAssertTrue(masked.contains("> Authorization: ***"))
        XCTAssertTrue(masked.contains("> proxy-authorization: ***"))
    }

    func testSafeTextIsUnchanged() {
        let samples = [
            "https://github.com/kkdy21/overgrove.git",
            "git@github.com:kkdy21/overgrove.git",
            "fatal: repository 'https://example.com/r.git/' not found",
            "Merge branch 'feat/12-x' into main",
            "tokenizer: split ghp tokens",
        ]
        for sample in samples {
            XCTAssertEqual(CredentialMasker.mask(sample), sample)
        }
    }

    func testMaskingIsIdempotent() {
        let once = CredentialMasker.mask("https://a:\(secret)@h/r?token=\(secret) \(classicToken)")
        XCTAssertEqual(CredentialMasker.mask(once), once)
    }

    func testAdversarialInputIsMaskedInLinearTime() {
        // #143: the old URL pattern backtracked quadratically (32 KB took 14 s). stderr can carry remote-controlled
        // text up to 256 KB, so every rule must stay linear.
        let size = 256 * 1024
        let inputs = [
            String(repeating: "y", count: size),
            String(repeating: "a://", count: size / 4),
            String(repeating: "https://x", count: size / 9),
            "https://" + String(repeating: "u", count: size) + "@",
            String(repeating: "?token=", count: size / 7),
            String(repeating: "gh" + "p_", count: size / 4),
            String(repeating: "authorization", count: size / 13),
        ]
        let clock = ContinuousClock()
        for input in inputs {
            let start = clock.now
            _ = CredentialMasker.mask(input)
            XCTAssertLessThan(clock.now - start, .seconds(1), "input starting with \(input.prefix(12))")
        }
    }

    func testUserinfoEdgeCases() {
        XCTAssertEqual(CredentialMasker.mask("a://b@c a://d"), "a://***@c a://d")
        XCTAssertEqual(CredentialMasker.mask("'https://t@h/x' and https://h2/y"), "'https://***@h/x' and https://h2/y")
        XCTAssertEqual(CredentialMasker.mask("https://@host/"), "https://@host/", "empty userinfo has nothing to hide")
        XCTAssertEqual(CredentialMasker.mask("see https://u:p@h"), "see https://***@h")
        XCTAssertEqual(CredentialMasker.mask("x://y://u@h"), "x://y://***@h", "resumes at the inner scheme")
    }

    func testMasksInvalidUTF8Bytes() {
        var bytes = Data("https://u:\(secret)@h/".utf8)
        bytes.append(0xFF)
        XCTAssertFalse(CredentialMasker.mask(bytes).contains(secret))
    }
}
