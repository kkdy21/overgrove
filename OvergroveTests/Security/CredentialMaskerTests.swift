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

    func testMasksInvalidUTF8Bytes() {
        var bytes = Data("https://u:\(secret)@h/".utf8)
        bytes.append(0xFF)
        XCTAssertFalse(CredentialMasker.mask(bytes).contains(secret))
    }
}
