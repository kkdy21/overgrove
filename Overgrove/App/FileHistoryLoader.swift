import Foundation

/// Which file's history S-09 shows (#70): a path as seen from one worktree's HEAD.
struct FileHistoryTarget: Sendable, Hashable {
    let repository: Repository
    let worktree: Worktree
    /// The worktree's HEAD when the history was asked for (from its latest status, else `worktree list`).
    let head: ObjectID?
    /// The file's path in the worktree (the newest name; `--follow` walks back from it).
    let path: GitPath
    var follow = true

    /// The cache key: the graph's page cache does not apply here, because a file's history depends on the worktree's
    /// HEAD, not on every ref (#70).
    var key: Key { Key(worktree: worktree.path, head: head, path: path, follow: follow) }

    struct Key: Sendable, Hashable {
        let worktree: GitPath
        let head: ObjectID?
        let path: GitPath
        let follow: Bool
    }
}

/// One page, or why there is none (already escaped for display).
enum FileHistoryLoadResult: Sendable, Equatable {
    case page(LogParser.FileHistoryPage)
    case unavailable(String)
    case cancelled
}

/// Reads pages of a file's history (`fileHistory`, catalog §3).
protocol FileHistoryLoading: Sendable {
    /// The `limit` commits after the newest `skip`.
    func page(_ target: FileHistoryTarget, skip: Int, limit: Int) async -> FileHistoryLoadResult
}

/// The app's loader. `fileHistory` runs in the worktree (it needs the worktree's HEAD), which is checked again and its
/// configuration inspected first (`LiveWorktreeInspector.verifiedInspection`), as for diffs.
struct LiveFileHistoryLoader: FileHistoryLoading {
    let client: @Sendable () async throws -> GitClient

    static let live = LiveFileHistoryLoader(client: { try await LiveGitClient.shared.client() })

    /// Asks git for `skip + limit` commits and drops the first `skip`: `--skip` with `--follow` skips the wrong commits.
    /// Reading from the newest commit each time also keeps every commit's path right across renames.
    func page(_ target: FileHistoryTarget, skip: Int, limit: Int) async -> FileHistoryLoadResult {
        guard target.path.isRepresentable else {
            return .unavailable("This path is not valid UTF-8, so Overgrove cannot show its history.")
        }
        guard target.worktree.path.isRepresentable,
            let directory = PathValidator.canonical(
                URL(fileURLWithPath: target.worktree.path.display, isDirectory: true))
        else { return .unavailable("The worktree folder could not be found.") }
        do {
            let client = try await self.client()
            guard
                let inspection = try await LiveWorktreeInspector.verifiedInspection(
                    at: directory, of: target.repository, client: client)
            else { return .unavailable(LiveWorktreeInspector.noLongerMatches) }
            guard let safety = inspection.safetyContext else {
                return .unavailable(
                    "Overgrove stopped querying this worktree for safety. "
                        + PathValidator.displayable(inspection.report.blockingReason ?? ""))
            }
            let output = try await client.run(
                .fileHistory(path: target.path, follow: target.follow, limit: skip + limit), in: directory,
                safety: safety)
            let all = try LogParser.parseFileHistory(output.stdout, path: target.path, truncated: output.isTruncated)
            return .page(
                LogParser.FileHistoryPage(entries: Array(all.entries.dropFirst(skip)), isPartial: all.isPartial))
        } catch GitError.cancelled {
            return .cancelled
        } catch let error as GitError {
            return .unavailable(PathValidator.displayable(error.message))
        } catch is ParseError {
            return .unavailable("Overgrove could not read this file's history.")
        } catch {
            return .cancelled
        }
    }
}
