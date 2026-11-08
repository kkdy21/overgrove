import Foundation
import XCTest

@testable import Overgrove

/// T11 credential exposure and TLS downgrade on the app's real path (security-review.md §2 T11, #93).
///
/// Elsewhere: SEC-T11-01 `CredentialMaskerTests`, SEC-T11-02 `FetchFailureGuidanceTests`/`FetchFailureTests`,
/// SEC-T11-03 unit `RepoConfigInspectorTests`, SEC-T11-05 `GHClientTests`.
final class SECT11CredentialTests: XCTestCase {
    // MARK: - SEC-T11-03

    /// A repository that turns TLS verification off, generically and per URL, gets it back on for fetch. Checked with
    /// git's own URL matching on the exact arguments `GitClient.fetch` uses.
    func testSECT11_03_LocalSSLVerifyFalseIsTrueForFetch() async throws {
        let repository = try await GitTestRepository.make()
        defer { repository.remove() }
        try await repository.git(["config", "http.sslVerify", "false"])
        try await repository.git(["config", "http.https://example.com/.sslVerify", "0"])
        let client = GitClient(environment: repository.environment)
        let listing = try await client.run(.configList, in: repository.root, safety: .preInspection)
        let safety = try XCTUnwrap(RepoConfigInspector.inspect(try ConfigParser.parse(listing.stdout)).safetyContext)

        func effectiveSSLVerify(fetchAuthentication: [String]) async throws -> String {
            let arguments = repository.environment.arguments(
                for: ["config", "--type=bool", "--get-urlmatch", "http.sslverify", "https://example.com/o/r.git"],
                neutralization: safety.neutralization,
                fetchAuthentication: fetchAuthentication
            )
            let result = try await ProcessRunner().run(
                ProcessRequest(
                    executable: repository.environment.executable, arguments: arguments,
                    environment: GitEnvironment.environment(parent: [:]), currentDirectory: repository.root,
                    limits: .query))
            return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let restored = try await effectiveSSLVerify(fetchAuthentication: safety.fetchAuthentication)
        XCTAssertEqual(restored, "true", "fetch arguments: \(safety.fetchAuthentication)")
        let unrestored = try await effectiveSSLVerify(fetchAuthentication: [])
        XCTAssertEqual(unrestored, "false", "control: the repository really turns verification off")
    }

    // MARK: - SEC-T11-04

    /// The fixture's `mirror` remote carries a user name and password in its URL (fixtures.md §3). What the UI shows
    /// (S-05 remote list, status bar, fetch guidance) is masked; the raw URL stays inside the inspection. The screens
    /// themselves do not exist yet, so this checks the model they will render.
    func testSECT11_04_RemoteURLShownWithoutCredentials() async throws {
        let fixture = try await makeFixture()
        let environment = try await GitEnvironment.discoverForTesting()
        let client = GitClient(environment: environment, parentEnvironment: fixture.environment)
        let listing = try await client.run(.configList, in: fixture.repository, safety: .preInspection)
        let inspection = RepoConfigInspector.inspect(try ConfigParser.parse(listing.stdout))

        let mirror = try XCTUnwrap(inspection.remotes.first { $0.name.value == "mirror" })
        let rawUserInfo = try XCTUnwrap(
            URLComponents(string: mirror.url).flatMap { components in
                components.password.map { "\(components.user ?? ""):\($0)" }
            },
            "the fixture's mirror URL must contain credentials, or this test proves nothing"
        )
        XCTAssertFalse(mirror.displayURL.contains(rawUserInfo), mirror.displayURL)
        XCTAssertTrue(mirror.displayURL.hasPrefix("https://***@example.invalid/"), mirror.displayURL)
        for remote in inspection.remotes {
            XCTAssertNil(URLComponents(string: remote.displayURL)?.password, remote.displayURL)
        }
        let endpoint = FetchFailureGuidance.Endpoint(remoteURL: mirror.url)
        XCTAssertEqual(endpoint?.host, "example.invalid", "guidance names the host only")
    }

    // MARK: - SEC-T11-12

    /// #375: `MaskedText` drops control and format characters (`Cc`, `Cf`) for display. A token split by them must not
    /// come back together unmasked once they are gone: an ANSI escape, DEL, a zero-width space or joiner, a BOM, a
    /// backspace, and a bidi mark, inside a GitHub token, inside URL userinfo, and inside schemeless userinfo.
    func testSECT11_12_TokensSplitByStrippedCharactersStayMasked() {
        let token = "ghp_" + String(repeating: "A", count: 12) + "BBBBBBBBBBBB"
        let secret = "s3cretPassw0rd"
        for separator in ["\u{1B}", "\u{7F}", "\u{200B}", "\u{200D}", "\u{FEFF}", "\u{08}", "\u{202E}", "\u{0}"] {
            let splitToken = String(token.prefix(10)) + separator + String(token.dropFirst(10))
            let splitURL =
                "https://alice:" + String(secret.prefix(5)) + separator + String(secret.dropFirst(5))
                + "@git.example.invalid/o/r.git"
            let splitHost = "alice" + separator + ":" + secret + "@git.example.invalid:o/r.git"
            let splitScheme = "https" + separator + "://alice:" + secret + "@git.example.invalid/o/r.git"
            let raw =
                "fatal: \(splitToken)\nfatal: unable to access '\(splitURL)'\nfatal: \(splitHost)\n\(splitScheme)\n"
            let shown = MaskedText(masking: raw).text
            let label = String(separator.unicodeScalars.first!.value, radix: 16)
            XCTAssertFalse(shown.contains(token), "U+\(label): token rejoined in \(shown.debugDescription)")
            XCTAssertFalse(shown.contains(secret), "U+\(label): password rejoined in \(shown.debugDescription)")
            XCTAssertTrue(shown.contains("***"), "U+\(label): something is masked")
        }
    }

    /// SEC-T11-12: characters that end a match for the first pass and are then dropped (VT, FF), and the other masked
    /// forms split by a dropped character. Each of these showed the secret before #375 (security review).
    func testSECT11_12_SplitsThatEndedAMatchStayMasked() {
        let secret = "s3cretPassw0rd"
        let patToken = "github_pat_" + String(repeating: "D", count: 24)
        for separator in ["\u{0B}", "\u{0C}"] {
            let raw =
                "fatal: unable to access 'https://alice:\(secret.prefix(5))\(separator)\(secret.dropFirst(5))"
                + "@git.example.invalid/o/r.git'\n"
            XCTAssertFalse(MaskedText(masking: raw).text.contains(secret), separator.debugDescription)
        }
        let others = [
            ("Authori\u{200B}zation: Basic \(secret)\n", secret),
            ("GET /o/r.git?access\u{0}_token=\(secret) HTTP/1.1\n", secret),
            ("fatal: \(patToken.prefix(13))\u{200B}\(patToken.dropFirst(13))\n", patToken),
        ]
        for (raw, hidden) in others {
            XCTAssertFalse(MaskedText(masking: raw).text.contains(hidden), raw.debugDescription)
        }
    }

    /// SEC-T11-12: characters that render as nothing but are not control or format characters (variation selectors,
    /// CGJ, Khmer inherent vowels, Hangul fillers, unassigned default-ignorables) are dropped too, so a token they split
    /// does not look whole on screen while the pattern misses it.
    func testSECT11_12_InvisibleNonFormatSplitsStayMasked() {
        let token = "ghp_" + String(repeating: "E", count: 24)
        for separator in [
            "\u{FE0F}", "\u{034F}", "\u{17B4}", "\u{E0100}", "\u{3164}", "\u{115F}", "\u{FFA0}", "\u{E0080}",
        ] {
            let shown = MaskedText(masking: "fatal: \(token.prefix(10))\(separator)\(token.dropFirst(10))\n").text
            XCTAssertFalse(shown.contains(token.dropFirst(10)), separator.debugDescription)
            XCTAssertFalse(shown.unicodeScalars.contains { $0 == separator.unicodeScalars.first! })
        }
    }

    /// SEC-T11-12: Korean file names (NFC and the decomposed form macOS uses) reach the error detail unchanged. A
    /// Hangul filler is default-ignorable and drawn as nothing, so it is dropped like the other invisible characters.
    func testSECT11_12_KoreanFileNamesAreKept() {
        let composed = "보고서.txt"
        let decomposed = composed.decomposedStringWithCanonicalMapping
        let shown = MaskedText(masking: "error: \(composed) \(decomposed) a\u{3164}.txt\n").text
        XCTAssertEqual(shown, "error: \(composed) \(decomposed) a.txt\n")
    }

    /// SEC-T11-12: a split token that straddles the length limit is masked before the limit cuts it.
    func testSECT11_12_SplitTokenAtTheLengthLimitIsMaskedBeforeTheCut() {
        let token = "ghp_" + String(repeating: "F", count: 24)
        let filler = String(repeating: "x", count: MaskedText.maximumLength - 8) + " "
        let shown = MaskedText(masking: filler + token.prefix(6) + "\u{0}" + token.dropFirst(6)).text
        XCTAssertFalse(shown.hasSuffix(String(token.prefix(7))), String(shown.suffix(12)))
        XCTAssertTrue(shown.contains("***"))
    }

    /// SEC-T11-12 (pins behaviour that already held before #375): a carriage return rewrites the line, as a terminal
    /// shows it. The token pieces on either side never end up on one line, and a token written whole after the rewrite
    /// is masked.
    func testSECT11_12_CarriageReturnsDoNotRejoinTokens() {
        let token = "ghp_" + String(repeating: "C", count: 24)
        let shown = MaskedText(masking: "remote: \(token.prefix(8))\r\(token.dropFirst(8))\nremote: \(token)\r\n").text
        XCTAssertFalse(shown.contains(token), shown.debugDescription)
        // The ANSI color form git and servers use: ESC is dropped, the rest of the sequence stays as text.
        let colored = MaskedText(masking: "remote: \(token.prefix(8))\u{1B}[0m\u{1B}\(token.dropFirst(8))\n").text
        XCTAssertFalse(colored.contains(token), colored.debugDescription)
    }
}
