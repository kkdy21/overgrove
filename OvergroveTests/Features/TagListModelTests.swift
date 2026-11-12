import Foundation
import XCTest

@testable import Overgrove

/// `TagListModel` (#377, information-architecture.md §4.5): the TAGS section from cached refs, without views.
final class TagListModelTests: XCTestCase {
    private func oid(_ character: Character) -> ObjectID { ObjectID(String(repeating: character, count: 40))! }

    private func tag(
        _ name: String, commit: Character = "a", annotated: Character? = nil, days: Double? = nil,
        type: GitObjectType = .commit
    ) -> Tag {
        Tag(
            fullName: "refs/tags/\(name)", target: annotated.map(oid) ?? oid(commit),
            peeledTarget: annotated == nil ? nil : oid(commit),
            date: days.map { Date(timeIntervalSince1970: 1_000_000_000 - $0 * 86_400) }, objectType: type)
    }

    /// §4.2: newest first; equal or missing dates by name, missing dates last; no folders.
    func testNewestFirstThenByName() {
        let model = TagListModel(
            tags: [
                tag("v1.9", days: 30), tag("v1.10", days: 2), tag("release/b", days: nil), tag("release/a", days: nil),
                tag("v2.0-rc.1", days: 2), tag("v1.10.1", days: 1),
            ], detachedHeads: [])
        XCTAssertEqual(
            model.rows.map(\.name), ["v1.10.1", "v1.10", "v2.0-rc.1", "v1.9", "release/a", "release/b"])
        XCTAssertEqual(model.count, 6)
    }

    /// The row selects the commit an annotated tag points to, not the tag object.
    func testAnnotatedTagsSelectTheirCommit() throws {
        let model = TagListModel(
            tags: [tag("v1", commit: "c", annotated: "d", days: 1), tag("v2", commit: "e")], detachedHeads: [])
        let annotated = try XCTUnwrap(model.rows.first { $0.name == "v1" })
        XCTAssertEqual(annotated.commit, oid("c"))
        XCTAssertTrue(annotated.isAnnotated)
        XCTAssertTrue(annotated.accessibilityLabel.hasPrefix("Annotated tag v1"))
        let light = try XCTUnwrap(model.rows.first { $0.name == "v2" })
        XCTAssertEqual(light.commit, oid("e"))
        XCTAssertFalse(light.isAnnotated)
        XCTAssertTrue(light.accessibilityLabel.hasPrefix("Lightweight tag v2"))
    }

    /// #432: a tag of a tree, blob, or (older git's one-level peel) another tag has no commit, so choosing it selects
    /// nothing; the tooltip and label say what it names, and Copy SHA still has the object.
    func testATagOfSomethingElseThanACommitSelectsNothing() throws {
        let model = TagListModel(
            tags: [
                tag("tree", commit: "c", type: .tree), tag("blob", commit: "d", annotated: "e", type: .blob),
                tag("nested", commit: "f", annotated: "1", type: .tag),
            ], detachedHeads: [oid("c")])
        for (name, word, object) in [
            ("tree", "tree", oid("c")), ("blob", "file", oid("d")), ("nested", "tag", oid("f")),
        ] {
            let row = try XCTUnwrap(model.rows.first { $0.name == name })
            XCTAssertNil(row.commit, name)
            XCTAssertEqual(row.object, object, name)
            XCTAssertFalse(row.hasDetachedWorktree, name)
            XCTAssertTrue(row.help.contains("not a commit"), row.help)
            XCTAssertTrue(row.help.contains(word), row.help)
            XCTAssertFalse(row.help.contains("Commit "), row.help)
            XCTAssertTrue(row.accessibilityLabel.contains("not a commit"), row.accessibilityLabel)
        }
    }

    /// §4.3: the `tree` mark when a worktree's detached HEAD is on the tag's commit.
    func testDetachedWorktreeMark() {
        let model = TagListModel(
            tags: [tag("v1", commit: "c", annotated: "d"), tag("v2", commit: "e")], detachedHeads: [oid("c")])
        XCTAssertEqual(model.rows.map(\.hasDetachedWorktree), [true, false])
        XCTAssertTrue(model.rows[0].accessibilityLabel.contains("checked out"))
    }

    /// §4.5: at most `maximumRows` rows; the rest are counted. The filter looks at every tag, and its matches are capped
    /// the same way.
    func testRowsAreCappedAndTheFilterSeesEveryTag() {
        let count = TagListModel.maximumRows + 50
        let model = TagListModel(
            tags: (0..<count).map { tag("t\($0)", days: Double($0)) }, detachedHeads: [])
        XCTAssertEqual(model.count, count)

        let all = model.visible(query: nil)
        XCTAssertEqual(all.rows.count, TagListModel.maximumRows)
        XCTAssertEqual(all.hidden, 50)
        XCTAssertEqual(all.rows.first?.name, "t0", "newest first")

        let old = model.visible(query: "t249")
        XCTAssertEqual(old.rows.map(\.name), ["t249"], "a tag past the cap is still found")
        XCTAssertEqual(old.hidden, 0)
        XCTAssertEqual(model.visible(query: "nothing").rows, [])
    }

    /// Tag names come from the repository: control and bidi characters are escaped before they are drawn.
    func testNamesAreEscaped() {
        let model = TagListModel(tags: [tag("v1\u{202E}gpj.exe"), tag("bell\u{7}")], detachedHeads: [])
        for row in model.rows {
            XCTAssertFalse(row.name.unicodeScalars.contains { $0 == "\u{202E}" || $0 == "\u{7}" }, row.name)
            XCTAssertFalse(row.help.unicodeScalars.contains { $0 == "\u{202E}" || $0 == "\u{7}" }, row.help)
        }
    }

    /// The model rides along with LOCAL and REMOTE, so the sidebar needs nothing new from `AppState`.
    func testBranchModelCarriesTheTags() {
        let refs = RefParser.Listing(
            branches: [], tags: [tag("v1", commit: "c")], isPartial: false, skippedRecords: 0)
        let model = BranchListModel(refs: refs, checkedOut: [], remoteNames: [], detachedHeads: [oid("c")])
        XCTAssertEqual(model.tags.rows.map(\.name), ["v1"])
        XCTAssertTrue(model.tags.rows[0].hasDetachedWorktree)
    }
}

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
}
