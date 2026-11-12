import Foundation
import XCTest

@testable import Overgrove

/// The refs query against real git (#377): an annotated tag carries its tagger date, so TAGS can sort it.
final class TagRefsIntegrationTests: XCTestCase {
    func testAnnotatedAndLightweightTagsBothHaveADate() async throws {
        let repository = try await GitTestRepository.make()
        defer { repository.remove() }
        try await repository.git(["commit", "-q", "--allow-empty", "-m", "one"])
        try await repository.git(["tag", "light"])
        try await repository.git(["tag", "-a", "annotated", "-m", "release"])

        let client = GitClient(environment: repository.environment)
        let safety = RepoSafetyContext(inspectedNeutralization: [], fetchAuthentication: [], trustedSSHCommand: nil)
        let output = try await client.run(.refs, in: repository.root, safety: safety)
        let tags = try RefParser.parse(output.stdout).tags
        XCTAssertEqual(Set(tags.map(\.shortName)), ["light", "annotated"])
        for tag in tags { XCTAssertNotNil(tag.date, tag.shortName) }
        let annotated = try XCTUnwrap(tags.first { $0.shortName == "annotated" })
        XCTAssertNotNil(annotated.peeledTarget)
        XCTAssertEqual(tags.map(\.objectType), [.commit, .commit])
    }

    /// #432: tags of a tree and a blob, lightweight and annotated, parse with their type and have no commit.
    func testTagsOfATreeAndABlobHaveNoCommit() async throws {
        let repository = try await GitTestRepository.make()
        defer { repository.remove() }
        try Data("a\n".utf8).write(to: repository.root.appendingPathComponent("a.txt"))
        try await repository.git(["add", "a.txt"])
        try await repository.git(["commit", "-q", "-m", "one"])
        try await repository.git(["tag", "tree-light", "HEAD^{tree}"])
        try await repository.git(["tag", "-a", "tree-annotated", "-m", "tree", "HEAD^{tree}"])
        try await repository.git(["tag", "blob-light", "HEAD:a.txt"])
        try await repository.git(["tag", "commit", "HEAD"])

        let client = GitClient(environment: repository.environment)
        let safety = RepoSafetyContext(inspectedNeutralization: [], fetchAuthentication: [], trustedSSHCommand: nil)
        let output = try await client.run(.refs, in: repository.root, safety: safety)
        let tags = Dictionary(uniqueKeysWithValues: try RefParser.parse(output.stdout).tags.map { ($0.shortName, $0) })
        XCTAssertEqual(tags["tree-light"]?.objectType, .tree)
        XCTAssertEqual(tags["tree-annotated"]?.objectType, .tree)
        XCTAssertNotNil(tags["tree-annotated"]?.peeledTarget)
        XCTAssertNil(tags["tree-light"]?.commit)
        XCTAssertNil(tags["tree-annotated"]?.commit)
        XCTAssertEqual(tags["blob-light"]?.objectType, .blob)
        XCTAssertNil(tags["blob-light"]?.commit)
        XCTAssertEqual(tags["commit"]?.objectType, .commit)
        XCTAssertNotNil(tags["commit"]?.commit)
    }

    /// #432: a tag of a tag. git that peels `*` all the way gives `commit` and the commit; git that peels one level
    /// gives `tag`, which has no commit. Either way the fields line up and nothing else is taken for the commit.
    func testATagOfATagIsTheCommitOrNoCommit() async throws {
        let repository = try await GitTestRepository.make()
        defer { repository.remove() }
        try await repository.git(["commit", "-q", "--allow-empty", "-m", "one"])
        try await repository.git(["tag", "-a", "inner", "-m", "inner"])
        try await repository.git(["tag", "-a", "outer", "-m", "outer", "inner"])
        let head = try await repository.git(["rev-parse", "HEAD"])
        let commit = ObjectID(
            String(decoding: head.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))

        let client = GitClient(environment: repository.environment)
        let safety = RepoSafetyContext(inspectedNeutralization: [], fetchAuthentication: [], trustedSSHCommand: nil)
        let output = try await client.run(.refs, in: repository.root, safety: safety)
        let outer = try XCTUnwrap(try RefParser.parse(output.stdout).tags.first { $0.shortName == "outer" })
        switch outer.objectType {
        case .commit: XCTAssertEqual(outer.commit, commit)
        case .tag: XCTAssertNil(outer.commit)
        default: XCTFail("\(outer.objectType)")
        }
    }
}
