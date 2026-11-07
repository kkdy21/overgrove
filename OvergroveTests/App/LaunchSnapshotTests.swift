import Darwin
import Foundation
import XCTest

@testable import Overgrove

/// The launch snapshot (ADR-0018, #109, security-review.md T19).
final class LaunchSnapshotTests: XCTestCase {
    private var root: URL!
    private var gitDirectory: URL!
    private var gitExecutable: URL!
    private var store: LaunchSnapshotStore!
    private let token = "ghp_abcdefghijklmnopqrstuvwxyz0123456789"
    private let secret = "s3cr3t-config-value"
    private let now = Date()

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("snapshot-\(UUID().uuidString)")
        gitDirectory = root.appendingPathComponent("repo/.git", isDirectory: true)
        for directory in ["", "worktrees/wt-1", "worktrees/wt-2"] {
            try FileManager.default.createDirectory(
                at: gitDirectory.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        for file in ["HEAD", "config", "packed-refs", "index", "worktrees/wt-1/HEAD", "worktrees/wt-2/HEAD"] {
            try Data("x".utf8).write(to: gitDirectory.appendingPathComponent(file))
        }
        gitExecutable = root.appendingPathComponent("git")
        try Data("#!".utf8).write(to: gitExecutable)
        store = LaunchSnapshotStore(
            directory: root.appendingPathComponent("Caches/LaunchSnapshots"), appVersion: "0.2.0 (7)")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private var repository: Repository {
        Repository(
            rootURL: gitDirectory.deletingLastPathComponent(), commonGitDirectoryURL: gitDirectory, isBare: false)
    }

    private func path(_ name: String) -> String { root.appendingPathComponent(name).path }

    private func change(_ name: String, _ status: FileChange.Status = .modified) -> FileChange {
        FileChange(path: GitPath(name), status: status)
    }

    /// A listing holding everything that must not reach the disk.
    private var hostileListing: WorktreeListing {
        let state = WorkingState(
            headCommit: ObjectID(String(repeating: "a", count: 40)), head: .branch("main"),
            upstream: .tracking(upstream: "origin/secret-upstream-name", ahead: 2, behind: 1), stashCount: 1,
            staged: [change("payroll-2027.xlsx")], unstaged: [change("notes/\(secret).txt")],
            untracked: [change("leak-\(token).env", .untracked)], conflicted: [], isPartial: false,
            skippedRecords: 0)
        let inspection = RepoConfigInspector.inspect(
            ConfigParser.Listing(
                entries: [
                    ConfigEntry(
                        scope: .local, section: "remote", subsection: "origin", variable: "url",
                        value: "https://kim:\(token)@git.internal.example/acme/api.git"),
                    ConfigEntry(
                        scope: .local, section: "core", subsection: nil, variable: "sshcommand",
                        value: "ssh -i /keys/\(secret)"),
                ], isPartial: false))
        func worktree(_ name: String, branch: String?, isMain: Bool = false, prunable: Bool = false) -> Worktree {
            Worktree(
                path: GitPath(path(name)), head: ObjectID(String(repeating: "b", count: 40)),
                branch: branch.map { "refs/heads/\($0)" }, isMain: isMain, isDetached: branch == nil, isBare: false,
                lock: .locked(reason: "release by \(secret)"), isPrunable: prunable,
                prunableReason: prunable ? "gitdir points nowhere" : nil)
        }
        var listing = WorktreeListing(
            entries: [
                WorktreeListing.Entry(
                    worktree: worktree("repo", branch: "main", isMain: true), state: .loaded(state),
                    inspection: inspection),
                WorktreeListing.Entry(
                    worktree: worktree("wt-1", branch: "feat/1"),
                    state: .failed(.nonZeroExit(code: 128, detail: MaskedText(masking: "fatal: \(token) at \(secret)")))
                ),
                WorktreeListing.Entry(worktree: worktree("wt-2", branch: nil, prunable: true), state: .missing),
            ], isPartial: false)
        listing.stashes = [
            Stash(
                index: 0, oid: ObjectID(String(repeating: "c", count: 40))!, subject: "WIP on main: \(secret)",
                branch: "main", message: secret, date: now, parents: [])
        ]
        listing.remoteNames = ["origin", "secret-remote"]
        return listing
    }

    private func snapshot(_ listing: WorktreeListing? = nil, at date: Date? = nil) throws -> LaunchSnapshot {
        try XCTUnwrap(
            LaunchSnapshot(
                listing: listing ?? hostileListing, focused: GitPath(path("repo")), repository: repository,
                appVersion: store.appVersion, gitExecutable: gitExecutable,
                gitVersion: GitVersion(major: 2, minor: 50, patch: 1),
                fingerprint: LaunchSnapshot.fingerprint(gitDirectory), now: date ?? now))
    }

    // MARK: SEC-T19-01

    func testSECT19_01_SnapshotHoldsOnlyTheSidebarSummary() throws {
        let saved = try snapshot()
        store.save(saved, for: repository)
        let json = try String(contentsOf: store.file(for: repository), encoding: .utf8)
        for leak in [
            token, secret, "kim", "git.internal.example", "acme/api", "secret-upstream-name", "payroll", "notes/",
            "leak-", "release by", "fatal", "WIP on main", "secret-remote", "sshcommand", "origin",
        ] {
            XCTAssertFalse(json.contains(leak), "the snapshot must not hold \(leak)")
        }
        let row = try XCTUnwrap(saved.rows.first { $0.isMain })
        XCTAssertEqual(row.branch, "main")
        XCTAssertEqual(row.changed, 3)
        XCTAssertEqual(row.ahead, 2)
        XCTAssertEqual(row.behind, 1)
        XCTAssertEqual(row.upstream, .tracking)
        XCTAssertTrue(row.isLocked, "the lock flag, not its reason")
        XCTAssertEqual(saved.rows.map(\.hasStatus), [true, false, false])
        XCTAssertEqual(saved.rows.last?.isMissing, true)
        XCTAssertEqual(saved.stashCount, 1)
    }

    func testFileNameAndPermissions() throws {
        store.save(try snapshot(), for: repository)
        let file = store.file(for: repository)
        XCTAssertEqual(file.lastPathComponent, LaunchSnapshot.hash(repository) + ".json")
        XCTAssertFalse(file.lastPathComponent.contains("repo"), "no repository path in the directory listing")
        var info = stat()
        XCTAssertEqual(lstat(file.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)
        XCTAssertEqual(lstat(store.directory.path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o700)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: store.directory.path)
        XCTAssertEqual(leftovers, [file.lastPathComponent], "no temporary file left")
    }

    func testLeftoversAreRemoved() throws {
        store.save(try snapshot(), for: repository)
        let temporary = store.directory.appendingPathComponent(".interrupted.tmp")
        try Data("partial".utf8).write(to: temporary)
        let old = store.directory.appendingPathComponent(String(repeating: "e", count: 64) + ".json")
        try Data("{}".utf8).write(to: old)
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-8 * 86_400)], ofItemAtPath: old.path)
        store.removeLeftovers(now: now)
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.file(for: repository).path), "a current one stays")
    }

    func testRoundTripAndRows() throws {
        let saved = try snapshot()
        store.save(saved, for: repository)
        XCTAssertEqual(store.load(for: repository, now: now), saved)

        let model = WorktreeListModel(snapshot: saved, home: root.path)
        XCTAssertEqual(model.rows.map(\.title), ["main", "feat/1", "detached @ bbbbbbb"])
        XCTAssertEqual(model.rows[0].subtitle, "~/repo")
        XCTAssertEqual(model.rows[0].badges, [.changed(3), .ahead(2), .behind(1), .locked])
        XCTAssertEqual(model.rows[1].badges, [.locked], "no status: no counts")
        XCTAssertEqual(model.rows[2].subtitle, "path missing")
        XCTAssertTrue(model.rows.allSatisfy { $0.accessibilityLabel.hasSuffix("updating") })
    }

    // MARK: SEC-T19-02

    func testSECT19_02_CorruptOrHostileFilesAreDroppedAndRemoved() throws {
        let good = try JSONEncoder().encode(try snapshot())
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: good) as? [String: Any])
        func mutated(_ change: (inout [String: Any]) -> Void) throws -> Data {
            var copy = json
            change(&copy)
            return try JSONSerialization.data(withJSONObject: copy)
        }
        func row(_ change: (inout [String: Any]) -> Void) throws -> Data {
            try mutated { object in
                var rows = object["rows"] as! [[String: Any]]
                change(&rows[0])
                object["rows"] = rows
            }
        }
        let cases: [(String, Data)] = [
            ("garbage", Data("not json".utf8)),
            ("oversized", Data(repeating: 0x20, count: LaunchSnapshot.maximumBytes + 1)),
            ("other format", try mutated { $0["format"] = 99 }),
            ("missing field", try mutated { $0["rows"] = nil }),
            ("negative count", try row { $0["changed"] = -1 }),
            ("huge count", try row { $0["ahead"] = 2_000_000 }),
            ("relative path", try row { $0["path"] = "repo" }),
            ("control character", try row { $0["path"] = "/tmp/a\u{0007}b" }),
            ("long branch", try row { $0["branch"] = String(repeating: "b", count: 300) }),
            ("bad head", try row { $0["head"] = "zzzz" }),
            ("too many rows", try mutated { $0["rows"] = Array(repeating: ($0["rows"] as! [Any])[0], count: 65) }),
            ("other repository", try mutated { $0["repositoryHash"] = String(repeating: "0", count: 64) }),
            (
                "future date",
                try mutated { $0["writtenAt"] = Date(timeIntervalSinceNow: 86_400).timeIntervalSinceReferenceDate }
            ),
        ]
        for (name, data) in cases {
            try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
            try data.write(to: store.file(for: repository))
            XCTAssertNil(store.load(for: repository, now: now), name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.file(for: repository).path), "\(name): removed")
        }

        // A FIFO or a directory in its place is refused without blocking.
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true)
        XCTAssertEqual(mkfifo(store.file(for: repository).path, 0o600), 0)
        XCTAssertNil(store.load(for: repository, now: now), "FIFO")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file(for: repository).path))
        try FileManager.default.createDirectory(at: store.file(for: repository), withIntermediateDirectories: false)
        XCTAssertNil(store.load(for: repository, now: now), "directory")
        try? FileManager.default.removeItem(at: store.file(for: repository))

        // A link to a valid snapshot is refused, not followed, and only the link is removed.
        let elsewhere = root.appendingPathComponent("elsewhere.json")
        try good.write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: store.file(for: repository), withDestinationURL: elsewhere)
        XCTAssertNil(store.load(for: repository, now: now))
        XCTAssertTrue(FileManager.default.fileExists(atPath: elsewhere.path), "the link target is untouched")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: store.file(for: repository).path))
    }

    // MARK: SEC-T19-04

    func testSECT19_04_SnapshotIsNotShownOnceSomethingChanged() throws {
        func check(_ name: String, rejection: LaunchSnapshot.Rejection, _ change: () throws -> Void) throws {
            store.save(try snapshot(), for: repository)
            try change()
            XCTAssertEqual(store.check(for: repository, now: now).failure, rejection, name)
            XCTAssertNil(store.load(for: repository, now: now), name)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.file(for: repository).path), name)
        }
        try check("HEAD moved", rejection: .repositoryChanged) {
            try Data("ref: refs/heads/other".utf8).write(to: gitDirectory.appendingPathComponent("HEAD"))
        }
        try check("a worktree's index changed", rejection: .repositoryChanged) {
            try Data("new".utf8).write(to: gitDirectory.appendingPathComponent("worktrees/wt-1/index"))
        }
        try check("a worktree was added", rejection: .repositoryChanged) {
            try FileManager.default.createDirectory(
                at: gitDirectory.appendingPathComponent("worktrees/wt-3"), withIntermediateDirectories: true)
        }
        try check("git was replaced", rejection: .gitChanged) {
            try FileManager.default.removeItem(at: gitExecutable)
            try Data("#!new".utf8).write(to: gitExecutable)
        }
        store.save(try snapshot(at: now.addingTimeInterval(-8 * 86_400)), for: repository)
        XCTAssertEqual(store.check(for: repository, now: now).failure, .expired)
        XCTAssertNil(store.load(for: repository, now: now))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.file(for: repository).path), "expired: removed")

        store.save(try snapshot(), for: repository)
        let otherBuild = LaunchSnapshotStore(directory: store.directory, appVersion: "0.2.0 (8)")
        XCTAssertEqual(otherBuild.check(for: repository, now: now).failure, .otherVersion)
    }
}

final class LaunchSnapshotFingerprintTests: XCTestCase {
    private var gitDirectory: URL!

    override func setUpWithError() throws {
        gitDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("fp-\(UUID().uuidString)/.git")
        try FileManager.default.createDirectory(at: gitDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: gitDirectory.deletingLastPathComponent())
    }

    /// Linked worktrees are stamped by position: their directory names (repository-chosen) are never written.
    func testSECT19_01_LinkedWorktreeNamesAreNotWritten() throws {
        let secretName = "customer-acme-merger"
        try FileManager.default.createDirectory(
            at: gitDirectory.appendingPathComponent("worktrees/\(secretName)"), withIntermediateDirectories: true)
        let stamps = try XCTUnwrap(LaunchSnapshot.fingerprint(gitDirectory))
        XCTAssertFalse(stamps.contains { $0.name.contains(secretName) })
        XCTAssertTrue(stamps.contains { $0.name == "worktrees/0/HEAD" })
    }

    /// A `worktrees` link is stamped as itself and not followed; a huge directory gives no fingerprint (T15).
    func testSECT19_02_WorktreesLinkAndFloodsAreBounded() throws {
        let elsewhere = gitDirectory.deletingLastPathComponent().appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(
            at: elsewhere.appendingPathComponent("outside-name"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: gitDirectory.appendingPathComponent("worktrees"), withDestinationURL: elsewhere)
        let linked = try XCTUnwrap(LaunchSnapshot.fingerprint(gitDirectory))
        XCTAssertEqual(linked.count, 5, "not listed through the link")

        try FileManager.default.removeItem(at: gitDirectory.appendingPathComponent("worktrees"))
        let flood = gitDirectory.appendingPathComponent("worktrees")
        try FileManager.default.createDirectory(at: flood, withIntermediateDirectories: true)
        for index in 0...LaunchSnapshot.maximumWorktreeScan {
            FileManager.default.createFile(atPath: flood.appendingPathComponent("w\(index)").path, contents: nil)
        }
        XCTAssertNil(LaunchSnapshot.fingerprint(gitDirectory), "too many entries: no snapshot")
    }
}

extension Result {
    fileprivate var failure: Failure? {
        if case .failure(let error) = self { return error }
        return nil
    }
}
