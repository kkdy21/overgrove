import Foundation
import XCTest

@testable import Overgrove

/// Runs `scripts/make-fixture-repo.sh` (docs/testing/fixtures.md §9) into a fresh temporary directory.
///
/// Layout of one fixture:
///
///     <temporary>/overgrove-fixture-<UUID>/   container, removed by `remove()`
///     ├── home/                               isolated HOME (empty; no user git configuration)
///     └── fixture/                            the script's OUT_DIR (`root`): repo/, worktrees/, remotes/, ...
///
/// The script runs with a complete, minimal environment: nothing is inherited from the test runner, HOME points at
/// `home/`, and `GIT_CONFIG_NOSYSTEM=1` / `GIT_CONFIG_GLOBAL=home/.gitconfig` keep system and user configuration out
/// (the script additionally pins `GIT_CONFIG_GLOBAL=/dev/null` itself). Use `environment` as the parent environment
/// of any git run against the fixture so the runner's HOME stays out of tests as well.
///
/// Building the `--malicious` fixture runs no git command after the payload configuration is written, so creating it
/// is safe; running git in it is what the canary tests (SEC-Tn-xx) are for.
///
/// Set `OVERGROVE_KEEP_FIXTURES=1` to keep fixtures (including ones from failed runs) and print their paths.
struct FixtureRepo: Sendable {
    enum Failure: Error, CustomStringConvertible {
        case scriptFailed(termination: ProcessTermination, timedOut: Bool, stderr: String, container: URL)
        case unexpectedOutput(String, container: URL)

        var description: String {
            switch self {
            case .scriptFailed(let termination, let timedOut, let stderr, _):
                "make-fixture-repo.sh failed (\(termination), timedOut: \(timedOut)): \(stderr)"
            case .unexpectedOutput(let output, _):
                "make-fixture-repo.sh printed an unexpected path: \(output)"
            }
        }

        /// A local push or fetch inside the setup script died: `fatal: the remote end hung up unexpectedly` (#234).
        ///
        /// Seen once in a full local run while several other test suites ran on the same machine; 40 parallel script
        /// runs did not reproduce it. The script talks only to local bare repositories, so the receiving `git`
        /// process failing to start or run (process limits under heavy load) is the likely cause. It is not a
        /// product failure, so `make` retries once.
        var isTransientSetupFailure: Bool {
            guard case .scriptFailed(_, let timedOut, let stderr, _) = self else { return false }
            return !timedOut && stderr.contains("the remote end hung up unexpectedly")
        }

        /// The fixture's container directory, already removed unless `OVERGROVE_KEEP_FIXTURES=1`.
        var container: URL {
            switch self {
            case .scriptFailed(_, _, _, let container), .unexpectedOutput(_, let container): container
            }
        }
    }

    /// Generation takes about 2 s (fixtures.md §1); the margin is for slow CI runners.
    static let limits = ProcessLimits(timeout: .seconds(120), stdoutLimit: 64 << 10, stderrLimit: 1 << 20)

    /// `.../OvergroveTests/Support/FixtureRepo.swift` → repository root. `#filePath` is this file, not the caller.
    static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("scripts/make-fixture-repo.sh")

    /// Holds `home` and `root`; symlinks resolved (`/private/var/...`), matching the paths git reports.
    let container: URL
    /// The script's output directory.
    let root: URL
    let home: URL
    let isMalicious: Bool

    var repository: URL { root.appendingPathComponent("repo", isDirectory: true) }
    var worktrees: URL { root.appendingPathComponent("worktrees", isDirectory: true) }
    var remotes: URL { root.appendingPathComponent("remotes", isDirectory: true) }
    /// `--malicious` only. Must stay empty under Overgrove's git arguments.
    var canary: URL { root.appendingPathComponent("canary", isDirectory: true) }
    /// `--malicious` only. The harmless scripts that write to `canary`.
    var payloads: URL { root.appendingPathComponent("payloads", isDirectory: true) }

    /// A linked worktree, e.g. `worktree("wt-locked")`.
    func worktree(_ name: String) -> URL {
        worktrees.appendingPathComponent(name, isDirectory: true)
    }

    /// Parent environment for app code under test (`GitClient(parentEnvironment:)`): only the isolated HOME and a
    /// temporary directory, so `GitEnvironment`'s passthrough cannot pick up the runner's HOME, USER or SSH agent.
    var environment: [String: String] {
        ["HOME": home.path, "TMPDIR": FileManager.default.temporaryDirectory.path]
    }

    /// Builds a fixture. Remove it with `remove()`, or use `XCTestCase.makeFixture(malicious:)`, which registers the
    /// removal as a teardown block so it also runs when the test fails or throws.
    static func make(malicious: Bool = false, script: URL = FixtureRepo.script) async throws -> FixtureRepo {
        do {
            return try await makeOnce(malicious: malicious, script: script)
        } catch let failure as Failure where failure.isTransientSetupFailure {
            // One more try in a fresh container: the failure was in the script's own setup, not in code under test.
            return try await makeOnce(malicious: malicious, script: script)
        }
    }

    private static func makeOnce(malicious: Bool, script: URL) async throws -> FixtureRepo {
        let container = try makeContainer()
        let home = container.appendingPathComponent("home", isDirectory: true)
        let root = container.appendingPathComponent("fixture", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: home, withIntermediateDirectories: false)
            let fixture = FixtureRepo(container: container, root: root, home: home, isMalicious: malicious)
            try await fixture.runScript(script)
            return fixture
        } catch {
            discard(container)
            throw error
        }
    }

    /// Removes the whole fixture, including the isolated HOME. Safe to call more than once.
    func remove() {
        Self.discard(container)
    }

    /// Names of canary files written so far (empty when no payload ran).
    func canaries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: canary.path)) ?? []).sorted()
    }

    // MARK: Private

    private func runScript(_ script: URL) async throws {
        // Run the same git the app would use (ADR-0008) by putting its directory first on PATH.
        let git = try await GitEnvironment.discoverForTesting(parentEnvironment: environment).executable
        let scriptEnvironment = environment.merging([
            "PATH": git.deletingLastPathComponent().path + ":" + GitEnvironment.path,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": home.appendingPathComponent(".gitconfig").path,
        ]) { _, new in new }
        let result = try await ProcessRunner().run(
            ProcessRequest(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: [script.path, "--quiet"] + (isMalicious ? ["--malicious"] : []) + ["--", root.path],
                environment: scriptEnvironment,
                currentDirectory: container,
                limits: Self.limits
            )
        )
        guard result.termination == .exited(code: 0), !result.timedOut else {
            throw Failure.scriptFailed(
                termination: result.termination,
                timedOut: result.timedOut,
                stderr: String(decoding: result.stderr, as: UTF8.self),
                container: container
            )
        }
        // `--quiet` prints only the resolved OUT_DIR on its last line.
        let output = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)
        let printed = output.split(separator: "\n").last.map(String.init) ?? ""
        guard printed == root.path else { throw Failure.unexpectedOutput(output, container: container) }
    }

    /// A new, uniquely named directory under the temporary directory, with symlinks resolved.
    private static func makeContainer() throws -> URL {
        let created = FileManager.default.temporaryDirectory
            .appendingPathComponent("overgrove-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: created, withIntermediateDirectories: false)
        guard let resolved = realpath(created.path, nil) else {
            discard(created)
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: created.path])
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    private static func discard(_ container: URL) {
        guard FileManager.default.fileExists(atPath: container.path) else { return }
        if ProcessInfo.processInfo.environment["OVERGROVE_KEEP_FIXTURES"] == "1" {
            print("OVERGROVE_KEEP_FIXTURES=1: kept fixture at \(container.path)")
            return
        }
        do {
            try FileManager.default.removeItem(at: container)
        } catch {
            print("warning: could not remove fixture at \(container.path): \(error)")
        }
    }
}

extension XCTestCase {
    /// Builds a fixture that is removed when the test ends, whether it passes, fails or throws.
    func makeFixture(malicious: Bool = false) async throws -> FixtureRepo {
        let fixture = try await FixtureRepo.make(malicious: malicious)
        addTeardownBlock { fixture.remove() }
        return fixture
    }
}
