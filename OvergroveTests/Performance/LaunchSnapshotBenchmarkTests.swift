import Darwin
import Foundation
import XCTest

@testable import Overgrove

/// PERF-13: the go / no-go measurement of ADR-0018 §7 (#109), before the launch snapshot is built.
///
/// After a relaunch the app opens the last repository with empty caches, so the sidebar waits for the first `.user`
/// load. A launch snapshot would replace that wait with reading one small file. Process start, window creation, and
/// drawing the rows cost the same either way, so only the part that differs is timed:
///
/// - **No snapshot**: what a relaunch does before the list can be drawn — find git (`GitEnvironment.discover`), a new
///   `GitClient` and `RepositoryService` (empty caches), and the first `.user` refresh of the bench repository.
/// - **Snapshot**: reading a file in the format ADR-0018 §1 describes (a prototype here; the real type comes only if
///   the gate passes) — `lstat`, read, decode, bounds checks, and the §3 fingerprint (`lstat` of `HEAD`,
///   `packed-refs`, `config`, `worktrees/`, and each worktree's `HEAD` and `index`).
///
/// The gate: the snapshot must save at least 150 ms at p95 (no-snapshot p95 − snapshot p95). Skipped unless
/// `OVERGROVE_BENCH_REPO` is set (`PerfRun`).
final class LaunchSnapshotBenchmarkTests: XCTestCase {
    private static let runs = 21  // the first is a warm-up and is dropped (performance-budget.md §1)
    private static let reads = 201
    static let gate: Duration = .milliseconds(150)

    func test_PERF_13_relaunchFirstListWithAndWithoutSnapshot() async throws {
        let root = try PerfRun.benchRepository()
        let parent = PerfRun.isolatedParentEnvironment
        let repository = Repository(
            rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false)

        var overview: RepositoryOverview?
        let relaunch = try await PerfSamples.measure(runs: Self.runs) {
            let environment = try await GitEnvironment.discover(parentEnvironment: parent)
            let service = RepositoryService(client: GitClient(environment: environment, parentEnvironment: parent))
            guard case .success(let loaded) = await service.refresh(repository, trigger: .user)?.result else {
                return XCTFail("the first load failed")
            }
            overview = loaded
        }
        let loaded = try XCTUnwrap(overview)
        XCTAssertEqual(loaded.entries.count, 10, "the bench repository has 10 worktrees")

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("perf13-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let gitDirectory = repository.commonGitDirectoryURL
        let tenRows = PrototypeSnapshot(overview: loaded, gitDirectory: gitDirectory, rows: nil)
        let maximumRows = PrototypeSnapshot(overview: loaded, gitDirectory: gitDirectory, rows: 64)
        var reports: [(String, PerfSamples, Int)] = []
        for (name, snapshot) in [("10 rows", tenRows), ("64 rows (the cap)", maximumRows)] {
            let file = directory.appendingPathComponent("\(name.prefix(2)).json")
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: file, options: .atomic)
            let samples = try PerfSamples.measure(runs: Self.reads) {
                let read = try PrototypeSnapshot.read(file)
                XCTAssertEqual(read.rows.count, snapshot.rows.count)
                XCTAssertEqual(PrototypeSnapshot.fingerprint(gitDirectory), read.fingerprint, "unchanged repository")
            }
            reports.append((name, samples, data.count))
        }

        let tenRowRead = reports[0].1
        let gain = relaunch.p95 - tenRowRead.p95
        var report = PerfReport(id: "PERF-13", title: "Relaunch first worktree list, with and without a snapshot")
        report.note(
            "\(ProcessInfo.processInfo.activeProcessorCount) cores; rendering and app launch are excluded (same in both)"
        )
        report.record("no snapshot: discover git + first .user load (10 worktrees)", relaunch)
        for (name, samples, bytes) in reports {
            report.record("snapshot read + checks + fingerprint, \(name), \(bytes) bytes", samples)
        }
        report.record(
            "gain at p95 (no snapshot − 10-row snapshot)", value: PerfReport.format(gain),
            budgetLabel: "≥ 150 ms (ADR-0018 §7)")
        report.note(
            gain >= Self.gate ? "gate passed: build the snapshot (#109)" : "gate not met: stop and reject ADR-0018")
        report.finish()
        if !PerfRun.isReportOnly {
            XCTAssertGreaterThanOrEqual(gain, Self.gate, "ADR-0018 §7: the snapshot saves less than 150 ms at p95")
        }
    }
}

/// The ADR-0018 §1 fields, only to time reading them. Not the app's type.
private struct PrototypeSnapshot: Codable {
    struct Row: Codable {
        let path: String
        let isMain: Bool
        let branch: String?
        let head: String?
        let isLocked: Bool
        let isPrunable: Bool
        let changed: Int
        let untracked: Int
        let conflicts: Int
        let ahead: Int?
        let behind: Int?
        let upstreamState: Int
    }

    struct Stat: Codable, Equatable {
        let path: String
        let device: Int64
        let inode: UInt64
        let size: Int64
        let modified: Double
        let changed: Double
    }

    let format: Int
    let appVersion: String
    let gitVersion: String
    let writtenAt: Date
    let repositoryHash: String
    let rows: [Row]
    let stashCount: Int
    let focused: String?
    let fingerprint: [Stat?]

    init(overview: RepositoryOverview, gitDirectory: URL, rows count: Int?) {
        let source = overview.entries.map { entry -> Row in
            let state: WorkingState? = if case .loaded(let state) = entry.status { state } else { nil }
            let (ahead, behind): (Int?, Int?) =
                if case .tracking(_, let ahead, let behind) = state?.upstream { (ahead, behind) } else { (nil, nil) }
            return Row(
                path: entry.worktree.path.display, isMain: entry.worktree.isMain,
                branch: entry.worktree.branchShortName, head: entry.worktree.head?.short,
                isLocked: entry.worktree.lock != .unlocked, isPrunable: entry.worktree.isPrunable,
                changed: (state?.staged.count ?? 0) + (state?.unstaged.count ?? 0),
                untracked: state?.untracked.count ?? 0, conflicts: state?.conflicted.count ?? 0, ahead: ahead,
                behind: behind, upstreamState: 0)
        }
        let wanted = count ?? source.count
        rows = (0..<wanted).map { source[$0 % source.count] }
        format = 1
        appVersion = "0.2.0 (1)"
        gitVersion = "2.50.1"
        writtenAt = Date()
        repositoryHash = String(repeating: "a", count: 64)
        stashCount = 0
        focused = source.first?.path
        fingerprint = Self.fingerprint(gitDirectory)
    }

    /// ADR-0018 §3: `HEAD`, `packed-refs`, `config`, `worktrees/`, and each worktree's `HEAD` and `index`.
    static func fingerprint(_ gitDirectory: URL) -> [Stat?] {
        var paths = ["HEAD", "packed-refs", "config", "worktrees", "index"].map {
            gitDirectory.appendingPathComponent($0).path
        }
        let linked = gitDirectory.appendingPathComponent("worktrees")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: linked.path))?.sorted() ?? []
        for name in names.prefix(64) {
            paths.append(linked.appendingPathComponent(name).appendingPathComponent("HEAD").path)
            paths.append(linked.appendingPathComponent(name).appendingPathComponent("index").path)
        }
        return paths.map { path in
            var info = stat()
            guard lstat(path, &info) == 0 else { return nil }
            return Stat(
                path: path, device: Int64(info.st_dev), inode: UInt64(info.st_ino), size: Int64(info.st_size),
                modified: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9,
                changed: Double(info.st_ctimespec.tv_sec) + Double(info.st_ctimespec.tv_nsec) / 1e9)
        }
    }

    /// ADR-0018 §4: a regular file of at most 256 KiB, decoded, every number and string within its bounds.
    static func read(_ file: URL) throws -> PrototypeSnapshot {
        var info = stat()
        guard lstat(file.path, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size <= 256 * 1024 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let snapshot = try JSONDecoder().decode(PrototypeSnapshot.self, from: try Data(contentsOf: file))
        let numbers = snapshot.rows.flatMap { [$0.changed, $0.untracked, $0.conflicts, $0.ahead ?? 0, $0.behind ?? 0] }
        guard snapshot.format == 1, snapshot.rows.count <= 64, numbers.allSatisfy({ (0...1_000_000).contains($0) }),
            snapshot.rows.allSatisfy({
                $0.path.hasPrefix("/") && $0.path.utf8.count <= 1_024 && ($0.branch?.utf8.count ?? 0) <= 256
                    && !$0.path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            })
        else { throw CocoaError(.fileReadCorruptFile) }
        return snapshot
    }
}
