import Foundation
import XCTest

@testable import Overgrove

/// T13 (security-review.md §2): Overgrove's queries do not write to the repository. SEC-T13-01 (only read-only
/// subcommands exist) is `GitCommandTests.testSECT13_01_OnlyReadOnlySubcommandsExist`.
final class WriteProtectionTests: XCTestCase {
    /// Content and modification date of an index file.
    private struct IndexState: Equatable {
        let bytes: Data
        let modified: Date

        init(_ url: URL) throws {
            bytes = try Data(contentsOf: url)
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            modified = try XCTUnwrap(attributes[.modificationDate] as? Date)
        }
    }

    private static let linkedWorktrees = [
        "wt-ahead", "wt-behind", "wt-conflict", "wt-detached", "wt-diverged", "wt-locked", "wt-no-upstream",
    ]

    /// The index of the main worktree and of every linked worktree (`.git/worktrees/<name>/index`).
    private func indexes(_ fixture: FixtureRepo) -> [String: URL] {
        var indexes = ["repo": fixture.repository.appendingPathComponent(".git/index")]
        for name in Self.linkedWorktrees {
            indexes[name] = fixture.repository.appendingPathComponent(".git/worktrees/\(name)/index")
        }
        return indexes
    }

    /// A normal fixture where status would like to refresh stat data: `docs/manual.md` keeps its content but gets a
    /// new mtime in the main worktree and in `wt-behind`.
    private func staleStatFixture() async throws -> (IntegrationContext, [String: URL], [String: IndexState]) {
        let context = try await IntegrationContext.make(fixture: try await makeFixture())
        for directory in [context.fixture.repository, context.fixture.worktree("wt-behind")] {
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: 1_767_225_600)],
                ofItemAtPath: directory.appendingPathComponent("docs/manual.md").path)
        }
        let indexes = indexes(context.fixture)
        return (context, indexes, try indexes.mapValues(IndexState.init))
    }

    private func assertUnchanged(
        _ indexes: [String: URL],
        since before: [String: IndexState],
        after action: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws {
        for (name, index) in indexes {
            let state = try IndexState(index)
            XCTAssertEqual(
                state.bytes, before[name]?.bytes, "\(action): \(name) index content changed", file: file, line: line)
            XCTAssertEqual(
                state.modified, before[name]?.modified, "\(action): \(name) index rewritten", file: file, line: line)
            let lock = index.deletingLastPathComponent().appendingPathComponent("index.lock")
            XCTAssertFalse(
                FileManager.default.fileExists(atPath: lock.path), "\(action): \(name) index.lock left", file: file,
                line: line)
        }
    }

    /// SEC-T13-02: status of every worktree leaves its index byte-for-byte and mtime-for-mtime unchanged, even when
    /// status would like to store refreshed stat data. Plain `git status` rewrites the index in the same state.
    func testSECT13_02_StatusNeverWritesTheIndex() async throws {
        let (context, indexes, before) = try await staleStatFixture()
        let fixture = context.fixture
        for directory in [fixture.repository] + Self.linkedWorktrees.map(fixture.worktree) {
            _ = try await context.status(of: directory)
        }
        try assertUnchanged(indexes, since: before, after: "app status")

        for (name, directory) in [("repo", fixture.repository), ("wt-behind", fixture.worktree("wt-behind"))] {
            _ = try await context.plainGit(["status", "--porcelain"], in: directory)
            let rewritten = try IndexState(try XCTUnwrap(indexes[name]))
            XCTAssertNotEqual(rewritten, before[name], "control: plain status should rewrite the \(name) index")
        }
    }

    /// Every file under `.git` (relative path, size, modification date): a query must not change any of them.
    private func gitDirectorySnapshot(_ repository: URL) throws -> [String: String] {
        let root = repository.appendingPathComponent(".git", isDirectory: true)
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys))
        var snapshot: [String: String] = [:]
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: Set(keys))
            guard values.isRegularFile == true else { continue }
            let relative = String(url.path.dropFirst(root.path.count))
            let modified = values.contentModificationDate?.timeIntervalSince1970 ?? 0
            snapshot[relative] = "\(values.fileSize ?? -1) \(modified)"
        }
        return snapshot
    }

    /// T13 beyond status: every other query, in the main worktree and in a linked one, leaves every file under
    /// `.git` unchanged (not just the index), including the worktree diff of a stat-dirty file (#208).
    func testOtherQueriesChangeNothingUnderGit() async throws {
        let (context, _, _) = try await staleStatFixture()
        let fixture = context.fixture
        let repo = fixture.repository
        let graph = try await context.graph()
        let stashes = try StashParser.parse(try await context.run(.stashList)).stashes
        let stash = try XCTUnwrap(stashes.last)
        let merge = try context.commit("0cbcd45", in: graph)
        let untracked = try XCTUnwrap(PathValidator.worktreeFile(GitPath("untracked.txt"), in: repo))
        let before = try gitDirectorySnapshot(repo)

        let queries: [(ReadOnlyGitCommand, URL?)] = [
            (.version, nil), (.probeRepository, repo), (.configList, repo), (.worktreeList, repo), (.refs, repo),
            (
                .aheadBehind(
                    local: FullRefName("refs/heads/main")!, upstream: FullRefName("refs/remotes/origin/main")!), repo
            ),
            (.stashList, repo), (.stashFiles(stash.oid), repo),
            (.stashPatch(stash.oid, path: GitPath("src/stash-target.txt"), fromUntracked: false), repo),
            (.graphPage(skip: 0, limit: 500), repo), (.commitMeta(merge.oid), repo),
            (.commitFiles(merge.oid, firstParent: merge.parents.first), repo),
            (.commitPatch(merge.oid, parent: merge.parents.first, path: GitPath("README.md")), repo),
            (.worktreeDiff(path: GitPath("src/staged-modified.txt"), staged: true), repo),
            (.worktreeDiff(path: GitPath("src/unstaged-modified.txt"), staged: false), repo),
            (.worktreeDiff(path: GitPath("docs/manual.md"), staged: false), repo),
            (.untrackedPreview(untracked), repo), (.fileHistory(path: GitPath("docs/manual.md"), limit: 100), repo),
            (.compareFiles(base: FullRefName("refs/remotes/origin/main")!, includeWorkingTree: true), repo),
            (.compareFiles(base: FullRefName("refs/remotes/origin/main")!, includeWorkingTree: false), repo),
            (
                .comparePatch(
                    base: FullRefName("refs/remotes/origin/main")!, path: GitPath("docs/manual.md"),
                    includeWorkingTree: true), repo
            ),
            (.commitsAhead(base: FullRefName("refs/remotes/origin/main")!, limit: 100), repo),
            (.status, fixture.worktree("wt-behind")),
            (.worktreeDiff(path: GitPath("docs/guide.md"), staged: false), fixture.worktree("wt-behind")),
            (.fileHistory(path: GitPath("docs/manual.md"), limit: 10), fixture.worktree("wt-behind")),
        ]
        for (command, directory) in queries {
            _ = try await context.run(command, in: directory ?? repo)
            let after = try gitDirectorySnapshot(repo)
            let changed = Set(after.keys).union(before.keys).filter { after[$0] != before[$0] }.sorted()
            XCTAssertEqual(changed, [], "\(command) changed files under .git")
        }
    }

    /// SEC-T13-02, worktree diff: `git diff` of a path whose content is unchanged but whose stat data is stale leaves
    /// the index untouched. `git diff` ignores `--no-optional-locks` for this refresh; `-c diff.autoRefreshIndex=false`
    /// in the common arguments stops it (#208). Control: the same app arguments without that one setting rewrite the
    /// index, so this test proves the setting is what protects it.
    func testSECT13_02_WorktreeDiffOfAStatDirtyFileKeepsTheIndex() async throws {
        let (context, indexes, before) = try await staleStatFixture()
        let diff = ReadOnlyGitCommand.worktreeDiff(path: GitPath("docs/manual.md"), staged: false)
        let output = try await context.run(diff)
        XCTAssertEqual(output, Data(), "unchanged content diffs empty")
        // The same in a linked worktree (its index is `.git/worktrees/wt-behind/index`).
        let linked = try await context.run(diff, in: context.fixture.worktree("wt-behind"))
        XCTAssertEqual(linked, Data(), "unchanged content diffs empty in wt-behind")
        try assertUnchanged(indexes, since: before, after: "worktreeDiff of a stat-dirty file")

        let commonWithoutSetting = Self.removingSetting(
            "diff.autoRefreshIndex=false", from: GitEnvironment.commonArguments)
        XCTAssertNotEqual(commonWithoutSetting, GitEnvironment.commonArguments, "the setting is a common argument")
        let control = try await ProcessRunner().run(
            ProcessRequest(
                executable: context.environment.executable,
                arguments: commonWithoutSetting + context.safety.neutralization + (try diff.subcommandArguments()),
                environment: GitEnvironment.environment(parent: context.fixture.environment),
                currentDirectory: context.fixture.repository,
                limits: .query
            )
        )
        XCTAssertEqual(control.termination, .exited(code: 0))
        let index = try XCTUnwrap(indexes["repo"])
        XCTAssertNotEqual(
            try IndexState(index), before["repo"], "control: without the setting git diff rewrites the index")
    }

    /// SEC-T13-02, merge-base comparison (#157): comparing the working tree with a base branch diffs stat-dirty files
    /// too. With the common arguments the index stays untouched; control: without `diff.autoRefreshIndex=false` the
    /// same comparison rewrites it (confirmed with Apple Git 2.50.1).
    func testSECT13_02_MergeBaseComparisonOfAStatDirtyWorkingTreeKeepsTheIndex() async throws {
        let (context, indexes, before) = try await staleStatFixture()
        let base = FullRefName("refs/remotes/origin/main")!
        let files = ReadOnlyGitCommand.compareFiles(base: base, includeWorkingTree: true)
        let patch = ReadOnlyGitCommand.comparePatch(
            base: base, path: GitPath("docs/manual.md"), includeWorkingTree: true)
        for command in [files, patch] {
            _ = try await context.run(command)
            _ = try await context.run(command, in: context.fixture.worktree("wt-behind"))
        }
        try assertUnchanged(indexes, since: before, after: "merge-base comparison of a stat-dirty working tree")

        let commonWithoutSetting = Self.removingSetting(
            "diff.autoRefreshIndex=false", from: GitEnvironment.commonArguments)
        let control = try await ProcessRunner().run(
            ProcessRequest(
                executable: context.environment.executable,
                arguments: commonWithoutSetting + context.safety.neutralization + (try files.subcommandArguments()),
                environment: GitEnvironment.environment(parent: context.fixture.environment),
                currentDirectory: context.fixture.repository,
                limits: .query
            )
        )
        XCTAssertEqual(control.termination, .exited(code: 0))
        XCTAssertNotEqual(
            try IndexState(try XCTUnwrap(indexes["repo"])), before["repo"],
            "control: without the setting the comparison rewrites the index")
    }

    /// `arguments` without one `-c <setting>` pair.
    private static func removingSetting(_ setting: String, from arguments: [String]) -> [String] {
        var result: [String] = []
        var index = arguments.startIndex
        while index < arguments.endIndex {
            if arguments[index] == "-c", index + 1 < arguments.endIndex, arguments[index + 1] == setting {
                index += 2
                continue
            }
            result.append(arguments[index])
            index += 1
        }
        return result
    }

    // MARK: SEC-T13-03

    private var executables: TestExecutables!

    override func setUpWithError() throws {
        executables = try TestExecutables()
    }

    override func tearDown() {
        executables?.remove()
    }

    private func check(_ content: String, as path: String) async throws -> ProcessResult {
        try await RepositoryScript.run(
            "scripts/lint/check-forbidden-apis.sh", ["--stdin", path], stdin: content, executables: executables)
    }

    /// Forbidden calls, assembled at runtime so this file does not trip the check it tests.
    private static let forbidden: [String] = [
        "let child = " + "Pro" + "cess()",
        "let task = NS" + "Task()",
        "posix" + "_spawn(&pid, path, nil, nil, argv, envp)",
        "let pipe = po" + "pen(command, \"r\")",
        "sys" + "tem(command)",
        "let shell = \"/bin/" + "sh\"",
        "let shell = \"/bin/" + "zsh\"",
        "try Pro" + "cess.run(url, arguments: [])",
        "let child: Pro" + "cess = .init()",
        "ex" + "ecv(path, argv)",
        "let pid = fo" + "rk()",
        "let task = try NSUserUnix" + "Task(url: url)",
        "let shell = \"/bin/k" + "sh\"",
    ]

    /// SEC-T13-03: the forbidden-API check passes on the repository, rejects process creation and shells outside
    /// `Overgrove/Execution/` (and test support), and accepts the same code in the allowed places.
    func testSECT13_03_ForbiddenAPICheckGuardsProcessCreation() async throws {
        let tree = try await RepositoryScript.run("scripts/lint/check-forbidden-apis.sh", executables: executables)
        XCTAssertEqual(tree.termination, .exited(code: 0), String(decoding: tree.stderr, as: UTF8.self))

        for snippet in Self.forbidden {
            let outside = try await check(snippet, as: "Overgrove/Features/Example.swift")
            XCTAssertEqual(outside.termination, .exited(code: 1), "not rejected: \(snippet)")
            XCTAssertTrue(
                String(decoding: outside.stderr, as: UTF8.self).contains("Overgrove/Features/Example.swift"), snippet)
            for allowed in ["Overgrove/Execution/Example.swift", "OvergroveTests/Support/Example.swift"] {
                let result = try await check(snippet, as: allowed)
                XCTAssertEqual(result.termination, .exited(code: 0), "\(allowed) should allow: \(snippet)")
            }
        }

        // Not over-blocking: `Font.system(...)`, `ProcessInfo`, `ProcessRunner` and `ProcessRequest` are fine anywhere.
        let harmless = try await check(
            "let font = Font.system(size: 12)\nlet id = ProcessInfo.processInfo.processIdentifier\n"
                + "let runner = ProcessRunner()\nlet request: ProcessRequest? = nil",
            as: "Overgrove/Features/Example.swift")
        XCTAssertEqual(harmless.termination, .exited(code: 0), String(decoding: harmless.stderr, as: UTF8.self))

        // Comment lines are prose (#223); code with a trailing comment, or indented code, is still checked.
        let comments = try await check(
            "// MARK: - " + "Pro" + "cess cap\n    /// " + "Pro" + "cess creation lives in Execution.\nlet x = 1",
            as: "Overgrove/Features/Example.swift")
        XCTAssertEqual(comments.termination, .exited(code: 0), String(decoding: comments.stderr, as: UTF8.self))
        for snippet in ["let child = " + "Pro" + "cess() // note", "    let child = " + "Pro" + "cess()"] {
            let result = try await check(snippet, as: "Overgrove/Features/Example.swift")
            XCTAssertEqual(result.termination, .exited(code: 1), "not rejected: \(snippet)")
        }
    }
}
