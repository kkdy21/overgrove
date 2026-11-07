import XCTest

@testable import Overgrove

/// S-03 texts and rows (#69, screens.md S-03).
final class CommitDetailModelTests: XCTestCase {
    static let oid = ObjectID(String(repeating: "a", count: 40))!
    static let parent = ObjectID(String(repeating: "b", count: 40))!
    static let parent2 = ObjectID(String(repeating: "c", count: 40))!

    static func commit(parents: [ObjectID] = [parent], subject: String = "feat(ratelimit): add limiter (#42)")
        -> CommitNode
    {
        CommitNode(
            oid: oid, parents: parents, authorName: "Alex Kim", authorEmail: "alex@example.com",
            authorDate: Date(timeIntervalSince1970: 1_794_000_000), subject: subject,
            coAuthors: ["Coding Agent <noreply@anthropic.com>", "Bo Lee <bo@example.com>"])
    }

    static func stat(_ path: String, _ status: FileChange.Status, _ added: Int?, _ deleted: Int?) -> FileStat {
        FileStat(path: GitPath(path), status: status, added: added, deleted: deleted)
    }

    static func detail(
        message: String, files: [FileStat], committer: (String, String) = ("Alex Kim", "alex@example.com"),
        parents: [ObjectID] = [parent], isPartial: Bool = false
    ) -> CommitDetail {
        CommitDetail(
            oid: oid, parents: parents, authorName: "Alex Kim", authorEmail: "alex@example.com",
            authorDate: Date(timeIntervalSince1970: 1_794_000_000), committerName: committer.0,
            committerEmail: committer.1, committerDate: Date(timeIntervalSince1970: 1_794_000_100), message: message,
            files: files, isPartial: isPartial)
    }

    private let seoul = TimeZone(identifier: "Asia/Seoul")!

    func testHeaderAndMetaShowAtOnceFromTheGraphRow() {
        let model = CommitDetailModel(
            commit: Self.commit(), detail: .loading, pills: [], showsAllFiles: false, timeZone: seoul)

        XCTAssertEqual(model.title, "feat(ratelimit): add limiter (#42)")
        XCTAssertEqual(model.shortSHA, "aaaaaaa")
        XCTAssertEqual(model.author.name, "Alex Kim")
        XCTAssertEqual(model.author.initials, "AK")
        XCTAssertEqual(model.coAuthors.map(\.isAI), [true, false], "only the agent gets the AI badge")
        XCTAssertEqual(model.coAuthors.map(\.title), ["Coding Agent", "Bo Lee"])
        XCTAssertEqual(model.coAuthors.first?.tooltip, "Coding Agent <noreply@anthropic.com>")
        XCTAssertEqual(model.date, "2026-11-07 06:20 (+09:00)")
        XCTAssertEqual(model.files, .loading)
        XCTAssertEqual(model.issues, [42])
        XCTAssertNil(model.committer)
        XCTAssertNil(model.filesNote)
    }

    /// #82: `owner/repo#n` counts only for the repository the issues come from.
    func testIssuesUseTheIssueRepository() {
        let commit = Self.commit(subject: "fix: port team/app#9 and evil/app#8")
        XCTAssertEqual(
            CommitDetailModel(commit: commit, detail: nil, pills: [], showsAllFiles: false, issueRepository: "team/app")
                .issues, [9])
        XCTAssertEqual(CommitDetailModel(commit: commit, detail: nil, pills: [], showsAllFiles: false).issues, [])
    }

    func testLoadedDetailBodyTrailersFilesAndCommitter() {
        let detail = Self.detail(
            message:
                "feat(ratelimit): add limiter (#42)\n\nUse a sliding window.\n\nRefs: #7\nCo-Authored-By: Coding Agent <noreply@anthropic.com>\n",
            files: [
                Self.stat("internal/ratelimit/limiter.go", .added, 112, 0),
                Self.stat("go.mod", .modified, 3, 6),
                Self.stat("assets/logo.png", .modified, nil, nil),
            ],
            committer: ("GitHub", "noreply@github.com"))

        let model = CommitDetailModel(
            commit: Self.commit(), detail: .loaded(detail), pills: [], showsAllFiles: false, timeZone: seoul)

        XCTAssertEqual(
            model.body.map(\.text),
            ["Use a sliding window.", "", "Refs: #7", "Co-Authored-By: Coding Agent <noreply@anthropic.com>"])
        XCTAssertEqual(model.body.map(\.isTrailer), [false, false, true, true])
        XCTAssertEqual(model.issues, [42, 7], "from the subject, then from trailers")
        XCTAssertEqual(model.committer?.name, "GitHub", "shown only when someone else committed")
        XCTAssertEqual(model.filesHeader, "Files (3)")
        XCTAssertEqual(model.totalLineChange, "+115 −6")
        guard case .loaded(let rows, let hidden) = model.files else { return XCTFail("\(model.files)") }
        XCTAssertEqual(rows.map(\.kindLetter), ["A", "M", "M"])
        XCTAssertEqual(rows.map(\.lineChange), ["+112", "+3 −6", "binary"], "zero parts are left out")
        XCTAssertEqual(rows.first?.fileName, "limiter.go")
        XCTAssertEqual(hidden, 0)
    }

    func testMergeNoteManyFilesPartialAndFailure() {
        let files = (0..<(CommitDetailModel.fileLimit + 5)).map { Self.stat("f\($0)", .modified, 1, 0) }
        let merge = Self.commit(parents: [Self.parent, Self.parent2], subject: "Merge branch 'x'")
        let detail = Self.detail(
            message: "Merge branch 'x'\n", files: files, parents: [Self.parent, Self.parent2], isPartial: true)

        let model = CommitDetailModel(commit: merge, detail: .loaded(detail), pills: [], showsAllFiles: false)
        XCTAssertEqual(model.filesNote, "Changes vs first parent")
        XCTAssertEqual(model.parents, [Self.parent, Self.parent2])
        XCTAssertTrue(model.isPartial)
        guard case .loaded(let rows, let hidden) = model.files else { return XCTFail() }
        XCTAssertEqual(rows.count, CommitDetailModel.fileLimit)
        XCTAssertEqual(hidden, 5)
        let all = CommitDetailModel(commit: merge, detail: .loaded(detail), pills: [], showsAllFiles: true)
        guard case .loaded(let allRows, 0) = all.files else { return XCTFail() }
        XCTAssertEqual(allRows.count, files.count)

        let failed = CommitDetailModel(commit: merge, detail: .failed("git timed out"), pills: [], showsAllFiles: false)
        XCTAssertEqual(failed.files, .failed("git timed out"))
    }

    func testRepositoryTextIsEscaped() {
        let hostile = Self.commit(subject: "fix\u{202E}gnp.exe")
        let detail = Self.detail(message: "fix\u{202E}gnp.exe\n\nbody\u{2028}line\n", files: [])
        let model = CommitDetailModel(commit: hostile, detail: .loaded(detail), pills: [], showsAllFiles: false)
        XCTAssertEqual(model.title, "fix\\u{202E}gnp.exe")
        XCTAssertEqual(model.body.map(\.text), ["body\\u{2028}line"])
        XCTAssertEqual(model.files, .loaded(rows: [], hidden: 0))
    }
}
