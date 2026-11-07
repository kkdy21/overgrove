import Foundation
import XCTest

@testable import Overgrove

/// PERF-11 (PB-7) and PERF-12 (PB-8) on the bench repository through the app's loaders (#98, benchmark-plan.md §3).
///
/// - PERF-11: S-09's first page, 100 commits of one file with `--follow` (`LiveFileHistoryLoader`, which re-checks the
///   worktree and inspects its configuration first, as the app does).
/// - PERF-12: S-03's file list for a commit not yet cached (`LiveCommitLoader.detail`) and S-04's for the newest stash
///   (`LiveStashLoader.files`).
///
/// Skipped unless `OVERGROVE_BENCH_REPO` is set (`PerfRun`). Rendering is excluded.
final class DetailBenchmarkTests: XCTestCase {
    private static let runs = 21  // the first is a warm-up and is dropped (performance-budget.md §1)
    private static let historyPath = GitPath("src/d00/f00000.txt")
    private static let skippedTipCommits = 50

    private struct Bench {
        let client: GitClient
        let service: RepositoryService
        let repository: Repository
        let overview: RepositoryOverview
        let environment: GitEnvironment
    }

    private func bench() async throws -> Bench {
        let root = try PerfRun.benchRepository()
        let parent = PerfRun.isolatedParentEnvironment
        let environment = try await GitEnvironment.discoverForTesting(parentEnvironment: parent)
        let client = GitClient(environment: environment, parentEnvironment: parent)
        let service = RepositoryService(client: client)
        let repository = Repository(
            rootURL: root, commonGitDirectoryURL: root.appendingPathComponent(".git"), isBare: false)
        let overview = try await service.loadOverview(of: repository)
        return Bench(
            client: client, service: service, repository: repository, overview: overview, environment: environment)
    }

    /// PERF-11.
    func test_PERF_11_fileHistoryFirstPage() async throws {
        let bench = try await bench()
        let main = try XCTUnwrap(bench.overview.entries.first { $0.worktree.isMain }?.worktree)
        let loader = LiveFileHistoryLoader(client: { bench.client })
        let target = FileHistoryTarget(
            repository: bench.repository, worktree: main, head: main.head, path: Self.historyPath)
        var count = 0
        let samples = await PerfSamples.measure(runs: Self.runs) {
            if case .page(let page) = await loader.page(target, skip: 0, limit: 100) { count = page.entries.count }
        }
        XCTAssertGreaterThan(count, 0, "the bench file has history")

        var report = PerfReport(id: "PERF-11", title: "File history first page (PB-7)")
        report.note("git \(bench.environment.version), \(ProcessInfo.processInfo.activeProcessorCount) cores")
        report.note("`\(Self.historyPath.display)`, `--follow`, \(count) commits on the page")
        report.record("first page (100, --follow)", samples, budget: .seconds(1), budgetLabel: "1.0 s (PB-7)")
        report.finish()
    }

    /// PERF-12.
    func test_PERF_12_commitAndStashFileLists() async throws {
        let bench = try await bench()
        let main = try XCTUnwrap(bench.overview.entries.first { $0.worktree.isMain }?.worktree)
        // A different non-merge commit each run: the service caches details by OID, and the bench's merges keep
        // `main`'s tree, so they list no files.
        let listing = try await bench.client.run(.configList, in: bench.repository.rootURL, safety: .preInspection)
        let safety = try XCTUnwrap(RepoConfigInspector.inspect(try ConfigParser.parse(listing.stdout)).safetyContext)
        let page = try await bench.client.run(
            .graphPage(skip: 0, limit: 500), in: bench.repository.rootURL, safety: safety)
        let candidates = try LogParser.parseGraph(page.stdout, truncated: page.isTruncated).commits
            .filter { !$0.isMerge }.map(\.oid)
            // The newest commits on the bench's branch tips change no files (worktree setup); older ones change one.
            .dropFirst(Self.skippedTipCommits).map { $0 }
        XCTAssertGreaterThanOrEqual(candidates.count, Self.runs)
        let commits = LiveCommitLoader(services: { (bench.client, bench.service) })
        var commitFiles = 0
        var run = 0
        let commitSamples = await PerfSamples.measure(runs: Self.runs) {
            if case .success(let detail) = await commits.detail(bench.repository, of: candidates[run]) {
                commitFiles = max(commitFiles, detail.files.count)
            }
            run += 1
        }
        XCTAssertGreaterThan(commitFiles, 0)

        let stash = try XCTUnwrap(bench.overview.stashes.stashes.first, "the bench repository has stashes")
        let stashes = LiveStashLoader(client: { bench.client })
        var stashFiles = 0
        let stashSamples = await PerfSamples.measure(runs: Self.runs) {
            if case .files(let detail) = await stashes.files(of: stash, in: bench.repository, worktree: main) {
                stashFiles = detail.files.count
            }
        }
        XCTAssertGreaterThan(stashFiles, 0)

        var report = PerfReport(id: "PERF-12", title: "Commit and stash file lists (PB-8)")
        report.note("git \(bench.environment.version), \(ProcessInfo.processInfo.activeProcessorCount) cores")
        report.record(
            "commit detail, \(commitSamples.samples.count) commits, not cached (up to \(commitFiles) files)",
            commitSamples, budget: .milliseconds(200),
            budgetLabel: "200 ms (PB-8)")
        report.record(
            "stash files, newest (\(stashFiles) files)", stashSamples, budget: .milliseconds(200),
            budgetLabel: "200 ms (PB-8)")
        report.finish()
    }
}
