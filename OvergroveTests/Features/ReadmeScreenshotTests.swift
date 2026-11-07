import AppKit
import SwiftUI
import XCTest

@testable import Overgrove

/// The README screenshots (#101): the real main window below its toolbar, filled with neutral sample data from stub
/// loaders (no git, no network). Opt-in: set `OVERGROVE_README_SCREENSHOT_DIR` (xcodebuild:
/// `TEST_RUNNER_OVERGROVE_README_SCREENSHOT_DIR`) to write `main-window-light.png` and `main-window-dark.png` there.
///
/// Paths live under the home folder so they show as `~/dev/api`; no real user or repository name appears.
@MainActor
final class ReadmeScreenshotTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() async throws {
        suiteName = "overgrove-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
    }

    func testREADMEScreenshots() async throws {
        guard let directory = ProcessInfo.processInfo.environment["OVERGROVE_README_SCREENSHOT_DIR"] else {
            throw XCTSkip("Set OVERGROVE_README_SCREENSHOT_DIR to write the README screenshots")
        }
        for (name, appearanceName) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            // The toolbar's material follows the app's appearance offscreen; set it before the window exists.
            let previous = NSApp.appearance
            NSApp.appearance = NSAppearance(named: appearanceName)
            defer { NSApp.appearance = previous }
            let state = try await Sample.state(defaults: defaults)
            let controller = NSHostingController(rootView: MainWindowView(state: state))
            controller.sceneBridgingOptions = [.toolbars, .title]
            let window = NSWindow(contentViewController: controller)
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.toolbarStyle = .unified
            window.titleVisibility = .hidden
            window.appearance = NSAppearance(named: appearanceName)
            window.setContentSize(NSSize(width: 1440, height: 900))
            defer { window.close() }
            window.layoutIfNeeded()
            controller.view.layoutSubtreeIfNeeded()
            // Let SwiftUI settle (lazy rows, the toolbar bridge) before drawing.
            try await Task.sleep(for: .milliseconds(300))
            controller.view.layoutSubtreeIfNeeded()

            let frame = try XCTUnwrap(window.contentView?.superview)
            let bitmap = try XCTUnwrap(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
            frame.cacheDisplay(in: frame.bounds, to: bitmap)
            // Below the toolbar: offscreen, AppKit cannot draw the toolbar's dark material (it comes out white), so
            // both appearances leave it out to match.
            let scale = CGFloat(bitmap.pixelsHigh) / frame.bounds.height
            let toolbar = (window.frame.height - window.contentLayoutRect.height) * scale
            let image = try XCTUnwrap(bitmap.cgImage)
            let content = try XCTUnwrap(
                image.cropping(
                    to: CGRect(
                        x: 0, y: toolbar.rounded(), width: CGFloat(image.width),
                        height: CGFloat(image.height) - toolbar.rounded())))
            let png = try XCTUnwrap(
                NSBitmapImageRep(cgImage: content).representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("main-window-\(name).png"))
        }
    }
}

/// A made-up repository: an API service with worktrees for a feature, a fix, and a review.
@MainActor
private enum Sample {
    static let home = NSHomeDirectory()
    static let root = home + "/dev/api"
    static let now = Date()

    static func oid(_ prefix: String) -> ObjectID {
        ObjectID(prefix + String(repeating: "0", count: 40 - prefix.count))!
    }

    // Newest first.
    static let feature = oid("a91f3c2")
    static let featureTest = oid("7d2e9b1")
    static let fix = oid("3c8a4f0")
    static let merge = oid("e5b17d9")
    static let docs = oid("b4096ae")
    static let perf = oid("0f6c2d8")
    static let release = oid("9a3e5c1")
    static let older = (0..<12).map { oid(String(format: "1%06x", 0x2b3c4d + $0 * 0x1f3)) }

    static func commit(
        _ oid: ObjectID, _ parents: [ObjectID], _ subject: String, _ author: String, hoursAgo: Double,
        coAuthors: [String] = []
    ) -> CommitNode {
        CommitNode(
            oid: oid, parents: parents, authorName: author,
            authorEmail: author.lowercased().replacingOccurrences(of: " ", with: ".") + "@example.com",
            authorDate: now.addingTimeInterval(-hoursAgo * 3_600), subject: subject, coAuthors: coAuthors)
    }

    static var commits: [CommitNode] {
        let olderSubjects = [
            ("feat(api): paginate the audit log endpoint", "Sara Kim"), ("fix(db): close idle connections", "Jun Park"),
            ("refactor(http): split the router", "Mina Lee"), ("test(db): migrate fixtures to SQL files", "Sara Kim"),
            ("feat(auth): rotate refresh tokens", "Jun Park"), ("chore(deps): bump the toolchain", "Mina Lee"),
            ("docs: add the deployment checklist", "Sara Kim"),
            ("fix(api): return 404 for unknown tenants", "Jun Park"),
            ("feat(api): add request IDs to logs", "Mina Lee"), ("perf(api): cache tenant lookups", "Sara Kim"),
            ("chore(release): v0.2.0", "Jun Park"), ("feat: initial service skeleton", "Mina Lee"),
        ]
        var list = [
            commit(
                feature, [featureTest], "feat(http): add a sliding-window rate limiter (#42)", "Mina Lee",
                hoursAgo: 1),
            commit(
                featureTest, [merge], "test(http): cover limiter edge cases", "Mina Lee", hoursAgo: 3,
                coAuthors: ["Claude <noreply@anthropic.com>"]),
            commit(fix, [merge], "fix(auth): keep the session after a token refresh (#57)", "Jun Park", hoursAgo: 5),
            commit(merge, [perf, docs], "Merge pull request #39 from team/docs-worktrees", "Sara Kim", hoursAgo: 20),
            commit(docs, [release], "docs: describe the worktree layout (#39)", "Sara Kim", hoursAgo: 26),
            commit(perf, [release], "perf(db): batch the audit log writes", "Jun Park", hoursAgo: 30),
            commit(release, [older[0]], "chore(release): v0.3.0", "Mina Lee", hoursAgo: 50),
        ]
        for (index, oid) in older.enumerated() {
            let (subject, author) = olderSubjects[index]
            let parents = index + 1 < older.count ? [older[index + 1]] : []
            list.append(commit(oid, parents, subject, author, hoursAgo: 72 + Double(index) * 20))
        }
        return list
    }

    static func branch(_ name: String, _ target: ObjectID, upstream: UpstreamStatus = .none) -> Branch {
        Branch(
            fullName: "refs/heads/\(name)", kind: .local, target: target, upstreamStatus: upstream, isHead: false,
            committerDate: now, symbolicTarget: nil)
    }

    static func remote(_ name: String, _ target: ObjectID) -> Branch {
        Branch(
            fullName: "refs/remotes/origin/\(name)", kind: .remote(remote: "origin"), target: target,
            upstreamStatus: .none, isHead: false, committerDate: now.addingTimeInterval(-7_200), symbolicTarget: nil)
    }

    static var refs: RefParser.Listing {
        RefParser.Listing(
            branches: [
                branch("main", merge, upstream: .tracking(upstream: "refs/remotes/origin/main", ahead: 0, behind: 0)),
                branch(
                    "feat/42-rate-limit", feature,
                    upstream: .tracking(upstream: "refs/remotes/origin/feat/42-rate-limit", ahead: 2, behind: 0)),
                branch(
                    "fix/57-session", fix,
                    upstream: .tracking(upstream: "refs/remotes/origin/fix/57-session", ahead: 0, behind: 1)),
                branch("docs/worktrees", docs),
                remote("main", merge), remote("feat/42-rate-limit", merge), remote("fix/57-session", perf),
            ],
            tags: [
                Tag(fullName: "refs/tags/v0.3.0", target: release, peeledTarget: nil, date: now),
                Tag(fullName: "refs/tags/v0.2.0", target: older[10], peeledTarget: nil, date: now),
            ], isPartial: false, skippedRecords: 0)
    }

    static func changes(_ names: [String], _ status: FileChange.Status) -> [FileChange] {
        names.map { FileChange(path: GitPath($0), status: status) }
    }

    static func entry(
        _ folder: String, branch: String?, head: ObjectID, isMain: Bool = false, staged: [String] = [],
        unstaged: [String] = [], untracked: [String] = [], upstream: UpstreamStatus = .none
    ) -> WorktreeListing.Entry {
        let path = isMain ? root : home + "/dev/api-wt/" + folder
        return WorktreeListing.Entry(
            worktree: Worktree(
                path: GitPath(path), head: head, branch: branch.map { "refs/heads/\($0)" }, isMain: isMain,
                isDetached: branch == nil, isBare: false, lock: .unlocked, isPrunable: false, prunableReason: nil),
            state: .loaded(
                WorkingState(
                    headCommit: head, head: branch.map(WorkingState.Head.branch) ?? .detached, upstream: upstream,
                    stashCount: 1, staged: changes(staged, .modified), unstaged: changes(unstaged, .modified),
                    untracked: changes(untracked, .untracked), conflicted: [], isPartial: false, skippedRecords: 0)))
    }

    static var listing: WorktreeListing {
        var listing = WorktreeListing(
            entries: [
                entry(
                    "api", branch: "main", head: merge, isMain: true,
                    upstream: .tracking(upstream: "origin/main", ahead: 0, behind: 0)),
                entry(
                    "42-rate-limit", branch: "feat/42-rate-limit", head: feature,
                    staged: ["internal/http/ratelimit.go", "internal/http/middleware.go"],
                    unstaged: ["internal/http/ratelimit_test.go"], untracked: ["docs/rate-limits.md"],
                    upstream: .tracking(upstream: "origin/feat/42-rate-limit", ahead: 2, behind: 0)),
                entry(
                    "57-session", branch: "fix/57-session", head: fix, unstaged: ["internal/auth/session.go"],
                    upstream: .tracking(upstream: "origin/fix/57-session", ahead: 0, behind: 1)),
                entry("review", branch: nil, head: docs),
            ],
            isPartial: false)
        listing.refs = refs
        listing.remoteNames = ["origin"]
        listing.githubRepository = GitHubRepository(owner: "example", name: "api")
        listing.stashes = [
            Stash(
                index: 0, oid: oid("5e7a1b3"), subject: "On main: try a token bucket", branch: "main",
                message: "try a token bucket", date: now.addingTimeInterval(-90_000), parents: [merge, oid("6f8b2c4")])
        ]
        return listing
    }

    static var issues: [Issue] {
        func issue(_ number: Int, _ title: String, _ labels: [String], hoursAgo: Double) -> Issue {
            Issue(
                number: number, title: title, state: .open, labels: labels.map { Issue.Label(name: $0, color: nil) },
                assignees: ["mina-lee"], updatedAt: now.addingTimeInterval(-hoursAgo * 3_600),
                url: URL(string: "https://github.com/example/api/issues/\(number)")!)
        }
        return [
            issue(42, "Rate limit the public API", ["type:feature"], hoursAgo: 1),
            issue(57, "Session lost after a token refresh", ["type:bug"], hoursAgo: 5),
            issue(61, "Export the audit log as CSV", ["type:feature"], hoursAgo: 30),
            issue(64, "Flaky test in the tenant cache", ["type:test"], hoursAgo: 48),
        ]
    }

    static func state(defaults: UserDefaults) async throws -> AppState {
        let state = AppState(
            layoutStore: PanelLayoutStore(defaults: defaults), registry: RepositoryRegistry(defaults: defaults),
            loader: StubRepositoryLoader(result: .success(listing)), issueLoader: StubIssueLoader([.issues(issues)]),
            graphLoader: ReadmeGraphLoader(), commitLoader: StubCommitLoader(),
            ghChecker: QueuedGHAuthChecker([.loggedIn(login: "mina-lee")]))
        let url = URL(fileURLWithPath: root, isDirectory: true)
        state.open(
            RepositoryContext(
                repository: Repository(
                    rootURL: url, commonGitDirectoryURL: url.appendingPathComponent(".git"), isBare: false),
                owner: nil))
        state.reload()
        await state.loadTask?.value
        await state.issuePanel.task?.value
        let deadline = ContinuousClock.now + .seconds(5)
        while state.graph.status != .loaded, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        state.selectWorktree(GitPath(home + "/dev/api-wt/42-rate-limit"))
        state.fetch.showForPreview(.idle(lastFetched: now.addingTimeInterval(-120)))
        return state
    }
}

private struct ReadmeGraphLoader: GraphLoading {
    func page(_ repository: Repository, skip: Int, limit: Int) async -> Result<GraphPageSnapshot, GitError> {
        let commits = await Sample.commits
        let refs = await Sample.refs
        let worktrees = await Sample.listing.entries.map(\.worktree)
        let end = min(commits.count, skip + limit)
        return .success(
            GraphPageSnapshot(
                commits: skip < end ? Array(commits[skip..<end]) : [], isPartial: false,
                refSet: GraphRefSet(refs: refs, worktrees: worktrees), refs: refs, worktrees: worktrees))
    }
}
