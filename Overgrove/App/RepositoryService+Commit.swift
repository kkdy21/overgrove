import Foundation

/// The commit detail cache key (overview.md §5, #69): the object ID, scoped to the repository so `forget` can drop it.
struct CommitKey: Sendable, Hashable {
    let repositoryID: String
    let oid: ObjectID
}

/// One commit's detail and file patches (S-03, #69). Commands run where the graph's do (the repository's main
/// worktree, or its git directory when bare), with the repository's inspection; they read history only.
extension RepositoryService {
    /// Metadata and the changed files: merges against their first parent (screens.md S-03). Cached by object ID and
    /// never invalidated (a commit cannot change); the bounded cache evicts the least recently used.
    func commitDetail(_ repository: Repository, of commit: ObjectID) async -> Result<CommitDetail, GitError> {
        let key = CommitKey(repositoryID: repository.id, oid: commit)
        if let cached = commitDetails.value(for: key) { return .success(cached) }
        let result = await Self.readCommit(repository, commit, makeContext(repository))
        if case .success(let detail) = result, !detail.isPartial { commitDetails.insert(detail, for: key) }
        return result
    }

    /// One file's patch in the commit, against `parent` (the first parent for merges; `nil` for a root commit).
    func commitPatch(
        _ repository: Repository, of commit: ObjectID, parent: ObjectID?, path: GitPath, originalPath: GitPath? = nil
    ) async -> Result<PatchParser.Listing, GitError> {
        await Self.run(repository, makeContext(repository)) { client, directory, safety in
            let output = try await client.run(
                .commitPatch(commit, parent: parent, path: path, originalPath: originalPath), in: directory,
                safety: safety)
            return try PatchParser.parse(output.stdout, truncated: output.isTruncated)
        }
    }

    /// The files changed from `base` to `target` (S-12, #388): `commitFiles` with `base` in the parent's place, so
    /// `diff-tree` compares the two trees. No new command (git-command-catalog.md, #122). Not cached: pairs are many and
    /// the list is cheap next to the graph.
    func compareCommits(_ repository: Repository, base: ObjectID, target: ObjectID) async
        -> Result<NumstatParser.Files, GitError>
    {
        await Self.run(repository, makeContext(repository)) { client, directory, safety in
            let output = try await client.run(.commitFiles(target, firstParent: base), in: directory, safety: safety)
            return try NumstatParser.parseCommitFiles(output.stdout, truncated: output.isTruncated)
        }
    }

    private static func readCommit(
        _ repository: Repository, _ commit: ObjectID, _ context: Context
    ) async -> Result<CommitDetail, GitError> {
        await run(repository, context) { client, directory, safety in
            let metaOutput = try await client.run(.commitMeta(commit), in: directory, safety: safety)
            let meta = try LogParser.parseCommitMeta(metaOutput.stdout, truncated: metaOutput.isTruncated)
            let firstParent = meta.parents.count > 1 ? meta.parents.first : nil
            let filesOutput = try await client.run(
                .commitFiles(commit, firstParent: firstParent), in: directory, safety: safety)
            let files = try NumstatParser.parseCommitFiles(filesOutput.stdout, truncated: filesOutput.isTruncated)
            return meta.detail(files: files.files, isPartial: files.isPartial)
        }
    }

    /// Runs `body` in the repository's directory with its (cached) inspection, mapping failures.
    private static func run<Value: Sendable>(
        _ repository: Repository, _ context: Context,
        _ body: @Sendable (GitClient, URL, RepoSafetyContext) async throws -> Value
    ) async -> Result<Value, GitError> {
        let directory = repository.rootURL ?? repository.commonGitDirectoryURL
        do {
            let inspection = try await inspect(directory, probe: nil, context)
            guard let safety = inspection.safetyContext else {
                return .failure(.configInspectionFailed(reason: inspection.report.blockingReason ?? ""))
            }
            return .success(try await body(context.client, directory, safety))
        } catch let error as GitError {
            return .failure(error)
        } catch let error as ParseError {
            return .failure(GitError(error))
        } catch {
            return .failure(.cancelled)
        }
    }
}
