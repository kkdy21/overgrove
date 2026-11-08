import Foundation

/// How one Fetch (every remote of a repository) ended (interaction.md §4.2, #77).
enum FetchRun: Sendable, Equatable {
    /// The remotes were tried; `failures` lists the ones that failed, empty when all succeeded. `remoteLimit` is set
    /// when configured remotes past `maximumFetchedRemotes` were skipped (#259).
    case finished(failures: [FetchFailureGuidance], remoteLimit: FetchRemoteLimit? = nil)
    /// The user stopped it. Remotes fetched before the stop keep their new refs.
    case cancelled
}

/// Fetch for the toolbar button and `⌘⇧R` (#77) on top of `GitClient.fetch` (#76).
extension RepositoryService {
    /// Fetches the remotes of `repository` (the first `maximumFetchedRemotes`), one after another (`GitClient` runs one fetch per repository at a time
    /// anyway, and reports per remote; git-command-catalog.md §4).
    ///
    /// The configuration is inspected first, from the cache while its files are unchanged, so the fetch runs with
    /// the current neutralization, trusted credential helpers, and blocking reasons. A configuration that blocks
    /// queries fails every remote with its reason (fail closed). Failures become `FetchFailureGuidance`, which offers
    /// a git command only when the configuration report is clean (#200).
    ///
    /// An untrusted repository (#107, ADR-0009) runs no git for a local path or `file://` remote: it is reported as
    /// turned off. Its other remotes fetch with a transport list without `file`, so a remote that only becomes local
    /// through configuration (`insteadOf`) is refused by git and reported the same way.
    ///
    /// - Parameters:
    ///   - untrusted: The repository is marked untrusted (the registry's flag). No default, so a caller that forgets
    ///     it does not fetch as trusted by accident (as `allowsTransport`, #215).
    ///   - onStart: Called once with the remotes about to be fetched (for `Fetching origin…`).
    func fetch(
        _ repository: Repository, untrusted: Bool, onStart: @Sendable ([String]) -> Void = { _ in }
    ) async -> FetchRun {
        let context = makeContext(repository)
        let directory = repository.rootURL ?? repository.commonGitDirectoryURL
        let inspection: RepoConfigInspection
        do {
            inspection = try await Self.inspect(directory, probe: nil, context)
        } catch {
            return Self.isCancellation(error) ? .cancelled : .finished(failures: [Self.unreadable(error)])
        }
        guard !inspection.remotes.isEmpty else { return .finished(failures: [.noRemotes]) }
        // The first remotes in configuration order, at most `maximumFetchedRemotes` (#259, T15).
        let remotes = Array(inspection.remotes.prefix(maximumFetchedRemotes))
        let limit =
            remotes.count < inspection.remotes.count
            ? FetchRemoteLimit(fetched: remotes.count, total: inspection.remotes.count) : nil
        onStart(remotes.map(\.name.value))
        // Stopped during the inspection: not a failure to report (security review of #77).
        if Task.isCancelled { return .cancelled }

        // Hooks Terminal git would run: read once, and only when a failure needs guidance (#354).
        var hookExecutables: [String]?
        func hooks() -> [String] {
            if let hookExecutables { return hookExecutables }
            let found = LiveWorktreeInspector.hookExecutables(in: repository.commonGitDirectoryURL)
            hookExecutables = found
            return found
        }

        guard var safety = inspection.safetyContext else {
            let blocked = GitError.configInspectionFailed(reason: inspection.report.blockingReason ?? "")
            return .finished(
                failures: remotes.compactMap { Self.guidance(blocked, $0, inspection.report, hooks: hooks()) },
                remoteLimit: limit)
        }
        safety.blocksLocalTransport = untrusted
        var failures: [FetchFailureGuidance] = []
        for remote in remotes {
            if Task.isCancelled { return .cancelled }
            if untrusted && RemoteLocation.isLocal(remote.url) {
                failures.append(Self.untrustedLocalRemote(remote, inspection.report))
                continue
            }
            do {
                _ = try await context.client.fetch(.fetch(remote: remote.name), in: repository, safety: safety)
            } catch {
                if Self.isCancellation(error) { return .cancelled }
                let gitError = (error as? GitError) ?? .launchFailed(errno: -1)
                if untrusted, case .transportNotAllowed("file", _) = gitError {
                    failures.append(Self.untrustedLocalRemote(remote, inspection.report))
                } else if let guidance = Self.guidance(gitError, remote, inspection.report, hooks: hooks()) {
                    failures.append(guidance)
                }
            }
        }
        return .finished(failures: failures, remoteLimit: limit)
    }

    private static func guidance(
        _ error: GitError, _ remote: RepoConfigInspection.Remote, _ report: RepoSecurityReport, hooks: [String]
    ) -> FetchFailureGuidance? {
        FetchFailureGuidance(
            error: error, remote: remote.name, endpoint: FetchFailureGuidance.Endpoint(remoteURL: remote.url),
            report: report, hookExecutables: hooks)
    }

    /// Overgrove's own text: the remote is on this Mac and the repository is untrusted. No command is offered.
    static let untrustedLocalReason =
        "This repository is marked untrusted, so Overgrove does not fetch remotes on this Mac (local paths and "
        + "file:// URLs): fetching runs git in the other repository with its own settings. Mark the repository "
        + "trusted to fetch them."

    private static func untrustedLocalRemote(
        _ remote: RepoConfigInspection.Remote, _ report: RepoSecurityReport
    ) -> FetchFailureGuidance {
        // `configInspectionFailed` never offers a command, so the hooks do not matter here.
        guidance(.configInspectionFailed(reason: untrustedLocalReason), remote, report, hooks: [])
            ?? FetchFailureGuidance(configurationError: .configInspectionFailed(reason: untrustedLocalReason))
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
