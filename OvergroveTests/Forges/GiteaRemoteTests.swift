import XCTest

@testable import Overgrove

/// Which Gitea repository a remote names, on instances gt has credentials for, and which issue links open
/// (ADR-0026 §2, §5).
final class GiteaRemoteTests: XCTestCase {
    private let plain = GiteaInstance("https://git.example.com")!
    private let based = GiteaInstance("https://code.example.org/gitea")!
    private let ported = GiteaInstance("https://code.example.org:8443")!

    /// SEC-T9-449-3: the three remote forms match an instance by host and base path, https remotes also by port;
    /// `--host` stays the instance URL gt printed.
    func testSECT9_449_3_RemotesMatchOnlyCredentialedInstances() throws {
        for (url, expected) in [
            ("https://git.example.com/acme/widgets.git", "https://git.example.com/acme/widgets"),
            ("git@git.example.com:acme/widgets.git", "https://git.example.com/acme/widgets"),
            ("ssh://git@git.example.com:2222/acme/widgets", "https://git.example.com/acme/widgets"),
            ("https://code.example.org/gitea/o/r", "https://code.example.org/gitea/o/r"),
            ("git@code.example.org:o/r.git", "https://code.example.org:8443/o/r"),
        ] {
            let repository = GiteaRemote.repository(fromURL: url, instances: [plain, based, ported])
            XCTAssertEqual(repository?.description, expected, url)
        }
        XCTAssertEqual(
            GiteaRemote.repository(fromURL: "git@git.example.com:acme/widgets", instances: [plain])?.instance.url,
            "https://git.example.com")
        for url in [
            "https://other.example.com/acme/widgets", "https://git.example.com/acme",
            "https://git.example.com/acme/widgets/extra", "https://git.example.com/-acme/widgets",
            "https://git.example.com/acme/widgets.git.git", "https://code.example.org/o/r",
            "https://code.example.org/other/o/r", "https://127.0.0.1/acme/widgets", "~/dev/acme/widgets",
            "https://git.example.com/" + String(repeating: "a", count: 41) + "/r",
        ] {
            XCTAssertNil(GiteaRemote.repository(fromURL: url, instances: [plain, based]), url)
        }
        XCTAssertNil(GiteaRemote.repository(fromURL: "https://git.example.com/acme/widgets", instances: []))
    }

    func testUpstreamFirstThenConfigurationOrder() {
        let remotes = [
            (name: "origin", url: "https://git.example.com/me/widgets"),
            (name: "upstream", url: "https://git.example.com/acme/widgets"),
        ]
        XCTAssertEqual(GiteaRemote.repository(remotes: remotes, instances: [plain])?.slug, "acme/widgets")
        XCTAssertEqual(
            GiteaRemote.repository(
                remotes: [(name: "b", url: "https://elsewhere.example/x/y"), (name: "a", url: remotes[0].url)],
                instances: [plain])?.slug, "me/widgets")
    }

    /// SEC-T9-449-4: Open in Browser only for this repository's issue page with this number on the instance's host,
    /// port, and base path, over https.
    func testSECT9_449_4_OnlyThisRepositorysIssuePageOpens() throws {
        func issue(_ url: String) -> Issue { IssueModelsTests.issue(7, url: url) }
        let repository = try XCTUnwrap(GiteaRepository(instance: based, owner: "acme", name: "widgets"))
        XCTAssertNotNil(repository.browserURL(for: issue("https://code.example.org/gitea/ACME/Widgets/issues/7")))
        for url in [
            "https://code.example.org/acme/widgets/issues/7", "https://code.example.org/gitea/acme/widgets/issues/8",
            "http://code.example.org/gitea/acme/widgets/issues/7",
            "https://code.example.org:8443/gitea/acme/widgets/issues/7",
            "https://code.example.org/gitea/acme/widgets/pulls/7",
            "https://code.example.org/gitea/acme/widgets/issues/7?x=1",
            "https://user@code.example.org/gitea/acme/widgets/issues/7",
            "https://code.example.org/gitea/other/widgets/issues/7", "https://evil.example/gitea/acme/widgets/issues/7",
            "https://code.example.org/gitea/acme/widgets/issues/07",
        ] {
            XCTAssertNil(repository.browserURL(for: issue(url)), url)
        }
        let root = try XCTUnwrap(GiteaRepository(instance: ported, owner: "o", name: "r"))
        XCTAssertNotNil(root.browserURL(for: issue("https://code.example.org:8443/o/r/issues/7")))
        XCTAssertNil(root.browserURL(for: issue("https://code.example.org/o/r/issues/7")))
    }

    /// The instance host is the shared `RemoteHost` rule, and must already be lowercase as gt prints it.
    func testInstanceHostUsesTheSharedRule() {
        XCTAssertEqual(GiteaInstance("https://git.example.com")?.host.name, "git.example.com")
        for text in ["https://Git.example.com", "https://1.2.3.0x4", "https://git.1a", "https://localhost"] {
            XCTAssertNil(GiteaInstance(text), text)
        }
    }
}
