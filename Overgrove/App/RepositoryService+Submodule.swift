import Darwin
import Foundation

/// Submodule state for the WIP detail (S-02, #108).
///
/// Each submodule is its own repository, with a configuration nobody inspected: the superproject's checks say nothing
/// about it, and `status` never recurses into it (`--ignore-submodules=dirty`, SEC-T1-02, SEC-T4-05). So a submodule
/// gets the same treatment as a worktree before anything runs inside it (catalog §3, "서브모듈 상태"):
/// 1. its path (from `.gitmodules` or the parent's status, both repository-controlled) stays inside the worktree with
///    no symbolic link on the way (`PathValidator.submoduleFolder`);
/// 2. its `.git` leads to this repository's `modules/` directory, or is a `.git` folder inside it
///    (`PathValidator.submoduleGitDirectory`);
/// 3. git agrees (`probeRepository`, allowed before inspection): that folder is the top level and that git directory
///    is the common directory;
/// 4. its own configuration is inspected (`configList`, then `RepoConfigInspector`), and `status` runs with that
///    submodule's own safety context. When the inspection blocks, nothing else runs.
/// Only the selected worktree's submodules are read, on demand, and at most `maximumInspectedSubmodules` of them
/// (T15). The submodules' configurations are not cached here; `SubmodulePanel` paces how often they are read again.
extension RepositoryService {
    /// Submodules inspected per request; the rest are counted (`SubmoduleListing.omitted`, SEC-T15-20).
    static let maximumInspectedSubmodules = 32
    /// Submodules inspected at the same time (each runs up to three git processes).
    static let concurrentSubmoduleInspections = 4
    /// `.gitmodules` paths kept from one read; past this the listing is partial and only counted as one more.
    static let maximumListedSubmodules = 4 * maximumInspectedSubmodules

    /// The submodules of `worktree`, or `nil` when it has no loaded status in the cache (as `lineCounts`).
    func submodules(of repository: Repository, worktree path: GitPath) async -> SubmoduleListing? {
        guard let entry = cachedOverview(of: repository)?.entries.first(where: { $0.worktree.path == path }),
            case .loaded(let state) = entry.status, path.isRepresentable,
            let listed = PathValidator.canonical(URL(fileURLWithPath: path.display, isDirectory: true))
        else { return nil }
        return await Self.submodules(of: entry.worktree, at: listed, state: state, makeContext(repository))
    }

    static func submodules(
        of worktree: Worktree, at listed: URL, state: WorkingState, _ context: Context
    ) async -> SubmoduleListing? {
        guard case .ready(let folder, let safety) = await prepare(worktree, at: listed, context),
            let worktreeGitDirectory = PathValidator.gitDirectory(of: folder)
        else { return nil }

        let (listedPaths, isPartial, isRefused) = await gitmodulesPaths(in: folder, safety: safety, context)
        let candidates = candidates(listed: listedPaths, state: state)
        let admitted = Array(candidates.prefix(maximumInspectedSubmodules))
        let omitted = candidates.count - admitted.count + (isPartial ? 1 : 0)
        let common = context.repository.commonGitDirectoryURL
        // A sliding window: one slow submodule holds one slot, not a whole batch.
        let results = await withTaskGroup(of: (Int, SubmoduleStatus).self) { group in
            func start(_ index: Int) {
                let (path, isListed) = admitted[index]
                group.addTask {
                    let state = await submoduleState(
                        path, in: folder, commonDirectory: common, worktreeGitDirectory: worktreeGitDirectory, context)
                    return (index, SubmoduleStatus(path: path, isListed: isListed, state: state))
                }
            }
            var next = 0
            while next < min(concurrentSubmoduleInspections, admitted.count) {
                start(next)
                next += 1
            }
            var collected: [(Int, SubmoduleStatus)] = []
            while let result = await group.next() {
                collected.append(result)
                if next < admitted.count, !Task.isCancelled {
                    start(next)
                    next += 1
                }
            }
            return collected.sorted { $0.0 < $1.0 }.map(\.1)
        }
        if Task.isCancelled { return nil }
        return SubmoduleListing(submodules: results, omitted: omitted, isGitmodulesRefused: isRefused)
    }

    /// Changed gitlinks from the parent's status first (with whether `.gitmodules` lists them), so one missing from
    /// `.gitmodules` still shows and made-up entries ahead of it there cannot push it past the cap; then the rest of
    /// `.gitmodules` in its order. Each path once.
    static func candidates(listed: [GitPath], state: WorkingState) -> [(GitPath, isListed: Bool)] {
        let listedSet = Set(listed)
        var seen = Set<GitPath>()
        let changed = (state.staged + state.unstaged + state.conflicted).filter(\.isSubmodule).map(\.path)
        return (changed + listed).filter { seen.insert($0).inserted }.map { ($0, listedSet.contains($0)) }
    }

    /// The paths `.gitmodules` lists. It is read only when it is a regular file inside the worktree: git would follow
    /// a symbolic link and read whatever it points to (SEC-T14-11).
    private static func gitmodulesPaths(
        in folder: URL, safety: RepoSafetyContext, _ context: Context
    ) async -> (paths: [GitPath], isPartial: Bool, isRefused: Bool) {
        let file = folder.appendingPathComponent(".gitmodules")
        var info = stat()
        guard lstat(file.path, &info) == 0 else { return ([], false, false) }
        guard info.st_mode & S_IFMT == S_IFREG else { return ([], false, true) }
        do {
            let output = try await context.client.run(.submodulePaths, in: folder, safety: safety)
            let listing = try SubmoduleListParser.parse(
                output.stdout, truncated: output.isTruncated, limit: maximumListedSubmodules)
            return (listing.paths, listing.isPartial, false)
        } catch {
            return ([], false, true)
        }
    }

    /// Steps 1–4 for one submodule.
    static func submoduleState(
        _ path: GitPath, in worktree: URL, commonDirectory: URL, worktreeGitDirectory: URL, _ context: Context
    ) async -> SubmoduleStatus.State {
        let folder: URL
        switch PathValidator.submoduleFolder(path, in: worktree) {
        case .folder(let found): folder = found
        case .missing: return .notCheckedOut
        case .invalid: return .notInspected(.invalidPath)
        case .symbolicLink: return .notInspected(.symbolicLink)
        }
        let gitDirectory: URL
        switch PathValidator.submoduleGitDirectory(
            of: folder, commonDirectory: commonDirectory, worktreeGitDirectory: worktreeGitDirectory)
        {
        case .inside(let found): gitDirectory = found
        case .notCheckedOut: return .notCheckedOut
        case .outside: return .notInspected(.outsideRepository)
        }
        do {
            let probeOutput = try await context.client.run(.probeRepository, in: folder, safety: .preInspection)
            guard let probe = try? ProbeParser.parse(probeOutput.stdout), isSameDirectory(probe.topLevel, folder),
                isSameDirectory(probe.commonDirectory, gitDirectory)
            else { return .notInspected(.outsideRepository) }

            let config = try await context.client.run(.configList, in: folder, safety: .preInspection)
            let inspection = RepoConfigInspector.inspect(
                try ConfigParser.parse(config.stdout, truncated: config.isTruncated))
            guard let safety = inspection.safetyContext else {
                return .notInspected(.blocked(reason: inspection.report.blockingReason ?? ""))
            }
            let output = try await context.client.run(.status, in: folder, safety: safety)
            let state = try StatusParser.parse(output.stdout, truncated: output.isTruncated)
            let files = Set((state.staged + state.unstaged + state.conflicted).map(\.path)).count
            if files == 0, state.untracked.isEmpty, !state.isPartial { return .clean }
            return .changed(files: files, untracked: state.untracked.count, isPartial: state.isPartial)
        } catch let error as GitError {
            return .failed(error)
        } catch let error as ParseError {
            return .failed(GitError(error))
        } catch {
            return .failed(.cancelled)
        }
    }
}
