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
/// - **Snapshot**: `LaunchSnapshotStore.load` — `lstat`, read, decode, bounds checks, the git executable's and the
///   §3 fingerprint's `lstat`s — and building the sidebar rows from it (`WorktreeListModel(snapshot:)`).
///
/// The first measurement (before the type existed) read a prototype of the same format; see
/// docs/performance/results/2026-11-08-perf13-launch-snapshot-gate.md.
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
        defer { try? FileManager.default.removeItem(at: directory) }
        let environment = try await GitEnvironment.discover(parentEnvironment: parent)
        let store = LaunchSnapshotStore(directory: directory, appVersion: "perf (13)")
        let listing = WorktreeListing(overview: loaded)
        // 64 rows (the cap): the 10 worktrees repeated under distinct paths.
        let manyEntries = (0..<LaunchSnapshot.maximumRows).map { index -> WorktreeListing.Entry in
            let entry = listing.entries[index % listing.entries.count]
            let worktree = entry.worktree
            return WorktreeListing.Entry(
                worktree: Worktree(
                    path: GitPath(worktree.path.display + "-\(index)"), head: worktree.head, branch: worktree.branch,
                    isMain: index == 0, isDetached: worktree.isDetached, isBare: false, lock: worktree.lock,
                    isPrunable: false, prunableReason: nil),
                state: entry.state)
        }
        var reports: [(String, PerfSamples, Int)] = []
        for (name, source) in [
            ("10 rows", listing), ("64 rows (the cap)", WorktreeListing(entries: manyEntries, isPartial: false)),
        ] {
            let snapshot = try XCTUnwrap(
                LaunchSnapshot(
                    listing: source, focused: nil, repository: repository, appVersion: store.appVersion,
                    gitExecutable: environment.executable, gitVersion: environment.version,
                    fingerprint: LaunchSnapshot.fingerprint(repository.commonGitDirectoryURL), now: Date()))
            store.save(snapshot, for: repository)
            let bytes = (try? Data(contentsOf: store.file(for: repository)).count) ?? 0
            let samples = try PerfSamples.measure(runs: Self.reads) {
                // What a relaunch does: every check of ADR-0018 §3–§4, then the sidebar rows.
                let read = try XCTUnwrap(store.load(for: repository))
                XCTAssertEqual(WorktreeListModel(snapshot: read).rows.count, snapshot.rows.count)
            }
            reports.append((name, samples, bytes))
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
