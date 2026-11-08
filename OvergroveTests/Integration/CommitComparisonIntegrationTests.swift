import Foundation
import XCTest

@testable import Overgrove

/// S-12 through the real path (#388): `commitFiles` and `commitPatch` with the base in the parent's place compare the
/// two trees, skipping what happened in between.
final class CommitComparisonIntegrationTests: XCTestCase {
    func testTwoCommitsAreComparedAsTrees() async throws {
        let repository = try await GitTestRepository.make()
        defer { repository.remove() }
        func commit(_ message: String) async throws -> ObjectID {
            try await repository.git(["add", "-A"])
            try await repository.git(["commit", "-q", "-m", message])
            let head = try await repository.git(["rev-parse", "HEAD"])
            return try XCTUnwrap(
                ObjectID(String(decoding: head.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
        }
        try repository.write("kept.txt", "one\n")
        try repository.write("changed.txt", "old line\n")
        let base = try await commit("base")
        try repository.write("temporary.txt", "here for a while\n")
        try repository.write("changed.txt", "middle line\n")
        _ = try await commit("middle")
        try FileManager.default.removeItem(at: repository.root.appendingPathComponent("temporary.txt"))
        try repository.write("changed.txt", "new line\n")
        try repository.write("added.txt", "fresh\n")
        let target = try await commit("target")

        let gitRepository = Repository(
            rootURL: repository.root, commonGitDirectoryURL: repository.root.appendingPathComponent(".git"),
            isBare: false)
        let client = GitClient(environment: repository.environment)
        let service = RepositoryService(client: client)
        let loader = LiveCommitLoader(services: { (client, service) })

        guard case .success(let list) = await loader.files(gitRepository, from: base, to: target) else {
            return XCTFail("no file list")
        }
        XCTAssertEqual(list.files.map(\.path.display), ["added.txt", "changed.txt"], "temporary.txt came and went")
        XCTAssertEqual(list.files.first { $0.path.display == "changed.txt" }?.status, .modified)

        guard
            case .success(let patch) = await loader.patch(
                gitRepository, of: target, parent: base, path: GitPath("changed.txt"), originalPath: nil)
        else { return XCTFail("no patch") }
        let lines = patch.files.flatMap(\.hunks).flatMap(\.lines).map { String(decoding: $0.content, as: UTF8.self) }
        XCTAssertEqual(lines, ["old line", "new line"], "base against target, not against the middle commit")

        guard case .success(let reversed) = await loader.files(gitRepository, from: target, to: base) else {
            return XCTFail("no reversed list")
        }
        XCTAssertEqual(reversed.files.first { $0.path.display == "added.txt" }?.status, .deleted)
    }
}
