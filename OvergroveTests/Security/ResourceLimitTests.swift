import Darwin
import Foundation
import XCTest

@testable import Overgrove

/// T15 (security-review.md §2): pathological output cannot exhaust memory, and truncated output is parsed safely.
/// SEC-T15-02 (timeout, no zombie) is `ProcessRunnerTests.testSECT15_02_TimeoutTerminatesAndLeavesNoZombie`; the
/// output cap itself is also checked by `ProcessRunnerTests.testSECT15_01_StdoutIsCappedAndMarkedTruncated`.
final class ResourceLimitTests: XCTestCase {
    // MARK: SEC-T15-01

    /// This process's physical memory footprint, as Activity Monitor reports it.
    private func physicalFootprint() throws -> Int {
        var info = rusage_info_v4()
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        XCTAssertEqual(status, 0, "proc_pid_rusage failed")
        return Int(info.ri_phys_footprint)
    }

    /// `head -c <bytes> /dev/zero` with the app's query limits (10 MB stdout).
    private func produce(_ bytes: Int) async throws -> ProcessResult {
        try await ProcessRunner().run(
            ProcessRequest(
                executable: URL(fileURLWithPath: "/usr/bin/head"),
                arguments: ["-c", String(bytes), "/dev/zero"],
                environment: ["PATH": GitEnvironment.path],
                currentDirectory: nil,
                limits: .query
            )
        )
    }

    /// SEC-T15-01: 20 MB of output (and, to make buffering obvious, 200 MB) stops at the 10 MB query cap, and the
    /// process's memory grows by about the cap, not by what the producer wrote.
    func testSECT15_01_OutputIsCappedAndMemoryStaysNearTheCap() async throws {
        let cap = ProcessLimits.query.stdoutLimit
        for size in [20 << 20, 200 << 20] {
            let before = try physicalFootprint()
            let result = try await produce(size)
            let growth = try physicalFootprint() - before

            XCTAssertTrue(result.stdoutTruncated, "\(size) bytes")
            XCTAssertEqual(result.stdout.count, cap, "\(size) bytes")
            XCTAssertFalse(result.timedOut)
            // The kept output is one cap; allow the same again for buffer growth and allocator slack.
            XCTAssertLessThan(growth, 2 * cap + (4 << 20), "\(size) bytes: grew \(growth >> 20) MB")
            withExtendedLifetime(result) {}
        }
    }

    // MARK: SEC-T15-03

    /// One command's real output and the parse of a truncated prefix, compared with the full parse.
    private struct Case {
        let name: String
        let command: ReadOnlyGitCommand
        let directory: URL?
        /// Records of a parse, flattened to comparable strings, plus `isPartial`. Throws `ParseError`.
        let records: (Data, Bool) throws -> (records: [String], isPartial: Bool)
    }

    private func cases(_ context: IntegrationContext) async throws -> [Case] {
        let repo = context.fixture.repository
        let graph = try await context.graph()
        let stashes = try StashParser.parse(try await context.run(.stashList)).stashes
        let stash = try XCTUnwrap(stashes.first)
        let renameCommit = try context.commit("c46c37d", in: graph)
        return [
            Case(name: "worktree list", command: .worktreeList, directory: repo) { data, truncated in
                let listing = try WorktreeParser.parse(data, truncated: truncated)
                return (listing.worktrees.map { "\($0.path.display) \($0.branch ?? "-")" }, listing.isPartial)
            },
            Case(name: "status", command: .status, directory: repo) { data, truncated in
                let state = try StatusParser.parse(data, truncated: truncated)
                let all = [("S", state.staged), ("U", state.unstaged), ("?", state.untracked), ("C", state.conflicted)]
                return (all.flatMap { tag, list in list.map { "\(tag) \($0.path.display)" } }, state.isPartial)
            },
            Case(name: "stash list", command: .stashList, directory: repo) { data, truncated in
                let listing = try StashParser.parse(data, truncated: truncated)
                return (listing.stashes.map(\.oid.hex), listing.isPartial)
            },
            Case(name: "graph page", command: .graphPage(skip: 0, limit: 500), directory: repo) { data, truncated in
                let page = try LogParser.parseGraph(data, truncated: truncated)
                return (page.commits.map(\.oid.hex), page.isPartial)
            },
            Case(name: "refs", command: .refs, directory: repo) { data, truncated in
                let listing = try RefParser.parse(data, truncated: truncated)
                return (listing.branches.map(\.fullName) + listing.tags.map(\.fullName), listing.isPartial)
            },
            Case(name: "commit files", command: .commitFiles(renameCommit.oid, firstParent: nil), directory: repo) {
                data, truncated in
                let files = try NumstatParser.parseCommitFiles(data, truncated: truncated)
                return (files.files.map(\.path.display), files.isPartial)
            },
            Case(name: "stash files", command: .stashFiles(stash.oid), directory: repo) { data, truncated in
                let files = try NumstatParser.parseStashFiles(data, truncated: truncated)
                return (files.files.map(\.path.display), files.isPartial)
            },
            Case(name: "config list", command: .configList, directory: repo) { data, truncated in
                let listing = try ConfigParser.parse(data, truncated: truncated)
                return (listing.entries.map(\.key), listing.isPartial)
            },
        ]
    }

    /// Bytes at the start of an output where a cut may fail closed instead of giving a partial result.
    private static let headerRegion = 256

    /// SEC-T15-03: real output of every parsed command, cut at many points as the output cap would cut it, parses
    /// without error into a partial result whose records are a prefix of the full result. Grouped records (status
    /// categories, refs then tags) must be a prefix within each group. Only a cut inside the first 256 bytes (the
    /// status header) may instead fail with `ParseError`.
    func testSECT15_03_TruncatedRealOutputParsesToAPrefix() async throws {
        let context = try await IntegrationContext.make(fixture: try await makeFixture())
        for item in try await cases(context) {
            let full = try await context.run(item.command, in: item.directory)
            let complete = try item.records(full, false)
            XCTAssertFalse(complete.isPartial, item.name)
            XCTAssertFalse(complete.records.isEmpty, "\(item.name): the fixture has data")

            let step = max(1, full.count / 40)
            let cuts = Set(Array(stride(from: 0, to: full.count, by: step)) + [1, full.count - 1]).sorted()
            for cut in cuts where cut < full.count {
                do {
                    let partial = try item.records(full.prefix(cut), true)
                    XCTAssertTrue(partial.isPartial, "\(item.name) cut at \(cut)/\(full.count)")
                    XCTAssertTrue(
                        isGroupedPrefix(partial.records, of: complete.records),
                        "\(item.name) cut at \(cut)/\(full.count): \(partial.records) is not a prefix")
                } catch is ParseError where cut < Self.headerRegion {
                    // A cut inside the mandatory header (status `# branch.oid`) fails closed. The 10 MB cap can
                    // never cut there, so this is safe and not a partial-result case.
                    continue
                } catch {
                    XCTFail("\(item.name) cut at \(cut)/\(full.count) threw \(error)")
                }
            }
        }
    }

    /// `partial` is a prefix of `full` within each group (records are tagged by their first word or ref namespace).
    private func isGroupedPrefix(_ partial: [String], of full: [String]) -> Bool {
        func group(_ record: String) -> String {
            if record.hasPrefix("refs/tags/") { return "tags" }
            if record.hasPrefix("refs/") { return "branches" }
            let tag = record.split(separator: " ", maxSplits: 1).first.map(String.init) ?? ""
            return ["S", "U", "?", "C"].contains(tag) ? tag : ""
        }
        let fullGroups = Dictionary(grouping: full, by: group)
        for (key, records) in Dictionary(grouping: partial, by: group) {
            guard let complete = fullGroups[key], complete.starts(with: records) else { return false }
        }
        return true
    }
}
