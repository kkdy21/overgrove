import Foundation
import XCTest

@testable import Overgrove

/// S-02's Submodules card (#108): what each state reads as, and when the card is hidden.
final class SubmoduleSectionModelTests: XCTestCase {
    private func listing(_ submodules: [SubmoduleStatus], omitted: Int = 0, refused: Bool = false) -> SubmoduleListing {
        SubmoduleListing(submodules: submodules, omitted: omitted, isGitmodulesRefused: refused)
    }

    private func row(_ state: SubmoduleStatus.State, path: String = "libs/a", listed: Bool = true)
        -> SubmoduleSectionModel.Row
    {
        SubmoduleSectionModel.row(SubmoduleStatus(path: GitPath(path), isListed: listed, state: state))
    }

    func testHiddenWithNothingToShow() {
        XCTAssertNil(SubmoduleSectionModel(nil))
        XCTAssertNil(SubmoduleSectionModel(.loaded(.empty)))
        XCTAssertNotNil(SubmoduleSectionModel(.loaded(listing([], refused: true))), "a refused .gitmodules is said")
        XCTAssertNotNil(SubmoduleSectionModel(.loaded(listing([], omitted: 3))))
        XCTAssertEqual(SubmoduleSectionModel(.pending)?.content, .checking)
        XCTAssertEqual(SubmoduleSectionModel(.failed)?.content, .failed)
    }

    func testBadges() {
        XCTAssertEqual(row(.clean).badge, "clean")
        XCTAssertEqual(row(.changed(files: 3, untracked: 2, isPartial: false)).badge, "3 changed · 2 untracked")
        XCTAssertEqual(row(.changed(files: 3, untracked: 0, isPartial: true)).badge, "3+ changed")
        XCTAssertEqual(row(.changed(files: 0, untracked: 1, isPartial: false)).tone, .changed)
        XCTAssertEqual(row(.notCheckedOut).badge, "not checked out")
        let blocked = row(.notInspected(.blocked(reason: "filter driver name is not allowed")))
        XCTAssertEqual(blocked.badge, "not inspected")
        XCTAssertEqual(blocked.tone, .attention)
        XCTAssertTrue(blocked.help?.contains("filter driver name") == true)
        XCTAssertTrue(row(.notInspected(.outsideRepository)).help?.contains("outside") == true)
        XCTAssertEqual(row(.failed(.cancelled)).tone, .attention)
    }

    /// Paths come from the repository: bidi overrides and controls are escaped; unlisted gitlinks are marked.
    func testPathsAreEscapedAndUnlistedMarked() {
        let hostile = row(.clean, path: "libs/\u{202E}txt.exe", listed: false)
        XCTAssertFalse(hostile.path.contains("\u{202E}"))
        XCTAssertTrue(hostile.isUnlisted)
    }
}

/// Answers from a script and counts requests.
private final class ScriptedSubmoduleLoader: SubmoduleLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    var callCount: Int { lock.withLock { calls } }
    let answer: SubmoduleListing?

    init(answer: SubmoduleListing?) { self.answer = answer }

    func submodules(
        _ repository: Repository, worktree: GitPath
    ) async throws(RepositoryLoadError) -> SubmoduleListing? {
        lock.withLock { calls += 1 }
        return answer
    }
}

/// `SubmodulePanel` (#108): one request per worktree status, a refresh asks again, a new status resets.
@MainActor
final class SubmodulePanelTests: XCTestCase {
    private let repository = Repository(
        rootURL: URL(fileURLWithPath: "/tmp/dev/api"),
        commonGitDirectoryURL: URL(fileURLWithPath: "/tmp/dev/api/.git"), isBare: false)
    private let path = GitPath("/tmp/dev/api")

    private func waitUntil(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { return XCTFail("condition not met", file: file, line: line) }
            await Task.yield()
        }
    }

    func testRequestsOncePerStatus() async {
        let answer = SubmoduleListing(
            submodules: [SubmoduleStatus(path: GitPath("libs/a"), isListed: true, state: .clean)], omitted: 0,
            isGitmodulesRefused: false)
        let loader = ScriptedSubmoduleLoader(answer: answer)
        let panel = SubmodulePanel(loader: loader)
        let state = WorktreeListing.state(branch: "main")

        panel.request(repository, path: path, state: state)
        XCTAssertEqual(panel.result(for: path, state), .pending)
        await waitUntil { panel.result(for: path, state) == .loaded(answer) }
        panel.request(repository, path: path, state: state)
        XCTAssertEqual(loader.callCount, 1, "same status: no new request")
        panel.request(repository, path: path, state: state, refresh: true)
        await waitUntil { loader.callCount == 2 }
        XCTAssertEqual(panel.result(for: path, state), .loaded(answer), "the shown answer stays while asking again")
        XCTAssertNil(panel.result(for: GitPath("/tmp/dev/other"), state))
        panel.clear()
        XCTAssertNil(panel.result(for: path, state))
    }
}
