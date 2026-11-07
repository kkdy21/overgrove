import Foundation
import XCTest

@testable import Overgrove

/// SEC-T15-06: a repository's `i18n.commitEncoding` / `i18n.logOutputEncoding` must not re-encode `-z` output (#205).
///
/// JOHAB maps the fullwidth `！` (U+FF01) to a NUL byte, so without the pinned output encoding a commit subject
/// containing it splits into extra fields: enough of them forge a whole record (security-review.md T15, E41).
final class OutputEncodingSecurityTests: XCTestCase {
    private var repository: GitTestRepository!
    private let hostileSubject = "a！b！c"

    override func setUp() async throws {
        repository = try await GitTestRepository.make()
        try await repository.git(["commit", "-q", "--allow-empty", "-m", "base"])
        try await repository.git(["commit", "-q", "--allow-empty", "-m", hostileSubject])
        try repository.write("f.txt", "x\n")
        try await repository.git(["add", "f.txt"])
        try await repository.git(["commit", "-q", "-m", "add f"])
        try repository.write("f.txt", "x\ny\n")
        try await repository.git(["stash", "push", "-q", "-m", "s！t"])
    }

    override func tearDown() {
        repository?.remove()
    }

    private func setEncoding(_ key: String, _ value: String) async throws {
        try await repository.git(["config", key, value])
    }

    /// The app's invocation: common safety arguments (including the pinned encoding) and environment allowlist.
    private func app(_ command: ReadOnlyGitCommand) async throws -> Data {
        try await repository.git(command.subcommandArguments()).stdout
    }

    /// Plain git with the same subcommand but none of Overgrove's arguments.
    private func plain(_ command: ReadOnlyGitCommand) async throws -> Data {
        try await ProcessRunner().run(
            ProcessRequest(
                executable: repository.environment.executable,
                arguments: try command.subcommandArguments(),
                environment: GitEnvironment.environment(parent: ProcessInfo.processInfo.environment),
                currentDirectory: repository.root,
                limits: .query
            )
        ).stdout
    }

    private func nulCount(_ data: Data) -> Int { data.reduce(0) { $1 == 0 ? $0 + 1 : $0 } }

    func testSECT15_06_GraphKeepsItsFieldsUnderHostileEncodings() async throws {
        for key in ["i18n.commitEncoding", "i18n.logOutputEncoding"] {
            try await setEncoding(key, "JOHAB")
            let page = try LogParser.parseGraph(try await app(.graphPage(skip: 0, limit: 10)))
            XCTAssertEqual(page.commits.map(\.subject), ["add f", hostileSubject, "base"], key)
            try await repository.git(["config", "--unset", key])
        }
        try await setEncoding("i18n.logOutputEncoding", "UTF-16")
        let page = try LogParser.parseGraph(try await app(.graphPage(skip: 0, limit: 10)))
        XCTAssertEqual(page.commits.count, 3, "UTF-16 output would otherwise make the whole page unparsable")
    }

    func testSECT15_06_CommitDetailAndStashListKeepTheirFields() async throws {
        try await setEncoding("i18n.commitEncoding", "JOHAB")
        let graph = try LogParser.parseGraph(try await app(.graphPage(skip: 0, limit: 10)))
        let hostile = try XCTUnwrap(graph.commits.first { $0.subject == hostileSubject })

        let meta = try LogParser.parseCommitMeta(try await app(.commitMeta(hostile.oid)))
        XCTAssertEqual(meta.message, hostileSubject + "\n")

        let stashes = try StashParser.parse(try await app(.stashList)).stashes
        XCTAssertEqual(stashes.map(\.message), ["s！t"])
    }

    /// The commits of a base comparison (#157) use the graph format too. Control: plain git shifts the fields.
    func testSECT15_06_ComparisonCommitsKeepTheirFields() async throws {
        try await repository.git(["branch", "basepoint", "HEAD~2"])
        try await setEncoding("i18n.commitEncoding", "JOHAB")
        let command = ReadOnlyGitCommand.commitsAhead(base: FullRefName("refs/heads/basepoint")!, limit: 10)

        let commits = try LogParser.parseGraph(try await app(command)).commits
        XCTAssertEqual(commits.map(\.subject), ["add f", hostileSubject])
        let plainOutput = try await plain(command)
        XCTAssertThrowsError(try LogParser.parseGraph(plainOutput), "control: the fields shift")
    }

    /// Negative control: without Overgrove's arguments the same repository does shift the fields.
    func testSECT15_06_control_PlainGitShiftsFields() async throws {
        try await setEncoding("i18n.commitEncoding", "JOHAB")
        let graph = try await plain(.graphPage(skip: 0, limit: 10))
        let pinned = try await app(.graphPage(skip: 0, limit: 10))
        XCTAssertEqual(try LogParser.parseGraph(pinned).commits.count, 3)
        XCTAssertEqual(nulCount(graph), nulCount(pinned) + 2, "each ！ became a NUL byte")
        XCTAssertThrowsError(try LogParser.parseGraph(graph), "two extra fields break the record grouping")

        let plainStash = try await plain(.stashList)
        let pinnedStash = try await app(.stashList)
        XCTAssertGreaterThan(nulCount(plainStash), nulCount(pinnedStash))
    }

    func testSECT15_06_InspectorReportsEncodingKeys() async throws {
        try await setEncoding("i18n.commitEncoding", "JOHAB")
        try await setEncoding("i18n.logOutputEncoding", "UTF-16")
        let listing = try ConfigParser.parse(try await app(.configList))
        let findings = RepoConfigInspector.inspect(listing).report.findings.filter { $0.entry.section == "i18n" }
        XCTAssertEqual(Set(findings.map(\.entry.variable)), ["commitencoding", "logoutputencoding"])
        XCTAssertTrue(findings.allSatisfy { $0.threat == "T15" && $0.handling == .reported })
    }
}
