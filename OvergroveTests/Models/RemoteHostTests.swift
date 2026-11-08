import XCTest

@testable import Overgrove

/// Provider-independent remote host reading and trust (ADR-0025 §1–§2), shared by GitHub and later providers.
final class RemoteHostTests: XCTestCase {
    /// SEC-T9-08 (host): only a lowercase ASCII DNS name with two or more labels; no IP literal, userinfo, port,
    /// path, or non-ASCII byte.
    func testSECT9_08_HostIsADNSName() {
        XCTAssertEqual(RemoteHost("GHE.Example.COM")?.name, "ghe.example.com")
        XCTAssertEqual(RemoteHost("a-1.b2.example")?.name, "a-1.b2.example")
        XCTAssertNotNil(RemoteHost(String(repeating: "a", count: 63) + ".example"))
        let longest = Array(repeating: String(repeating: "a", count: 62), count: 4).joined(separator: ".") + ".a"
        XCTAssertEqual(longest.utf8.count, 253)
        XCTAssertNotNil(RemoteHost(longest))
        for raw in [
            "", "localhost", "example.", ".example", "a..example", "-a.example", "a-.example",
            String(repeating: "a", count: 64) + ".example", longest + "a", "127.0.0.1", "10.0.0.256", "[::1]",
            "::1", "user@ghe.example", "ghe.example:443", "ghe.example/x", "ghe.example?x", "ghe_x.example",
            "gh\u{0435}.example", "ghe.example\u{0}", "ghe.example\n", " ghe.example", "ghe.\u{202E}example",
        ] {
            XCTAssertNil(RemoteHost(raw), raw)
        }
    }

    func testThreeRemoteFormsGiveHostAndPath() {
        for (url, host, path) in [
            ("https://ghe.example/team/app.git", "ghe.example", ["team", "app"]),
            ("https://GHE.example/team/app", "ghe.example", ["team", "app"]),
            ("git@ghe.example:team/app.git", "ghe.example", ["team", "app"]),
            ("ssh://git@ghe.example/team/app", "ghe.example", ["team", "app"]),
            ("ssh://git@ghe.example:2222/team/app.git", "ghe.example", ["team", "app"]),
            ("https://gitlab.example/group/sub/app.git", "gitlab.example", ["group", "sub", "app"]),
        ] {
            let remote = HostedRemoteURL(url)
            XCTAssertEqual(remote?.host.name, host, url)
            XCTAssertEqual(remote?.pathSegments, path, url)
        }
    }

    /// SEC-T9-08 (URL): anything outside the three forms, or a host that is not a DNS name, is not a hosted remote.
    func testSECT9_08_OtherURLsAreNotHostedRemotes() {
        for url in [
            "", "http://ghe.example/o/r", "https://ghe.example", "https://ghe.example/", "https://ghe.example/o//r",
            "https://ghe.example/o/r/", "https://user@ghe.example/o/r", "https://u:p@ghe.example/o/r",
            "https://ghe.example:8443/o/r", "https://127.0.0.1/o/r", "https://[::1]/o/r", "git@ghe.example/o/r",
            "git@127.0.0.1:o/r", "me@ghe.example:o/r", "ssh://ghe.example/o/r", "ssh://me@ghe.example/o/r",
            "ssh://git@ghe.example:0/o/r", "ssh://git@ghe.example:65536/o/r", "ssh://git@ghe.example:x/o/r",
            "ssh://git@ghe.example:/o/r", "ext::ssh ghe.example", "file:///srv/o/r", "~/dev/o/r",
            "https://ghe.example\u{301}/o/r", "https://ghe.example/.git",
        ] {
            XCTAssertNil(HostedRemoteURL(url), url)
        }
    }

    /// ADR-0025 §1: the public host always, other hosts only once the CLI reports a login for them.
    func testTrustedHostsComeFromTheLoginList() throws {
        let github = try XCTUnwrap(RemoteHost("github.com"))
        let ghe = try XCTUnwrap(RemoteHost("ghe.example"))
        let before = TrustedHosts(publicHost: github)
        XCTAssertTrue(before.contains(github))
        XCTAssertFalse(before.contains(ghe))
        XCTAssertTrue(before.mayTrustMore(["git@ghe.example:o/r.git"]))
        XCTAssertFalse(before.mayTrustMore(["https://github.com/o/r", "https://localhost/o/r", "~/dev/o/r"]))
        let after = TrustedHosts(publicHost: github, loggedIn: [ghe])
        XCTAssertTrue(after.contains(ghe))
        XCTAssertFalse(after.contains(try XCTUnwrap(RemoteHost("other.example"))))
        XCTAssertFalse(after.mayTrustMore(["https://other.example/o/r"]), "the list was read: nothing more to learn")
    }
}
