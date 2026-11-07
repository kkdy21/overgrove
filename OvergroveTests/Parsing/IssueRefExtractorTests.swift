import XCTest

@testable import Overgrove

/// PAR-ISSUE-01…03 (parsing-spec.md §11.3).
final class IssueRefExtractorTests: XCTestCase {
    private let repository = "kkdy21/overgrove"

    // MARK: - PAR-ISSUE-01 branch names

    func testPARISSUE01_TypedBranchPrefix() {
        XCTAssertEqual(IssueRefExtractor.issueNumber(inBranch: "feat/12-x"), 12)
        XCTAssertEqual(IssueRefExtractor.issueNumber(inBranch: "fix/7-crash-on-open"), 7)
        XCTAssertEqual(IssueRefExtractor.issueNumber(inBranch: "docs/1234567-long"), 1_234_567)
        for type in ["feat", "fix", "docs", "test", "chore", "spike", "refactor", "perf", "ci"] {
            XCTAssertEqual(IssueRefExtractor.issueNumber(inBranch: "\(type)/42-y"), 42, type)
        }
    }

    func testPARISSUE01_FullRefNameIsAccepted() {
        XCTAssertEqual(IssueRefExtractor.issueNumber(inBranch: "refs/heads/feat/12-x"), 12)
    }

    func testPARISSUE01_FallbackSegmentRule() {
        XCTAssertEqual(IssueRefExtractor.issueNumber(inBranch: "12-quick-fix"), 12)
        XCTAssertEqual(IssueRefExtractor.issueNumber(inBranch: "alice/88-try"), 88)
        XCTAssertEqual(IssueRefExtractor.issueNumber(inBranch: "wip/team/5-a/9-b"), 5, "first matching segment wins")
    }

    func testPARISSUE01_NonMatchingBranches() {
        for name in [
            "main", "feat/no-number", "feat/12", "feat/x12-y", "feature12-x", "feat/12345678-too-long",
            "feat/0-zero", "release-12-x", "feat/１２-fullwidth", "", "/", "feat/-12-x",
        ] {
            XCTAssertNil(IssueRefExtractor.issueNumber(inBranch: name), name)
        }
    }

    // MARK: - PAR-ISSUE-02 commit subjects

    func testPARISSUE02_HashNumbersInSubject() {
        XCTAssertEqual(issues("fix: crash on open (#12)"), [12])
        XCTAssertEqual(issues("#3 at the start"), [3])
        XCTAssertEqual(issues("merge #4, #5 and #4 again"), [4, 5], "unique, in order of appearance")
        XCTAssertEqual(issues("ends with #9"), [9])
        XCTAssertEqual(issues("[#10] bracketed"), [10])
    }

    func testPARISSUE02_FalsePositivesAreExcluded() {
        for subject in [
            "port to C#", "C#10 features", "#define MAX 3", "F#7 interop", "use &#123; entity", "#12abc", "#",
            "issue#12 glued to a word", "#12345678 too long", "#0 is not an issue", "path/#12", "##12 doubled",
            "#１２ fullwidth digits",
        ] {
            XCTAssertEqual(issues(subject), [], subject)
        }
    }

    func testPARISSUE02_CrossRepositoryReferenceOnlyForSameRepository() {
        XCTAssertEqual(issues("see kkdy21/overgrove#21"), [21])
        XCTAssertEqual(issues("see KKDY21/Overgrove#21"), [21], "GitHub owner and repo names are case-insensitive")
        XCTAssertEqual(issues("see other/repo#21"), [])
        XCTAssertEqual(issues("see evil-kkdy21/overgrove#21"), [], "owner must match exactly, not as a suffix")
        XCTAssertEqual(issues("see kkdy21/overgrove-fork#21"), [])
        XCTAssertEqual(
            IssueRefExtractor.issueNumbers(inSubject: "see kkdy21/overgrove#21", repository: nil),
            [],
            "without a known repository no cross-repository reference matches"
        )
    }

    // MARK: - PAR-ISSUE-03 trailers

    func testPARISSUE03_Trailers() {
        let message = """
            feat(parser): add something

            Body text mentioning #99 is not a trailer.

            Closes #57
            Fixes #58 and more
            Resolves #59
            Refs: #60
            Co-Authored-By: Someone <someone@example.com>
            """
        XCTAssertEqual(IssueRefExtractor.issueNumbers(inTrailers: message), [57, 58, 59, 60])
    }

    func testPARISSUE03_TrailerShapesThatDoNotMatch() {
        let message = """
            Refs: #60 extra
            refs: #61
            closes #62
            Closes: #63
             Closes #64
            Refs: #12345678
            Closes #12345678
            Closes #0
            """
        XCTAssertEqual(IssueRefExtractor.issueNumbers(inTrailers: message), [])
    }

    func testPARISSUE03_CRLFAndDuplicates() {
        XCTAssertEqual(IssueRefExtractor.issueNumbers(inTrailers: "Refs: #5\r\nCloses #5\r\nRefs: #6\r\n"), [5, 6])
    }

    private func issues(_ subject: String) -> [Int] {
        IssueRefExtractor.issueNumbers(inSubject: subject, repository: repository)
    }
}
