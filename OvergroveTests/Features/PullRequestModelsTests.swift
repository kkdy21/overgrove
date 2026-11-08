import Foundation
import XCTest

@testable import Overgrove

/// PR pill and S-05 card (ADR-0023 §3, §5), and the display half of SEC-T9-07.
final class PullRequestModelsTests: XCTestCase {
    private let repository = GitHubRepository(owner: "team", name: "app")!

    private func pullRequest(
        _ number: Int = 5, state: PullRequest.State = .open, isDraft: Bool = false, title: String = "feat: x",
        review: PullRequest.ReviewDecision = .none, base: String = "main", url: String? = nil
    ) -> PullRequest {
        PullRequest(
            number: number, title: title, state: state, isDraft: isDraft,
            head: PullRequest.Head(owner: "team", name: "app", branch: "feat/x"), baseRefName: base,
            reviewDecision: review, updatedAt: nil,
            url: URL(string: url ?? "https://github.com/team/app/pull/\(number)")!)
    }

    func testBadgeStates() {
        let cases: [(PullRequest.State, Bool, String, String, Bool)] = [
            (.open, false, "Open", "arrow.triangle.pull", false),
            (.open, true, "Draft", "arrow.triangle.pull", true),
            (.merged, false, "Merged", "checkmark.circle", false),
            (.closed, true, "Closed", "xmark.circle", false),
            (.unknown, false, "Unknown state", "questionmark.circle", false),
        ]
        for (state, draft, text, symbol, dashed) in cases {
            let badge = PullRequestBadge(pullRequest(state: state, isDraft: draft))
            XCTAssertEqual(badge.stateText, text)
            XCTAssertEqual(badge.symbol, symbol)
            XCTAssertEqual(badge.isDraft, dashed)
            XCTAssertEqual(badge.text, "#5")
        }
        XCTAssertEqual(PullRequestBadge(pullRequest(isDraft: true)).accessibilityText, "pull request 5, draft")
    }

    func testCard() {
        let card = PullRequestCardModel(
            pullRequest(review: .changesRequested, base: "release/1.0"), repository: repository)
        XCTAssertEqual(card.review, "Changes requested")
        XCTAssertEqual(card.base, "release/1.0")
        XCTAssertEqual(card.browserURL?.absoluteString, "https://github.com/team/app/pull/5")
        XCTAssertNil(PullRequestCardModel(pullRequest(base: ""), repository: repository).base)
        XCTAssertNil(PullRequestCardModel(pullRequest(), repository: repository).review)
        XCTAssertEqual(PullRequestCardModel(pullRequest(review: .approved), repository: repository).review, "Approved")
        XCTAssertEqual(
            PullRequestCardModel(pullRequest(review: .reviewRequired), repository: repository).review, "Review required"
        )
    }

    /// SEC-T9-07 (display): titles, branch names, and URLs are escaped before they are shown.
    func testSECT9_07_TextIsEscaped() {
        let card = PullRequestCardModel(
            pullRequest(title: "evil\u{202E}gpj.exe\u{7}\nsecond", base: "ma\u{202E}in"), repository: repository)
        for text in [card.title, card.base ?? "", card.badge.help] {
            XCTAssertFalse(text.unicodeScalars.contains { $0 == "\u{202E}" || $0 == "\u{7}" || $0 == "\n" }, text)
        }
    }

    /// SEC-T9-07 (display): Open in Browser only for this repository's page for this number, over https on
    /// github.com; OWNER and NAME ignore ASCII case. Anything else leaves only Copy URL.
    func testSECT9_07_OnlyThisRepositorysPullRequestPageOpens() {
        XCTAssertNotNil(
            PullRequestCardModel(pullRequest(url: "https://github.com/TEAM/App/pull/5"), repository: repository)
                .browserURL)
        for url in [
            "https://github.com/other/app/pull/5", "https://github.com/team/app/pull/6",
            "https://github.com/team/app/issues/5", "https://github.com/team/app/pull/5/files",
            "https://github.com/team/app/pull/5?x=1", "https://github.com/team/app/pull/5#y",
            "https://user@github.com/team/app/pull/5", "https://github.com:444/team/app/pull/5",
            "https://github.com/team/%61pp/pull/5", "https://github.com/team/app/pull/05",
        ] {
            XCTAssertNil(
                PullRequestCardModel(pullRequest(url: url), repository: repository).browserURL, url)
        }
        XCTAssertNil(PullRequestCardModel(pullRequest(), repository: nil).browserURL)
    }

    func testBadgeContextLooksUpLocalBranches() {
        let links = PullRequestLinkIndex(
            pullRequests: [PullRequestLinksTests.pullRequest(5)], branches: [PullRequestLinksTests.branch("feat/42")],
            remotes: ["origin": repository])
        let context = PullRequestBadgeContext(links: links)
        XCTAssertEqual(context.badge(forBranch: "refs/heads/feat/42")?.number, 5)
        XCTAssertNil(context.badge(forBranch: nil))
        XCTAssertNil(context.badge(forBranch: "refs/heads/other"))
    }
}
