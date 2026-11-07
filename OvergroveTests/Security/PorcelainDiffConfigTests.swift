import Foundation
import XCTest

@testable import Overgrove

/// SEC-T3-03 (#239): a repository's own diff configuration must not change the porcelain `git diff` output the app
/// reads (`worktreeDiff`, `worktreeNumstat`, `untrackedPreview`, `comparePatch`, `compareFiles`). With each setting
/// planted, the app's output is byte-identical to the output without it; the control (the same subcommand without
/// the pinning options and the common arguments) changes. `diff-tree` (plumbing) does not read these settings.
final class PorcelainDiffConfigTests: XCTestCase {
    private var repository: GitTestRepository!
    private var submodule: GitTestRepository!
    private let inspected = RepoSafetyContext(
        inspectedNeutralization: [], fetchAuthentication: [], trustedSSHCommand: nil)

    /// Each setting changes plain `git diff` output (Apple Git 2.50.1).
    private static let settings: [(key: String, value: String)] = [
        ("color.diff", "always"), ("diff.noprefix", "true"), ("diff.mnemonicPrefix", "true"),
        ("diff.suppressBlankEmpty", "true"), ("diff.srcPrefix", "X/"), ("diff.dstPrefix", "Y/"),
        ("diff.submodule", "log"), ("diff.submodule", "diff"),
    ]

    override func setUp() async throws {
        submodule = try await GitTestRepository.make()
        try submodule.write("s.txt", "s\n")
        try await submodule.git(["add", "s.txt"])
        try await submodule.git(["commit", "-q", "-m", "sub one"])

        repository = try await GitTestRepository.make()
        try repository.write("f.txt", "a\n\nb\n")
        try await repository.git(["add", "f.txt"])
        try await repository.git(["commit", "-q", "-m", "one"])
        try await repository.git(["branch", "base"])
        try await repository.git(
            ["-c", "protocol.file.allow=always", "submodule", "-q", "add", submodule.root.path, "sub"])
        try await repository.git(["commit", "-q", "-m", "add submodule"])

        // Working tree changes: a blank context line in f.txt, a moved submodule commit, an untracked file.
        try repository.write("f.txt", "a\n\nB\n")
        let inner = repository.root.appendingPathComponent("sub")
        try "s2\n".write(to: inner.appendingPathComponent("s.txt"), atomically: true, encoding: .utf8)
        try await repository.git(["-C", inner.path, "commit", "-q", "-a", "-m", "sub two"])
        try repository.write("u.txt", "u\n\nv\n")
    }

    override func tearDown() {
        repository?.remove()
        submodule?.remove()
    }

    private func commands() throws -> [ReadOnlyGitCommand] {
        let base = FullRefName("refs/heads/base")!
        let untracked = try XCTUnwrap(PathValidator.worktreeFile(GitPath("u.txt"), in: repository.root))
        return [
            .worktreeDiff(path: GitPath("f.txt"), staged: false),
            .worktreeDiff(path: GitPath("sub"), staged: false),
            .untrackedPreview(untracked),
            .comparePatch(base: base, path: GitPath("f.txt"), includeWorkingTree: true),
            .comparePatch(base: base, path: GitPath("sub"), includeWorkingTree: true),
            .compareFiles(base: base, includeWorkingTree: true),
            .worktreeNumstat(staged: false),
        ]
    }

    private func app(_ commands: [ReadOnlyGitCommand]) async throws -> [Data] {
        let client = GitClient(environment: repository.environment)
        var outputs: [Data] = []
        for command in commands {
            outputs.append(try await client.run(command, in: repository.root, safety: inspected).stdout)
        }
        return outputs
    }

    /// The same subcommands without the pinning options and without Overgrove's common arguments.
    private func plain(_ commands: [ReadOnlyGitCommand]) async throws -> [Data] {
        var outputs: [Data] = []
        for command in commands {
            let arguments = try command.subcommandArguments().filter {
                !ReadOnlyGitCommand.porcelainDiffOptions.contains($0)
            }
            let result = try await ProcessRunner().run(
                ProcessRequest(
                    executable: repository.environment.executable, arguments: arguments,
                    environment: GitEnvironment.environment(parent: ProcessInfo.processInfo.environment),
                    currentDirectory: repository.root, limits: .query))
            outputs.append(result.stdout)
        }
        return outputs
    }

    func testSECT3_03_RepositoryDiffConfigurationDoesNotChangeTheOutput() async throws {
        let commands = try commands()
        let baseline = try await app(commands)
        let plainBaseline = try await plain(commands)
        XCTAssertTrue(
            String(decoding: baseline[0], as: UTF8.self).contains("--- a/f.txt\n+++ b/f.txt\n"), "baseline prefixes")
        XCTAssertTrue(String(decoding: baseline[1], as: UTF8.self).contains("Subproject commit"), "short submodule")

        for (key, value) in Self.settings {
            try await repository.git(["config", key, value])
            let pinned = try await app(commands)
            for (index, command) in commands.enumerated() {
                XCTAssertEqual(pinned[index], baseline[index], "\(key)=\(value) changed \(command)")
            }
            let unpinned = try await plain(commands)
            XCTAssertNotEqual(unpinned, plainBaseline, "control: \(key)=\(value) changes plain git diff output")
            try await repository.git(["config", "--unset", key])
        }
    }
}
