import Foundation
import XCTest

@testable import Overgrove

/// Picking GitLab projects from remotes and the issue page rule (ADR-0026 §2, §5).
final class GitLabRemoteTests: XCTestCase {
    private func remotes(_ pairs: [(String, String)]) -> [(name: String, url: String)] {
        pairs.map { (name: $0.0, url: $0.1) }
    }

    func testCandidatesFollowGhsOrderOneProjectPerHost() {
        let found = GitLabRemote.candidates(
            remotes: remotes([
                ("origin", "git@gitlab.example.com:me/app.git"),
                ("upstream", "https://gitlab.example.com/group/sub/app.git"),
                ("mirror", "ssh://git@code.example.org:2222/team/app"),
                ("gh", "https://github.com/team/app"),
                ("local", "~/dev/app"),
            ]), excluding: GitHubRemote.publicOnly)
        XCTAssertEqual(found.map(\.description), ["gitlab.example.com/group/sub/app", "code.example.org/team/app"])
    }

    func testHostsGhHandlesAreSkippedAndAtMostThreeHostsAreAsked() {
        let trusted = TrustedHosts(publicHost: GitHubRepository.publicHost, loggedIn: [RemoteHost("ghe.example")!])
        let found = GitLabRemote.candidates(
            remotes: remotes(
                [("a", "https://ghe.example/team/app")]
                    + (1...5).map { ("r\($0)", "https://h\($0).example.com/group/app") }), excluding: trusted)
        XCTAssertEqual(found.map(\.host.name), ["h1.example.com", "h2.example.com", "h3.example.com"])
        XCTAssertEqual(GitLabRemote.maximumHosts, 3)
    }

    func testRemotesThatCannotBeAProjectAreNotCandidates() {
        for url in [
            "https://gitlab.example.com/app", "https://10.0.0.1/group/app", "https://user@gitlab.example.com/g/app",
            "https://gitlab.example.com/-group/app", "https://gitlab.example.com/g/../app", "file:///tmp/g/app",
            "https://gitlab.example.com/g//app",
        ] {
            XCTAssertNil(GitLabRemote.project(fromURL: url), url)
        }
    }

    func testUntrustedHostIsTheFirstHostedRemoteNoCliHandles() {
        XCTAssertEqual(
            GitLabRemote.untrustedHost(
                remotes: remotes([("origin", "https://github.com/team/app"), ("work", "git@git.example.com:team/app")]),
                excluding: GitHubRemote.publicOnly)?.name, "git.example.com")
        XCTAssertNil(
            GitLabRemote.untrustedHost(
                remotes: remotes([("origin", "https://github.com/team/app"), ("l", "~/dev/app")]),
                excluding: GitHubRemote.publicOnly))
    }

    /// SEC-T14-154-1: only this project's issue page on its host opens; anything else is Copy URL only.
    func testSECT14_154_1_OnlyThisProjectsIssuePageOpens() {
        let project = GitLabProject(host: RemoteHost("gitlab.example.com")!, namespace: ["group", "sub"], name: "app")!
        func issue(_ url: String, number: Int = 7) -> Issue {
            Issue(
                number: number, title: "t", state: .open, labels: [], assignees: [], updatedAt: Date(),
                url: URL(string: url)!)
        }
        for url in [
            "https://gitlab.example.com/group/sub/app/-/issues/7",
            "https://gitlab.example.com/group/sub/app/-/work_items/7",
            "https://gitlab.example.com/Group/Sub/App/-/issues/7",
        ] {
            XCTAssertNotNil(GitLabRemote.issueURL(for: issue(url), in: project), url)
            XCTAssertNotNil(IssueSource.gitlab(project).browserURL(for: issue(url)), url)
        }
        for url in [
            "http://gitlab.example.com/group/sub/app/-/issues/7", "https://gitlab.example.com/group/sub/app/-/issues/8",
            "https://gitlab.example.com/group/other/-/issues/7", "https://gitlab.example.com/group/sub/app/issues/7",
            "https://evil.example/group/sub/app/-/issues/7", "https://gitlab.example.com:8443/group/sub/app/-/issues/7",
            "https://u@gitlab.example.com/group/sub/app/-/issues/7",
            "https://gitlab.example.com/group/sub/app/-/issues/7?x",
            "https://gitlab.example.com/group/sub/app/-/issues/7#n",
            "https://gitlab.example.com/group/sub/app/-/merge_requests/7",
            "https://gitlab.example.com/group/sub/app/-/issues/7/x",
        ] {
            XCTAssertNil(GitLabRemote.issueURL(for: issue(url), in: project), url)
        }
    }

    func testSourceNamesForDisplayAndReferences() {
        let project = GitLabProject(host: RemoteHost("gitlab.example.com")!, namespace: ["group"], name: "app")!
        XCTAssertEqual(IssueSource.gitlab(project).slug, "gitlab.example.com/group/app")
        XCTAssertEqual(IssueSource.gitlab(project).referencePath, "group/app")
        XCTAssertNil(IssueSource.gitlab(project).gitHubRepository)
    }
}
