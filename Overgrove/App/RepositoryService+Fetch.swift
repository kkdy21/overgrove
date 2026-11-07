import Foundation

/// How one Fetch (every remote of a repository) ended (interaction.md §4.2, #77).
enum FetchRun: Sendable, Equatable {
    /// Every remote was tried; `failures` lists the ones that failed, empty when all succeeded.
    case finished(failures: [FetchFailureGuidance])
    /// The user stopped it. Remotes fetched before the stop keep their new refs.
    case cancelled
}

/// Fetch for the toolbar button and `⌘⇧R` (#77) on top of `GitClient.fetch` (#76).
extension RepositoryService {
    /// Fetches every remote of `repository`, one after another (`GitClient` runs one fetch per repository at a time
    /// anyway, and reports per remote; git-command-catalog.md §4).
    ///
    /// The configuration is inspected first, from the cache while its files are unchanged, so the fetch runs with
    /// the current neutralization, trusted credential helpers, and blocking reasons. A configuration that blocks
    /// queries fails every remote with its reason (fail closed). Failures become `FetchFailureGuidance`, which offers
    /// a git command only when the configuration report is clean (#200).
    ///
    /// - Parameter onStart: Called once with the remotes about to be fetched (for `Fetching origin…`).
    func fetch(_ repository: Repository, onStart: @Sendable ([String]) -> Void = { _ in }) async -> FetchRun {
        let context = makeContext(repository)
        let directory = repository.rootURL ?? repository.commonGitDirectoryURL
        let inspection: RepoConfigInspection
        do {
            inspection = try await Self.inspect(directory, probe: nil, context)
        } catch {
            return Self.isCancellation(error) ? .cancelled : .finished(failures: [Self.unreadable(error)])
        }
        let remotes = inspection.remotes
        guard !remotes.isEmpty else { return .finished(failures: [.noRemotes]) }
        onStart(remotes.map(\.name.value))
        // Stopped during the inspection: not a failure to report (security review of #77).
        if Task.isCancelled { return .cancelled }

        guard let safety = inspection.safetyContext else {
            let blocked = GitError.configInspectionFailed(reason: inspection.report.blockingReason ?? "")
            return .finished(failures: remotes.compactMap { Self.guidance(blocked, $0, inspection.report) })
        }
        var failures: [FetchFailureGuidance] = []
        for remote in remotes {
            if Task.isCancelled { return .cancelled }
            do {
                _ = try await context.client.fetch(.fetch(remote: remote.name), in: repository, safety: safety)
            } catch {
                if Self.isCancellation(error) { return .cancelled }
                let gitError = (error as? GitError) ?? .launchFailed(errno: -1)
                if let guidance = Self.guidance(gitError, remote, inspection.report) { failures.append(guidance) }
            }
        }
        return .finished(failures: failures)
    }

    private static func guidance(
        _ error: GitError, _ remote: RepoConfigInspection.Remote, _ report: RepoSecurityReport
    ) -> FetchFailureGuidance? {
        FetchFailureGuidance(
            error: error, remote: remote.name, endpoint: FetchFailureGuidance.Endpoint(remoteURL: remote.url),
            report: report)
    }

    private static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? GitError) == .cancelled
    }

    /// The configuration could not be read at all, so no remote is known: one failure without a remote.
    private static func unreadable(_ error: Error) -> FetchFailureGuidance {
        let gitError: GitError =
            switch error {
            case let error as GitError: error
            case let error as ParseError: GitError(error)
            default: .launchFailed(errno: -1)
            }
        return FetchFailureGuidance(configurationError: gitError)
    }
}
