import Foundation
import XCTest

@testable import Overgrove

/// `RepositoryService.commitDetail` and `commitPatch` on real git (#69): merges diff against their first parent, root
/// commits list their files, and details are cached by object ID until `forget`.
final class CommitDetailServiceTests: XCTestCase {
    private var executables: TestExecutables!
    private var repository: GitTestRepository!
    private var markers: URL!

    override func setUp() async throws {
        executables = try TestExecutables()
        markers = executables.directory.appendingPathComponent("markers", isDirectory: true)
        repository = try await GitTestRepository.make()
        try repository.write("a.txt", "a\n")
        try await repository.git(["add", "a.txt"])
        try await repository.git(["commit", "-q", "-m", "root"])
        try await repository.git(["switch", "-q", "-c", "side"])
        try repository.write("side.txt", "s\n")
        try await repository.git(["add", "side.txt"])
        try await repository.git(["commit", "-q", "-m", "side work"])
        try await repository.git(["switch", "-q", "main"])
        try repository.write("main.txt", "m\n")
        try await repository.git(["add", "main.txt"])
        try await repository.git(["commit", "-q", "-m", "main work\n\nRefs: #12"])
        try await repository.git(["merge", "-q", "--no-ff", "-m", "Merge side", "side"])
    }

    override func tearDown() {
        repository?.remove()
        executables?.remove()
    }

    private var model: Repository {
        Repository(
            rootURL: repository.root, commonGitDirectoryURL: repository.root.appendingPathComponent(".git"),
            isBare: false)
    }

    private func makeService() throws -> RepositoryService {
        let gated = try executables.gatedGit(forwardingTo: repository.environment.executable, markers: markers)
        FileManager.default.createFile(atPath: markers.appendingPathComponent("release").path, contents: nil)
        return RepositoryService(
            client: GitClient(environment: GitEnvironment(executable: gated, version: repository.environment.version)))
    }

    private func calls(_ subcommand: String) -> Int {
        let log = (try? String(contentsOf: markers.appendingPathComponent("invocations.log"), encoding: .utf8)) ?? ""
        return log.split(separator: "\n").filter { $0 == subcommand }.count
    }

    private func oid(_ revision: String) async throws -> ObjectID {
        let output = try await repository.git(["rev-parse", revision])
        return try XCTUnwrap(ObjectID(String(decoding: output.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)))
    }

    func testMergeListsChangesAgainstItsFirstParentAndIsCached() async throws {
        let service = try makeService()
        let merge = try await oid("HEAD")

        let detail = try await service.commitDetail(model, of: merge).get()
        XCTAssertEqual(detail.parents.count, 2)
        XCTAssertEqual(detail.files.map(\.path.display), ["side.txt"], "vs the first parent (main)")
        XCTAssertEqual(detail.subject, "Merge side")

        let reads = calls("diff-tree")
        _ = try await service.commitDetail(model, of: merge).get()
        XCTAssertEqual(calls("diff-tree"), reads, "a commit never changes: cached")

        await service.forget(model)
        _ = try await service.commitDetail(model, of: merge).get()
        XCTAssertEqual(calls("diff-tree"), reads + 1, "forget drops it")
    }

    func testRootCommitAndMessageAndPatch() async throws {
        let service = try makeService()
        let root = try await oid("HEAD~1~1")
        let detail = try await service.commitDetail(model, of: root).get()
        XCTAssertEqual(detail.files.map(\.path.display), ["a.txt"])

        let main = try await oid("HEAD~1")
        let mainDetail = try await service.commitDetail(model, of: main).get()
        XCTAssertEqual(mainDetail.message, "main work\n\nRefs: #12\n")

        let patch = try await service.commitPatch(
            model, of: main, parent: mainDetail.parents.first, path: GitPath("main.txt")
        ).get()
        XCTAssertEqual(patch.files.count, 1)
        XCTAssertFalse(patch.isPartial)
    }
}
