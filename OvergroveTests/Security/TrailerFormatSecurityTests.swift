import Foundation
import XCTest

@testable import Overgrove

/// The graph format reads `Co-authored-by` trailers (#160). Repository-local `trailer.<key>.cmd` / `.command` runs a
/// program when `git interpret-trailers` adds that trailer; this checks that `%(trailers:…)` in a pretty format only
/// parses and never runs it (T4-style config execution, security-review.md §2).
final class TrailerFormatSecurityTests: XCTestCase {
    private var repository: GitTestRepository!

    override func setUp() async throws {
        repository = try await GitTestRepository.make()
    }

    override func tearDown() {
        repository?.remove()
    }

    private var cmdCanary: URL { repository.root.appendingPathComponent("canary-cmd") }
    private var commandCanary: URL { repository.root.appendingPathComponent("canary-command") }

    private func plantTrailerCommands() async throws {
        try await repository.git(["config", "trailer.co-authored-by.cmd", "touch '\(cmdCanary.path)'; echo x"])
        try await repository.git(["config", "trailer.co-authored-by.command", "touch '\(commandCanary.path)'; echo x"])
    }

    private var canariesFired: [String] {
        [cmdCanary, commandCanary].filter { FileManager.default.fileExists(atPath: $0.path) }.map(\.lastPathComponent)
    }

    func testGraphFormatReadsTrailersWithoutRunningTrailerCommands() async throws {
        try await repository.git([
            "commit", "-q", "--allow-empty", "-m",
            "with trailers\n\nCo-Authored-By: Claude <noreply@anthropic.com>\nco-authored-by: Alice <a@example.com>",
        ])
        try await plantTrailerCommands()

        let result = try await repository.git(ReadOnlyGitCommand.graphPage(skip: 0, limit: 10).subcommandArguments())
        let page = try LogParser.parseGraph(result.stdout)

        XCTAssertEqual(page.commits.first?.coAuthors, ["Claude <noreply@anthropic.com>", "Alice <a@example.com>"])
        XCTAssertTrue(AIAgentRule.builtIn.isAIAssisted(try XCTUnwrap(page.commits.first)))
        XCTAssertEqual(canariesFired, [], "a pretty format must not run trailer commands")
    }

    /// Negative control: the planted configuration is live — `interpret-trailers` does run it.
    func testNegativeControl_InterpretTrailersRunsThePlantedCommand() async throws {
        try await plantTrailerCommands()
        try repository.write("message.txt", "subject\n")

        try await repository.git(
            ["interpret-trailers", "--trailer", "co-authored-by=x", "message.txt"], allowFailure: true)

        XCTAssertFalse(canariesFired.isEmpty, "interpret-trailers should run trailer.<key>.cmd or .command")
    }
}
