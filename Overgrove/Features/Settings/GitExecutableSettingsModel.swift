import Foundation
import Observation

/// What Settings shows about the git in use (screens.md S-08, ADR-0019).
struct GitExecutableReport: Equatable, Sendable {
    /// The path chosen in Settings as entered; `nil` for the default git.
    let entered: String?
    /// The real file that runs.
    let resolvedPath: String
    let version: GitVersion
    /// Shown only; never required (ADR-0019 §2).
    let isAppleSigned: Bool

    /// Below `lazyFetchControlVersion`, partial clones cannot be fetched (#317). Backported releases compare lower
    /// too, which errs on the safe side.
    var canFetchPartialClones: Bool { version >= GitEnvironment.lazyFetchControlVersion }
}

enum GitExecutableState: Equatable, Sendable {
    case checking
    case ready(GitExecutableReport)
    /// The stored choice fails ADR-0019's rules; queries are stopped until it is fixed (fail closed).
    case rejected(path: String, reason: String)
    /// Discovery failed for another reason (for example, no developer tools for the default git).
    case failed(String)
}

/// The Settings › Advanced git executable row (#106).
///
/// A choice is saved only after `resolve` accepted it (ADR-0019 §4). Saving resets the shared client so the next
/// command uses the new git; commands already running finish with the old one.
@MainActor
@Observable
final class GitExecutableSettingsModel {
    typealias Resolve =
        @Sendable (_ chosenPath: String?, _ protectedDirectories: @escaping @Sendable () -> [URL]) async throws
        -> GitEnvironment

    private(set) var state: GitExecutableState = .checking
    /// Why the last Choose… was not saved; cleared by the next refresh or choice.
    private(set) var choiceError: String?
    private(set) var isWorking = false

    @ObservationIgnored private let settings: AppSettings
    /// The registered repositories, read on the main actor; their directories are worked out off it, and only for a
    /// chosen git.
    @ObservationIgnored private let repositories: @MainActor () -> [RegisteredRepository]
    @ObservationIgnored private let resolve: Resolve
    @ObservationIgnored private let isAppleSigned: @Sendable (URL) -> Bool
    @ObservationIgnored private let resetSharedClient: @Sendable () async -> Void

    init(
        settings: AppSettings,
        repositories: @escaping @MainActor () -> [RegisteredRepository],
        resolve: @escaping Resolve = { path, protected in
            try await GitEnvironment.resolve(chosenPath: path, protectedDirectories: protected)
        },
        isAppleSigned: @escaping @Sendable (URL) -> Bool = GitExecutablePolicy.isAppleSigned,
        resetSharedClient: @escaping @Sendable () async -> Void = GitExecutableSettingsModel.resetLiveClient
    ) {
        self.settings = settings
        self.repositories = repositories
        self.resolve = resolve
        self.isAppleSigned = isAppleSigned
        self.resetSharedClient = resetSharedClient
    }

    /// The app's model: registered repositories (and their worktrees) are protected.
    convenience init(settings: AppSettings, registry: RepositoryRegistry) {
        self.init(settings: settings, repositories: { registry.repositories })
    }

    var isDefault: Bool { settings.gitExecutablePath == nil }

    /// Drops the app's shared client so the next command discovers git again.
    nonisolated private static func resetLiveClient() async {
        await LiveGitClient.shared.reset()
    }

    /// Checks the stored choice (or the default) again, as every discovery does. A stored choice that now fails also
    /// drops the shared client, so queries really stop as the screen says (ADR-0019 §4).
    func refresh() async {
        choiceError = nil
        state = await evaluate(settings.gitExecutablePath)
        switch state {
        case .rejected: await resetSharedClient()
        case .failed where !isDefault: await resetSharedClient()
        default: break
        }
    }

    /// Choose…: saves `path` only if it passes. The `/usr/bin/git` shim stands for the default.
    func choose(path: String) async {
        isWorking = true
        defer { isWorking = false }
        choiceError = nil
        if GitExecutablePolicy.isShim(path) {
            await useDefault()
            return
        }
        let checked = await evaluate(path)
        switch checked {
        case .ready:
            settings.gitExecutablePath = path
            await resetSharedClient()
            state = checked
        case .rejected(_, let reason):
            choiceError = reason
        case .failed(let message):
            choiceError = message
        case .checking:
            break
        }
    }

    /// Use Default: forgets the choice and checks the default git.
    func useDefault() async {
        settings.gitExecutablePath = nil
        await resetSharedClient()
        await refresh()
    }

    private func evaluate(_ path: String?) async -> GitExecutableState {
        let snapshot = repositories()
        do {
            let environment = try await resolve(path) { GitExecutablePolicy.protectedDirectories(for: snapshot) }
            let signed = isAppleSigned
            let isSigned = await Task.detached { signed(environment.executable) }.value
            return .ready(
                GitExecutableReport(
                    entered: path, resolvedPath: environment.executable.path, version: environment.version,
                    isAppleSigned: isSigned))
        } catch GitError.chosenExecutableRejected(let shown, let reason) {
            return .rejected(path: shown, reason: reason)
        } catch let error as GitError {
            return .failed(error.message)
        } catch {
            return .failed("Overgrove could not run git.")
        }
    }
}
