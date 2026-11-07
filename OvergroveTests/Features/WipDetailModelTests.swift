import Foundation
import XCTest

@testable import Overgrove

/// `WipDetailModel` (#66): screens.md S-02 from a worktree's `WorkingState`, without views.
final class WipDetailModelTests: XCTestCase {
    private func change(_ path: String, _ status: FileChange.Status, from original: String? = nil) -> FileChange {
        FileChange(path: GitPath(path), originalPath: original.map(GitPath.init), status: status)
    }

    private func state(
        staged: [FileChange] = [], unstaged: [FileChange] = [], untracked: [FileChange] = [],
        conflicted: [FileChange] = [], isPartial: Bool = false, skippedRecords: Int = 0
    ) -> WorkingState {
        WorkingState(
            headCommit: ObjectID("a91f3c2000000000000000000000000000000000"), head: .branch("main"),
            upstream: .none, stashCount: 0, staged: staged, unstaged: unstaged, untracked: untracked,
            conflicted: conflicted, isPartial: isPartial, skippedRecords: skippedRecords)
    }

    private func model(
        _ state: WorkingState, branch: String? = "main", untrackedLimit: Int = WipDetailModel.untrackedDisplayLimit
    ) -> WipDetailModel {
        WipDetailModel(
            entry: WorktreeListing.entry("/tmp/dev/api", branch: branch, isMain: true, state: .loaded(state)),
            home: "/tmp/dev", untrackedLimit: untrackedLimit)
    }

    /// S-02: CONFLICTED → STAGED → UNSTAGED → UNTRACKED; empty groups are hidden.
    func testGroupOrderHidesEmptyGroups() {
        let full = model(
            state(
                staged: [change("a", .added)], unstaged: [change("b", .modified)], untracked: [change("c", .untracked)],
                conflicted: [change("d", .conflicted(.bothModified))]))
        XCTAssertEqual(full.groups.map(\.group), [.conflicted, .staged, .unstaged, .untracked])

        let some = model(state(unstaged: [change("b", .modified)], untracked: [change("c", .untracked)]))
        XCTAssertEqual(some.groups.map(\.group), [.unstaged, .untracked])
        XCTAssertEqual(some.groups.map(\.countText), ["1", "1"])
    }

    /// `MM`: the same file in STAGED and UNSTAGED, counted once as a changed file.
    func testFileChangedInIndexAndWorktreeIsInBothGroups() {
        let model = model(
            state(staged: [change("src/logger.go", .modified)], unstaged: [change("src/logger.go", .modified)]))
        XCTAssertEqual(model.groups.map { $0.rows.map(\.fileName) }, [["logger.go"], ["logger.go"]])
        XCTAssertEqual(model.changedFileCount, 1)
        let staged = FileSelection(worktree: GitPath("/tmp/dev/api"), group: .staged, path: GitPath("src/logger.go"))
        let unstaged = FileSelection(
            worktree: GitPath("/tmp/dev/api"), group: .unstaged, path: GitPath("src/logger.go"))
        XCTAssertEqual(model.row(for: staged)?.group, .staged)
        XCTAssertEqual(model.row(for: unstaged)?.group, .unstaged)
    }

    /// Files keep git's order within a group.
    func testFilesKeepGitOrder() {
        let model = model(state(unstaged: [change("b.txt", .modified), change("a.txt", .deleted)]))
        XCTAssertEqual(model.groups.first?.rows.map(\.fileName), ["b.txt", "a.txt"])
        XCTAssertEqual(model.groups.first?.rows.map(\.kindLetter), ["M", "D"])
    }

    /// Renames share their common directory once: `internal/log/` + `{format.go → encoder.go}`.
    func testRenameDisplay() {
        func parts(_ path: String, from original: String) -> [String] {
            let parts = WipDetailModel.displayParts(change(path, .renamed(score: 90), from: original))
            return [parts.directory, parts.fileName]
        }
        XCTAssertEqual(
            parts("internal/log/encoder.go", from: "internal/log/format.go"),
            ["internal/log/", "{format.go → encoder.go}"])
        XCTAssertEqual(parts("b/x.go", from: "a/x.go"), ["", "{a/x.go → b/x.go}"])
        XCTAssertEqual(parts("new.txt", from: "old.txt"), ["", "{old.txt → new.txt}"])
        XCTAssertEqual(parts("src/a/new.go", from: "src/old.go"), ["src/", "{old.go → a/new.go}"])
        let plain = WipDetailModel.displayParts(change("src/main.go", .modified))
        XCTAssertEqual([plain.directory, plain.fileName], ["src/", "main.go"])

        let row = model(state(staged: [change("src/new.txt", .renamed(score: 100), from: "src/old.txt")])).groups[0]
            .rows[0]
        XCTAssertEqual(row.accessibilityLabel, "renamed, src/old.txt renamed to src/new.txt, staged")
        XCTAssertTrue(row.help.hasPrefix("src/old.txt → src/new.txt"))
    }

    func testSubmoduleIsMarked() {
        let submodule = FileChange(path: GitPath("vendor/lib"), status: .modified, isSubmodule: true)
        let row = model(state(unstaged: [submodule])).groups[0].rows[0]
        XCTAssertTrue(row.isSubmodule)
        XCTAssertTrue(row.accessibilityLabel.contains("submodule"))
    }

    func testConflictKindsAreNamed() {
        let rows = model(state(conflicted: ConflictKind.allCases.map { change("f-\($0.rawValue)", .conflicted($0)) }))
            .groups[0].rows
        XCTAssertEqual(
            rows.map(\.kindName),
            [
                "both deleted", "added by us", "deleted by them", "added by them", "deleted by us", "both added",
                "both modified",
            ])
        XCTAssertTrue(rows.allSatisfy { $0.kindLetter == "U" })
    }

    /// The untracked display limit (provisional 5,000, #91): `5,000+` and `Showing first … · N more`.
    func testUntrackedLimit() {
        XCTAssertEqual(WipDetailModel.untrackedDisplayLimit, 5_000)
        let untracked = (0..<5).map { change("u\($0).txt", .untracked) }
        let over = model(state(untracked: untracked), untrackedLimit: 3).groups[0]
        XCTAssertEqual(over.rows.count, 3)
        XCTAssertEqual(over.totalCount, 5)
        XCTAssertEqual(over.countText, "3+")
        XCTAssertEqual(over.limitNote, "Showing first 3 files · 2 more")

        let exactly = model(state(untracked: Array(untracked.prefix(3))), untrackedLimit: 3).groups[0]
        XCTAssertEqual(exactly.countText, "3")
        XCTAssertNil(exactly.limitNote)

        // Only untracked is limited.
        let staged = model(state(staged: untracked.map { change($0.path.display, .added) }), untrackedLimit: 3)
        XCTAssertEqual(staged.groups[0].rows.count, 5)
        XCTAssertEqual(WipDetailModel.formatted(5_000), "5,000")
    }

    /// Paths that are not UTF-8 are shown but cannot be selected (no file-level actions).
    func testUnrepresentablePathIsShownButNotSelectable() {
        let path = GitPath(raw: Data([0x62, 0x61, 0x64, 0xFF, 0x2E, 0x74, 0x78, 0x74]))
        let row = model(state(untracked: [FileChange(path: path, status: .untracked)])).groups[0].rows[0]
        XCTAssertFalse(row.isSelectable)
        XCTAssertTrue(row.help.contains("not valid UTF-8"))
        XCTAssertTrue(model(state(untracked: [change("ok.txt", .untracked)])).groups[0].rows[0].isSelectable)
    }

    /// File names and paths are escaped: no control or bidi characters reach the screen.
    func testPathsAreEscaped() {
        let model = model(
            state(
                unstaged: [change("dir\u{202E}/line\nbreak.txt", .modified)],
                untracked: [change("tab\there.txt", .untracked)]))
        let rows = model.groups.flatMap(\.rows)
        XCTAssertEqual(rows[0].directory, "dir\\u{202E}/")
        XCTAssertEqual(rows[0].fileName, "line\\u{A}break.txt")
        XCTAssertEqual(rows[1].fileName, "tab\\u{9}here.txt")
        for text in rows.flatMap({ [$0.directory, $0.fileName, $0.accessibilityLabel] }) {
            XCTAssertFalse(
                text.unicodeScalars.contains {
                    [.format, .control, .lineSeparator, .paragraphSeparator].contains($0.properties.generalCategory)
                }, text)
        }
    }

    /// The title, the worktree path, and a rename's original path are escaped too (security review of #66).
    func testHeaderAndRenameSourceAreEscaped() {
        let model = WipDetailModel(
            entry: WorktreeListing.entry(
                "/tmp/dev/evil\n\u{202E}wt", branch: "feat/x\u{2028}y", isMain: true,
                state: .loaded(state(staged: [change("new.txt", .renamed(score: 90), from: "old\u{202E}.txt")]))),
            home: "/tmp/dev")
        XCTAssertEqual(model.title, "feat/x\\u{2028}y")
        XCTAssertEqual(model.displayPath, "~/evil\\u{A}\\u{202E}wt")
        let row = model.groups[0].rows[0]
        XCTAssertEqual(row.fileName, "{old\\u{202E}.txt → new.txt}")
        XCTAssertTrue(row.help.hasPrefix("old\\u{202E}.txt → new.txt"), row.help)
        XCTAssertTrue(row.accessibilityLabel.contains("old\\u{202E}.txt renamed to new.txt"))
    }

    /// Copy Path is offered only when the copied text is exactly what the screen shows: a pasted line feed could run
    /// a shell command, and a lossy path points somewhere else (security review of #66).
    func testCopyPathOnlyForPlainPaths() {
        func copyable(_ path: GitPath) -> String? {
            WipDetailModel(
                entry: WorktreeListing.Entry(
                    worktree: Worktree(
                        path: path, head: nil, branch: "refs/heads/main", isMain: true, isDetached: false,
                        isBare: false, lock: .unlocked, isPrunable: false, prunableReason: nil),
                    state: .loaded(state())),
                home: "/tmp/dev"
            ).copyablePath
        }
        XCTAssertEqual(copyable(GitPath("/tmp/dev/my repo 🌳")), "/tmp/dev/my repo 🌳")
        XCTAssertNil(copyable(GitPath("/tmp/x\nrm -rf ~\n")))
        XCTAssertNil(copyable(GitPath("/tmp/evil\u{202E}gpj")))
        XCTAssertNil(copyable(GitPath(raw: Data([0x2F, 0x74, 0xFF]))))
    }

    /// A rename whose original path is not UTF-8 is not selectable either.
    func testRenameFromAnUnrepresentablePathIsNotSelectable() {
        let rename = FileChange(
            path: GitPath("new.txt"), originalPath: GitPath(raw: Data([0x6F, 0xFF])), status: .renamed(score: 100))
        XCTAssertFalse(model(state(staged: [rename])).groups[0].rows[0].isSelectable)
    }

    func testHeader() {
        let model = model(state(staged: [change("a", .added)]))
        XCTAssertEqual(model.title, "main")
        XCTAssertEqual(model.displayPath, "~/api")
        XCTAssertEqual(model.changedFileCount, 1)
        XCTAssertEqual(self.model(state(), branch: nil).title, "detached @ a91f3c2")
    }

    func testStates() {
        XCTAssertEqual(model(state()).content, .clean)
        func entry(_ state: WorktreeListing.State) -> WipDetailModel {
            WipDetailModel(entry: WorktreeListing.entry("/tmp/dev/x", branch: "x", state: state), home: "/tmp/dev")
        }
        XCTAssertEqual(entry(.missing).content, .missing)
        XCTAssertEqual(
            entry(.failed(.timeout(seconds: 15))).content,
            .unavailable("git did not respond within 15 seconds and was stopped."))
        XCTAssertEqual(
            entry(.notQueried(.foreignRepository)).content,
            .unavailable(
                "This worktree entry points at a folder that belongs to another repository, so Overgrove does not query it."
            ))
        guard case .unavailable(let blocked) = entry(.notQueried(.inspectionBlocked("x\u{202E}"))).content else {
            return XCTFail("expected unavailable")
        }
        XCTAssertTrue(blocked.hasSuffix("x\\u{202E}"))
    }

    func testWarningForPartialOrSkippedOutput() {
        XCTAssertNil(model(state(staged: [change("a", .added)])).warning)
        for partial in [state(isPartial: true), state(skippedRecords: 1)] {
            XCTAssertEqual(model(partial).warning, "Some changes could not be read, so this list may be incomplete.")
        }
    }

    func testSelectionOfAnotherWorktreeFindsNothing() {
        let model = model(state(staged: [change("a", .added)]))
        XCTAssertNil(
            model.row(for: FileSelection(worktree: GitPath("/tmp/dev/other"), group: .staged, path: GitPath("a"))))
        XCTAssertNil(
            model.row(for: FileSelection(worktree: GitPath("/tmp/dev/api"), group: .unstaged, path: GitPath("a"))))
    }
}
