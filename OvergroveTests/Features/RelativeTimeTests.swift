import Foundation
import XCTest

@testable import Overgrove

/// Relative times outside the fetch wording (#686): compact in TAGS and REMOTE rows, `… ago` in S-04's head and the
/// issue detail, spelled out for VoiceOver. The status bar's and S-05's fetch wording stays in days.
final class RelativeTimeTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    private func ago(_ seconds: TimeInterval) -> Date { now.addingTimeInterval(-seconds) }

    /// The graph Date column's steps (screens.md S-01): old dates go up to weeks, months, and years.
    func testCompactGoesUpToMonthsAndYears() {
        XCTAssertEqual(RelativeTime.compact(ago(20), now: now), "now")
        XCTAssertEqual(RelativeTime.compact(ago(3 * 3_600), now: now), "3h")
        XCTAssertEqual(RelativeTime.compact(ago(3 * day), now: now), "3d")
        XCTAssertEqual(RelativeTime.compact(ago(12 * day), now: now), "1w")
        XCTAssertEqual(RelativeTime.compact(ago(40 * day), now: now), "1mo")
        XCTAssertEqual(RelativeTime.compact(ago(1_097 * day), now: now), "3y", "#686 showed 1,097 d ago")
    }

    /// S-04 `3d ago` and the issue detail's `updated 3h ago` (screens.md S-04, S-06).
    func testAgoForHeaders() {
        XCTAssertEqual(RelativeTime.ago(ago(20), now: now), "just now")
        XCTAssertEqual(RelativeTime.ago(ago(5 * 60), now: now), "5m ago")
        XCTAssertEqual(RelativeTime.ago(ago(3 * 3_600), now: now), "3h ago")
        XCTAssertEqual(RelativeTime.ago(ago(3 * day), now: now), "3d ago")
        XCTAssertEqual(RelativeTime.ago(ago(1_097 * day), now: now), "3y ago")
        XCTAssertEqual(RelativeTime.ago(now.addingTimeInterval(600), now: now), "just now", "a date in the future")
    }

    /// interaction.md §6: VoiceOver hears `3 days ago`, in the app's language.
    func testSpokenForVoiceOver() {
        XCTAssertEqual(RelativeTime.spoken(ago(20), now: now), "just now")
        XCTAssertEqual(RelativeTime.spoken(ago(3 * 3_600), now: now), "3 hours ago")
        XCTAssertEqual(RelativeTime.spoken(ago(3 * day), now: now), "3 days ago")
        XCTAssertEqual(RelativeTime.spoken(ago(1_097 * day), now: now), "3 years ago")
        XCTAssertEqual(RelativeTime.spoken(ago(3 * day), now: now, locale: Locale(identifier: "ko")), "3일 전")
    }

    /// The fetch wording (interaction.md §4.2) is left as it was: `2 d ago`, never weeks or years.
    func testTheFetchWordingIsUnchanged() {
        XCTAssertEqual(StatusBarItem.relative(ago(2 * day), now: now), "2 d ago")
        XCTAssertEqual(StatusBarItem.relative(ago(20 * day), now: now), "20 d ago")
    }

    /// #686: the rows and headers that used the fetch wording.
    func testTagRemoteStashAndIssueDates() throws {
        let threeYears = ago(1_097 * day)
        let tags = TagListModel(
            tags: [
                Tag(
                    fullName: "refs/tags/v0.0.1", target: ObjectID(String(repeating: "b", count: 40))!,
                    peeledTarget: ObjectID(String(repeating: "a", count: 40))!, date: threeYears, objectType: .commit)
            ], detachedHeads: [])
        let tag = try XCTUnwrap(tags.rows.first)
        XCTAssertEqual(tag.relativeDate(now: now), "3y")
        XCTAssertEqual(tag.spokenLabel(now: now), "Annotated tag v0.0.1, 3 years ago")

        let remote = Branch(
            fullName: "refs/remotes/origin/main", kind: .remote(remote: "origin"),
            target: ObjectID(String(repeating: "a", count: 40))!, upstreamStatus: .none, isHead: false,
            committerDate: threeYears, symbolicTarget: nil)
        let branches = BranchListModel(
            refs: RefParser.Listing(branches: [remote], tags: [], isPartial: false, skippedRecords: 0), checkedOut: [],
            remoteNames: ["origin"])
        let rows = branches.remote.flatMap(Self.rows)
        XCTAssertEqual(rows.map { $0.relativeDate(now: now) }, ["3y"])

        let stash = StashDetailModelTests.stash()
        let detail = StashDetailModel(stash: stash, state: .loading)
        XCTAssertEqual(detail.relativeDate(now: stash.date.addingTimeInterval(1_097 * day)), "3y ago")

        let issue = IssueDetailModel(
            IssueModelsTests.issue(12, updated: -3 * 3_600), repository: IssueModelsTests.repository)
        XCTAssertEqual(issue.updatedLine(now: now), "team/app · updated 3h ago")
        XCTAssertEqual(issue.updatedLine(now: now, spoken: true), "team/app · updated 3 hours ago")
        XCTAssertEqual(
            IssueDetailModel(IssueModelsTests.issue(12, updated: -30), repository: nil).updatedLine(now: now),
            "updated just now")
    }

    private static func rows(_ node: BranchNode) -> [BranchRow] {
        switch node {
        case .branch(let row): [row]
        case .folder(_, _, _, let children): children.flatMap(rows)
        }
    }
}
