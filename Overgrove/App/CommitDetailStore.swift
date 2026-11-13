import Foundation
import Observation

/// Reads one commit's detail and file patches (S-03, #69).
protocol CommitLoading: Sendable {
    func detail(_ repository: Repository, of commit: ObjectID) async -> Result<CommitDetail, GitError>
    func patch(
        _ repository: Repository, of commit: ObjectID, parent: ObjectID?, path: GitPath, originalPath: GitPath?
    ) async
        -> Result<PatchParser.Listing, GitError>
    /// The files changed from `base` to `target` (S-12, #388).
    func files(_ repository: Repository, from base: ObjectID, to target: ObjectID) async
        -> Result<NumstatParser.Files, GitError>
    /// The commits `target` has that `base` does not (S-12, #389).
    func commits(_ repository: Repository, from base: ObjectID, to target: ObjectID) async
        -> Result<LogParser.GraphPage, GitError>
}

extension CommitLoading {
    func files(_ repository: Repository, from base: ObjectID, to target: ObjectID) async
        -> Result<NumstatParser.Files, GitError>
    {
        .failure(.executableNotFound(path: "git"))
    }

    func commits(_ repository: Repository, from base: ObjectID, to target: ObjectID) async
        -> Result<LogParser.GraphPage, GitError>
    {
        .failure(.executableNotFound(path: "git"))
    }
}

/// The app's loader: `RepositoryService.commitDetail` (cached by object ID) and `commitPatch`.
struct LiveCommitLoader: CommitLoading {
    let services: @Sendable () async throws -> (GitClient, RepositoryService)

    static let live = LiveCommitLoader(services: { try await LiveGitClient.shared.services() })

    func detail(_ repository: Repository, of commit: ObjectID) async -> Result<CommitDetail, GitError> {
        guard let service = try? await services().1 else { return .failure(.executableNotFound(path: "git")) }
        return await service.commitDetail(repository, of: commit)
    }

    func patch(
        _ repository: Repository, of commit: ObjectID, parent: ObjectID?, path: GitPath, originalPath: GitPath?
    ) async
        -> Result<PatchParser.Listing, GitError>
    {
        guard let service = try? await services().1 else { return .failure(.executableNotFound(path: "git")) }
        return await service.commitPatch(
            repository, of: commit, parent: parent, path: path, originalPath: originalPath)
    }

    func files(_ repository: Repository, from base: ObjectID, to target: ObjectID) async
        -> Result<NumstatParser.Files, GitError>
    {
        guard let service = try? await services().1 else { return .failure(.executableNotFound(path: "git")) }
        return await service.compareCommits(repository, base: base, target: target)
    }

    func commits(_ repository: Repository, from base: ObjectID, to target: ObjectID) async
        -> Result<LogParser.GraphPage, GitError>
    {
        guard let service = try? await services().1 else { return .failure(.executableNotFound(path: "git")) }
        return await service.commitsBetween(repository, base: base, target: target)
    }
}

/// S-03 for the selected commit and the S-10 diff of a file picked in it (#69).
///
/// The graph row already has the metadata (`CommitNode`), so the header shows at once; the message body, committer,
/// and files load lazily. Results of an older selection are dropped.
@MainActor
@Observable
final class CommitDetailStore {
    enum Detail: Equatable {
        case loading
        case loaded(CommitDetail)
        case failed(String)
    }

    private(set) var commit: CommitNode?
    private(set) var detail: Detail?
    private(set) var selectedFile: FileStat?
    private(set) var fileDiff: DiffLoadState?
    /// `Show all n files` was pressed (screens.md S-03, many files).
    private(set) var showsAllFiles = false
    /// In-flight loads; tests await them.
    private(set) var task: Task<Void, Never>?
    private(set) var fileTask: Task<Void, Never>?

    private let loader: any CommitLoading
    private var repository: Repository?
    private var generation = 0
    private var fileGeneration = 0

    init(loader: any CommitLoading = LiveCommitLoader.live) {
        self.loader = loader
    }

    /// Shows `commit` of `repository`, loading its detail unless it is already shown.
    func show(_ commit: CommitNode, in repository: Repository) {
        guard self.commit?.oid != commit.oid || self.repository != repository else { return }
        clear()
        self.commit = commit
        self.repository = repository
        detail = .loading
        let generation = generation
        let loader = loader
        task = Task { [weak self] in
            let result = await loader.detail(repository, of: commit.oid)
            guard let self, generation == self.generation, !Task.isCancelled else { return }
            switch result {
            case .success(let detail): self.detail = .loaded(detail)
            case .failure(.cancelled): break
            case .failure(let error): self.detail = .failed(PathValidator.displayable(error.message))
            }
        }
    }

    /// Opens `file`'s patch in the center (S-10). Merges diff against their first parent, as the file list does.
    func selectFile(_ file: FileStat) {
        guard let commit, let repository, file.path.isRepresentable else { return }
        fileTask?.cancel()
        fileGeneration += 1
        selectedFile = file
        fileDiff = .loading
        let generation = fileGeneration
        let loader = loader
        let label = commit.oid.short + (commit.isMerge ? " · " + String(localized: "vs first parent") : "")
        fileTask = Task { [weak self] in
            let result = await loader.patch(
                repository, of: commit.oid, parent: commit.parents.first, path: file.path,
                originalPath: file.originalPath)
            guard let self, generation == self.fileGeneration, !Task.isCancelled else { return }
            switch result {
            case .success(let patch):
                // A file without a known status (a history row, #659) takes its kind from the patch git printed.
                let letter = file.status.map { String($0.code) } ?? Self.kindLetter(of: patch)
                let source = DiffDocument.Source(label: label, kindLetter: letter)
                self.fileDiff = .loaded(DiffDocument(listing: patch, path: file.path, source: source))
            case .failure(.cancelled):
                break
            case .failure(let error):
                self.fileDiff = .unavailable(PathValidator.displayable(error.message))
            }
        }
    }

    /// The change kind a patch shows: `A` for a new file, `D` for a deleted one, `R` and `C` for a rename or copy,
    /// `T` when git printed a type change as two blocks, `M` otherwise (#659).
    nonisolated static func kindLetter(of listing: PatchParser.Listing) -> String {
        guard listing.files.count == 1, let patch = listing.files.first else {
            return listing.files.count > 1 ? "T" : "M"
        }
        if patch.isNewFile { return "A" }
        if patch.isDeletedFile { return "D" }
        if patch.renameFrom != nil { return "R" }
        if patch.copyFrom != nil { return "C" }
        return "M"
    }

    /// Back to the graph (`⎋`).
    func clearFile() {
        fileTask?.cancel()
        fileGeneration += 1
        selectedFile = nil
        fileDiff = nil
    }

    func showAllFiles() {
        showsAllFiles = true
    }

    func clear() {
        task?.cancel()
        generation += 1
        clearFile()
        commit = nil
        repository = nil
        detail = nil
        showsAllFiles = false
    }
}
