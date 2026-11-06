import Foundation

@testable import Overgrove

/// Runs `scripts/make-fixture-repo.sh` (docs/testing/fixtures.md) into a temporary directory.
/// Set `OVERGROVE_KEEP_FIXTURES=1` to keep the output for debugging.
struct FixtureRepo {
    let root: URL
    var repository: URL { root.appendingPathComponent("repo") }
    var canary: URL { root.appendingPathComponent("canary") }

    static func make(malicious: Bool = false, file: StaticString = #filePath) async throws -> FixtureRepo {
        // .../OvergroveTests/Support/FixtureRepo.swift → repository root
        let sourceRoot = URL(fileURLWithPath: "\(file)").deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent()
        let script = sourceRoot.appendingPathComponent("scripts/make-fixture-repo.sh")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "overgrove-fixture-\(UUID().uuidString)")
        let result = try await ProcessRunner().run(
            ProcessRequest(
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: [script.path] + (malicious ? ["--malicious"] : []) + [root.path],
                environment: GitEnvironment.environment(parent: ProcessInfo.processInfo.environment),
                currentDirectory: nil,
                limits: ProcessLimits(timeout: .seconds(60), stdoutLimit: 1 << 20, stderrLimit: 1 << 20)
            )
        )
        guard result.termination == .exited(code: 0) else {
            throw NSError(
                domain: "FixtureRepo",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: String(decoding: result.stderr, as: UTF8.self)]
            )
        }
        return FixtureRepo(root: root)
    }

    func remove() {
        if ProcessInfo.processInfo.environment["OVERGROVE_KEEP_FIXTURES"] != "1" {
            try? FileManager.default.removeItem(at: root)
        }
    }

    func canaries() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: canary.path)) ?? []).sorted()
    }
}
