import Foundation
import XCTest

@testable import Overgrove

/// Records inspections and answers with an empty configuration.
final class RecordingInspector: WorktreeInspecting, @unchecked Sendable {
    private let lock = NSLock()
    private var inspected: [GitPath] = []

    var paths: [GitPath] { lock.withLock { inspected } }

    func inspect(_ worktree: Worktree, of repository: Repository) async -> WorktreeInspection {
        lock.withLock { inspected.append(worktree.path) }
        return WorktreeInspection(
            inspection: RepoConfigInspector.inspect(ConfigParser.Listing(entries: [], isPartial: false)),
            failure: nil, inspectedAt: Date(), gitVersion: GitVersion(major: 2, minor: 50, patch: 1),
            commonArguments: GitEnvironment.commonArguments, diffArguments: ["diff", "--no-ext-diff", "--no-textconv"],
            hookExecutables: [], realPath: nil)
    }
}

/// `AppState` worktree detail flows (#67): the `Changes | Worktree` segment and on-demand inspection.
@MainActor
final class AppStateWorktreeDetailTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let feature = GitPath("/tmp/dev/api-wt/42-rate-limit")
    private let missing = GitPath("/tmp/dev/api-wt/old-spike")

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    private func loadedState(_ inspector: RecordingInspector) async -> AppState {
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(), inspector: inspector)
        let root = URL(fileURLWithPath: "/tmp/dev/api", isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        state.reload()
        await state.loadTask?.value
        return state
    }

    func testWorktreeSegmentInspectsOnDemand() async {
        let inspector = RecordingInspector()
        let state = await loadedState(inspector)
        state.selectWorktree(feature)
        XCTAssertNil(state.worktreeDetailModel, "Changes is the default segment")
        XCTAssertEqual(inspector.paths, [], "nothing is inspected until the segment opens")

        state.showWorktreeDetail()
        XCTAssertEqual(state.selection, .worktreeInfo(feature))
        XCTAssertNil(state.wipDetailModel)
        XCTAssertNil(state.worktreeDetailModel?.security, "loading")
        await state.inspectionTask?.value
        XCTAssertEqual(inspector.paths, [feature])
        XCTAssertEqual(state.worktreeDetailModel?.title, "feat/42-rate-limit")
        XCTAssertEqual(state.worktreeDetailModel?.security?.rows.first?.mark, .applied)

        // Opening it again does not re-run git.
        state.showChanges()
        XCTAssertEqual(state.selection, .wip(feature))
        state.showWorktreeDetail()
        await state.inspectionTask?.value
        XCTAssertEqual(inspector.paths, [feature])
    }

    func testTheSegmentStaysWhenAnotherWorktreeIsSelected() async {
        let inspector = RecordingInspector()
        let state = await loadedState(inspector)
        state.selectWorktree(feature)
        state.showWorktreeDetail()
        await state.inspectionTask?.value

        let main = GitPath("/tmp/dev/api")
        state.selectWorktree(main)
        XCTAssertEqual(state.selection, .worktreeInfo(main))
        await state.inspectionTask?.value
        XCTAssertEqual(inspector.paths, [feature, main])
    }

    func testMissingWorktreeIsNotInspected() async {
        let inspector = RecordingInspector()
        let state = await loadedState(inspector)
        state.selectWorktree(missing)
        state.showWorktreeDetail()
        await state.inspectionTask?.value
        XCTAssertEqual(inspector.paths, [])
        XCTAssertNotNil(state.worktreeDetailModel?.securityUnavailable)
    }

    func testReloadReinspectsTheShownWorktree() async {
        let inspector = RecordingInspector()
        let state = await loadedState(inspector)
        state.selectWorktree(feature)
        state.showWorktreeDetail()
        await state.inspectionTask?.value
        state.reload()
        await state.loadTask?.value
        await state.inspectionTask?.value
        XCTAssertEqual(inspector.paths, [feature, feature], "configuration may have changed")
    }

    func testOpeningAnotherRepositoryDropsInspections() async {
        let inspector = RecordingInspector()
        let state = await loadedState(inspector)
        state.selectWorktree(feature)
        state.showWorktreeDetail()
        await state.inspectionTask?.value
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: URL(fileURLWithPath: "/tmp/dev/web"),
                    commonGitDirectoryURL: URL(fileURLWithPath: "/tmp/dev/web/.git"), isBare: false),
                owner: nil))
        XCTAssertEqual(state.worktreeInspections, [:])
        XCTAssertNil(state.selection)
        XCTAssertNil(state.worktreeDetailModel)
    }

    func testSegmentActionsNeedASelection() {
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(), inspector: RecordingInspector())
        state.showWorktreeDetail()
        state.showChanges()
        XCTAssertNil(state.selection)
    }
}
