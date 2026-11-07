import XCTest

@testable import Overgrove

/// Which github.com repository the issue panel reads (git-command-catalog.md §5, #81).
final class GitHubRemoteTests: XCTestCase {
    func testAcceptsTheThreeGitHubURLForms() {
        for url in [
            "https://github.com/kkdy21/overgrove", "https://github.com/kkdy21/overgrove.git",
            "git@github.com:kkdy21/overgrove.git", "git@github.com:kkdy21/overgrove",
            "ssh://git@github.com/kkdy21/overgrove.git",
        ] {
            XCTAssertEqual(GitHubRemote.repository(fromURL: url)?.slug, "kkdy21/overgrove", url)
        }
    }

    /// SEC-T9-05: a repository's remote URL decides gh's `--repo` value, so only `OWNER/NAME` from the three
    /// github.com forms passes: no option-like owner, non-ASCII, userinfo, port, other host, or extra path.
    func testRejectsEverythingElse() {
        for url in [
            "", "http://github.com/o/r", "https://github.com/o", "https://github.com/o/r/", "https://github.com/o/r/x",
            "https://github.com//r", "https://user@github.com/o/r", "https://github.com:443/o/r",
            "https://github.com.evil.example/o/r", "https://GITHUB.COM/o/r", "git@github.com:/o/r",
            "git@gitlab.com:o/r.git", "ssh://github.com/o/r", "https://github.com/-o/r", "https://github.com/o/..",
            "https://github.com/o/r?x=1", "https://github.com/\u{301}o/r", "file:///srv/o/r", "~/dev/o/r",
            "https://github.com/o/r.git.git",
        ] {
            XCTAssertNil(GitHubRemote.repository(fromURL: url), url)
        }
    }

    func testPrefersUpstreamThenGitHubThenOriginThenConfigOrder() {
        func remotes(_ pairs: [(String, String)]) -> [(name: String, url: String)] {
            pairs.map { (name: $0.0, url: $0.1) }
        }
        let fork = remotes([
            ("origin", "git@github.com:me/app.git"), ("upstream", "https://github.com/team/app.git"),
        ])
        XCTAssertEqual(GitHubRemote.repository(remotes: fork)?.slug, "team/app")
        let hosted = remotes([("origin", "git@github.com:me/app.git"), ("github", "git@github.com:org/app.git")])
        XCTAssertEqual(GitHubRemote.repository(remotes: hosted)?.slug, "org/app")
        // A non-GitHub `upstream` is skipped.
        let mixed = remotes([
            ("upstream", "git@gitlab.com:team/app.git"), ("mirror", "git@github.com:mirror/app.git"),
            ("origin", "https://github.com/me/app"),
        ])
        XCTAssertEqual(GitHubRemote.repository(remotes: mixed)?.slug, "me/app")
        let other = remotes([("b", "https://example.com/x"), ("a", "git@github.com:a/app.git")])
        XCTAssertEqual(GitHubRemote.repository(remotes: other)?.slug, "a/app")
        XCTAssertNil(GitHubRemote.repository(remotes: remotes([("origin", "https://example.com/o/r")])))
    }
}
