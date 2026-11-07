import Foundation

/// The outcome of loading one file's patch for S-10.
enum DiffLoadResult: Sendable, Equatable {
    case patch(PatchParser.Listing)
    /// Not shown; the text says why (escaped).
    case unavailable(String)
}

/// Loads the patch of a file picked in the WIP detail (#232).
protocol DiffLoading: Sendable {
    func load(_ file: FileSelection, worktree: Worktree, of repository: Repository, isSubmodule: Bool) async
        -> DiffLoadResult
}

/// The app's loader. Staged and unstaged files use `worktreeDiff(path:staged:)`, untracked files
/// `untrackedPreview(WorktreeFile)` (git-command-catalog.md). Before running either, the worktree is checked again and
/// its own configuration inspected (`LiveWorktreeInspector.verifiedInspection`), so the diff runs with that
/// worktree's safety context.
struct LiveDiffLoader: DiffLoading {
    let client: @Sendable () async throws -> GitClient

    static let live = LiveDiffLoader(client: { try await LiveGitClient.shared.client() })

    func load(_ file: FileSelection, worktree: Worktree, of repository: Repository, isSubmodule: Bool) async
        -> DiffLoadResult
    {
        if let reason = Self.refusal(file, isSubmodule: isSubmodule) { return .unavailable(reason) }
        guard worktree.path.isRepresentable,
            let directory = PathValidator.canonical(URL(fileURLWithPath: worktree.path.display, isDirectory: true))
        else { return .unavailable("The worktree folder could not be found.") }
        do {
            let client = try await self.client()
            guard
                let inspection = try await LiveWorktreeInspector.verifiedInspection(
                    at: directory, of: repository, client: client)
            else { return .unavailable(LiveWorktreeInspector.noLongerMatches) }
            guard let safety = inspection.safetyContext else {
                return .unavailable(
                    "Overgrove stopped querying this worktree for safety. "
                        + PathValidator.displayable(inspection.report.blockingReason ?? ""))
            }
            let command: ReadOnlyGitCommand
            switch file.group {
            case .staged, .unstaged:
                command = .worktreeDiff(
                    path: file.path, originalPath: file.originalPath, staged: file.group == .staged)
            case .untracked:
                // Only a regular file or symbolic link really inside the worktree (T14); a FIFO would stall git.
                guard let preview = PathValidator.worktreeFile(file.path, in: directory) else {
                    return .unavailable("This file cannot be previewed: it is not a regular file inside the worktree.")
                }
                command = .untrackedPreview(preview)
            case .conflicted:
                return .unavailable(Self.conflicted)
            }
            let output = try await client.run(command, in: directory, safety: safety)
            return .patch(try PatchParser.parse(output.stdout, truncated: output.isTruncated))
        } catch let error as GitError {
            return .unavailable(PathValidator.displayable(error.message))
        } catch is ParseError {
            return .unavailable("Overgrove could not read this diff.")
        } catch {
            return .unavailable(GitError.cancelled.message)
        }
    }

    static let conflicted = "Conflicted file. The combined diff is not shown yet; resolve it in Terminal."

    /// Files whose diff is not run at all.
    static func refusal(_ file: FileSelection, isSubmodule: Bool) -> String? {
        if !file.path.isRepresentable {
            return "This path is not valid UTF-8, so Overgrove cannot show its diff."
        }
        if file.group == .conflicted { return conflicted }
        // Submodules are diffed since #239: `--submodule=short` overrides `diff.submodule` and
        // `--ignore-submodules=dirty` keeps git out of the submodule's working tree (no filters run there).
        return nil
    }
}
