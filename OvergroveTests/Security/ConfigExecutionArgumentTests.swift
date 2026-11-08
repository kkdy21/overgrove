import Foundation
import XCTest

@testable import Overgrove

/// Argument-level checks for T1–T8 (security-review.md §2): the safety arguments are on every command the app can
/// run, and no command can ask git for a patch through an external program or a signature check.
final class ConfigExecutionArgumentTests: XCTestCase {
    private static let oid = ObjectID(String(repeating: "ab", count: 20))!
    private static let parent = ObjectID(String(repeating: "cd", count: 20))!

    /// A real file for `untrackedPreview` (`PathValidator` only accepts files inside an existing worktree).
    private static let previewWorktree: URL = {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("overgrove-args-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? Data("a\n".utf8).write(to: directory.appendingPathComponent("a.txt"))
        return directory
    }()

    override class func tearDown() {
        try? FileManager.default.removeItem(at: previewWorktree)
        super.tearDown()
    }

    /// Every `ReadOnlyGitCommand` case, with representative values. `testEveryCaseIsListed` keeps it complete.
    private static func allQueries() throws -> [ReadOnlyGitCommand] {
        let file = try XCTUnwrap(PathValidator.worktreeFile(GitPath("a.txt"), in: previewWorktree))
        return [
            .version, .probeGitDirectory, .probeRepository, .configList, .worktreeList, .status, .refs,
            .aheadBehind(local: FullRefName("refs/heads/a")!, upstream: FullRefName("refs/remotes/origin/a")!),
            .stashList, .stashFiles(oid), .stashPatch(oid, path: GitPath("a.txt"), fromUntracked: false),
            .stashPatch(oid, path: GitPath("a.txt"), fromUntracked: true), .graphPage(skip: 0, limit: 10),
            .graphStream(limit: 10), .commitMeta(oid), .commitFiles(oid, firstParent: nil),
            .commitFiles(oid, firstParent: parent),
            .commitPatch(oid, parent: parent, path: GitPath("a.txt")),
            .commitPatch(oid, parent: nil, path: GitPath("a.txt")),
            .worktreeDiff(path: GitPath("a.txt"), staged: false), .worktreeDiff(path: GitPath("a.txt"), staged: true),
            .worktreeNumstat(staged: false), .worktreeNumstat(staged: true),
            .untrackedPreview(file), .fileHistory(path: GitPath("a.txt"), limit: 10),
            .compareFiles(base: FullRefName("refs/heads/main")!, includeWorkingTree: true),
            .comparePatch(base: FullRefName("refs/heads/main")!, path: GitPath("a.txt"), includeWorkingTree: true),
            .commitsAhead(base: FullRefName("refs/heads/main")!, limit: 10),
        ]
    }

    /// Final argument arrays of every query and of fetch, as `GitClient` assembles them.
    private static func allFinalArguments() throws -> [(label: String, arguments: [String], subcommandStart: Int)] {
        let environment = GitEnvironment(
            executable: URL(fileURLWithPath: "/usr/bin/git"), version: GitVersion(major: 2, minor: 50, patch: 1))
        let queries = try allQueries().map { command in
            let subcommand = try command.subcommandArguments()
            return ("\(command)", environment.arguments(for: subcommand), GitEnvironment.commonArguments.count)
        }
        let fetch = FetchCommand.fetch(remote: RemoteName("origin")!)
        let fetchAuthentication = ["-c", "credential.helper="]
        let fetchOverrides = fetch.configurationOverrides()
        let fetchArguments = environment.arguments(
            for: fetch.subcommandArguments(), fetchAuthentication: fetchAuthentication, fetchOverrides: fetchOverrides)
        let subcommandStart = GitEnvironment.commonArguments.count + fetchAuthentication.count + fetchOverrides.count
        return queries + [("fetch", fetchArguments, subcommandStart)]
    }

    func testEveryCaseIsListed() throws {
        XCTAssertEqual(
            Set(try Self.allQueries().map(CanaryHarness.caseName)), Set(CanaryHarness.CaseName.allCases))
    }

    /// `-c key=value` appears before the subcommand of every command.
    private func assertEveryCommandSets(_ setting: String, file: StaticString = #filePath, line: UInt = #line) throws {
        for entry in try Self.allFinalArguments() {
            let options = entry.arguments.prefix(entry.subcommandStart)
            let pairs = zip(options, options.dropFirst()).filter { $0.0 == "-c" }.map(\.1)
            XCTAssertTrue(pairs.contains(setting), "\(entry.label) lacks -c \(setting)", file: file, line: line)
        }
    }

    /// SEC-T1-03
    func testSECT1_03_EveryCommandDisablesFSMonitor() throws {
        try assertEveryCommandSets("core.fsmonitor=false")
    }

    /// SEC-T2-02
    func testSECT2_02_EveryCommandDisablesHooks() throws {
        try assertEveryCommandSets("core.hooksPath=/dev/null")
    }

    /// SEC-T8-02
    func testSECT8_02_EveryCommandDisablesAutoGCAndMaintenance() throws {
        try assertEveryCommandSets("gc.auto=0")
        try assertEveryCommandSets("maintenance.auto=false")
    }

    /// SEC-T13-02 (argument part): `git diff` would otherwise refresh and rewrite the index for a stat-dirty path,
    /// ignoring `--no-optional-locks` (#208). The setting is on every command, so a new porcelain diff is covered too.
    func testSECT13_02_EveryCommandDisablesDiffIndexRefresh() throws {
        try assertEveryCommandSets("diff.autoRefreshIndex=false")
    }

    /// SEC-T15-06 (argument part): every command pins the output encoding, so repository i18n config cannot
    /// re-encode `-z` output (#205).
    func testSECT15_06_EveryCommandPinsTheOutputEncoding() throws {
        try assertEveryCommandSets("i18n.logOutputEncoding=UTF-8")
    }

    /// SEC-T15-18 (argument part): no command reads a mailmap, so a repository's mailmap file (any path, or a FIFO)
    /// is never opened (#356).
    func testSECT15_18_EveryCommandTurnsTheMailmapOff() throws {
        try assertEveryCommandSets("log.mailmap=false")
        try assertEveryCommandSets("mailmap.file=")
        try assertEveryCommandSets("mailmap.blob=")
    }

    /// SEC-T7 (argument part of SEC-T7-01): signature checking is off on every command.
    func testEveryCommandDisablesSignatureDisplay() throws {
        try assertEveryCommandSets("log.showSignature=false")
    }

    /// SEC-T3-02: every case that can produce a diff disables external diff drivers and textconv, and the log-based
    /// cases never ask for a patch. A log case that asks for any diff output (`--numstat` for file history, #70, or a
    /// future `--raw`, `--name-status`, …) counts as a diff case and needs both flags.
    /// `git log` options that compute a diff without printing a patch.
    static let logDiffOutputOptions: Set<String> = [
        "--numstat", "--shortstat", "--dirstat", "--raw", "--name-only", "--name-status", "--summary",
        "--compact-summary", "--word-diff", "-W", "--function-context", "--check",
    ]

    func testSECT3_02_EveryDiffCaseDisablesExternalDiffAndTextconv() throws {
        // Every subcommand is classified, so a new one (`show`, `diff-index`, …) fails here until it is reviewed.
        let known: Set<String> = [
            "version", "rev-parse", "config", "worktree", "status", "for-each-ref", "rev-list", "stash", "log",
            "diff-tree", "diff",
        ]
        var diffCases = 0
        for command in try Self.allQueries() {
            let arguments = try command.subcommandArguments()
            XCTAssertTrue(known.contains(arguments.first ?? ""), "\(command): unreviewed subcommand")
            let isDiff =
                ["diff", "diff-tree"].contains(arguments.first) || arguments.starts(with: ["stash", "show"])
                || (arguments.first == "log" && !Self.logDiffOutputOptions.isDisjoint(with: arguments))
            if isDiff {
                diffCases += 1
                XCTAssertTrue(arguments.contains("--no-ext-diff"), "\(command)")
                XCTAssertTrue(arguments.contains("--no-textconv"), "\(command)")
            }
            if arguments.first == "log" {
                for patchOption in ["-p", "-u", "--patch", "--patch-with-stat", "--cc", "-c", "--stat"] {
                    XCTAssertFalse(arguments.contains(patchOption), "\(command) must not show a patch")
                }
            }
        }
        XCTAssertGreaterThanOrEqual(
            diffCases, 12, "stashFiles, stashPatch×2, commitFiles×2, commitPatch×2, diff×2, numstat×2, fileHistory…")
    }

    /// SEC-T7-02: no source file uses a signature format (`%G?`, `%GS`, `%GK`, `%GF`, `%GP`, `%GT`, …), which runs
    /// `gpg.program` even with `log.showSignature=false`. Comment lines are skipped: they may name the formats to
    /// document the ban.
    func testSECT7_02_NoSignatureFormatInSources() throws {
        let sources = Self.repositoryRoot.appendingPathComponent("Overgrove", isDirectory: true)
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(at: sources, includingPropertiesForKeys: [.isRegularFileKey]))
        let pattern = try NSRegularExpression(pattern: "%G[A-Z?]")
        var scanned = 0
        while let url = enumerator.nextObject() as? URL {
            guard url.pathExtension == "swift" else { continue }
            let text = try String(contentsOf: url, encoding: .utf8)
            scanned += 1
            for (number, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let code = String(line)
                if code.trimmingCharacters(in: .whitespaces).hasPrefix("//") { continue }
                let range = NSRange(code.startIndex..., in: code)
                XCTAssertNil(
                    pattern.firstMatch(in: code, range: range),
                    "\(url.lastPathComponent):\(number + 1) uses a %G format: \(code)")
            }
        }
        XCTAssertGreaterThan(scanned, 20, "the app sources were found")

        // The final arguments themselves, which also catches a format assembled from pieces.
        for entry in try Self.allFinalArguments() {
            for argument in entry.arguments {
                let range = NSRange(argument.startIndex..., in: argument)
                XCTAssertNil(pattern.firstMatch(in: argument, range: range), "\(entry.label): \(argument)")
            }
        }
    }

    /// `.../OvergroveTests/Security/ConfigExecutionArgumentTests.swift` → repository root.
    private static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
}
