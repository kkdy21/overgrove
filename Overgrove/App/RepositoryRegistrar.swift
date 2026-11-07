import Foundation

/// Why a folder could not be added.
enum RegistrationError: Error, Equatable, Sendable {
    case invalidPath(PathValidator.Failure)
    /// The inside of a git directory: a `.git` folder, a subfolder of a bare repository, or a bare repository's
    /// administrative `worktrees/<id>` folder. The repository itself (or one of its worktrees) must be picked.
    case insideGitDirectory
    /// The probe's worktree and shared git directory do not match the folder on disk: `core.worktree` pointing
    /// elsewhere, or a `.git` file pointing into another repository (T14).
    case inconsistentRepository
    case git(GitError)

    var message: String {
        switch self {
        case .invalidPath(.notAbsolute), .invalidPath(.doesNotExist):
            "The folder could not be found."
        case .invalidPath(.notADirectory):
            "Choose a folder, not a file."
        case .invalidPath(.controlCharacters):
            "The folder's path contains control characters (such as a line break), so Overgrove will not add it."
        case .insideGitDirectory:
            "This folder is inside a Git directory. Choose the repository folder (for a bare repository, the folder "
                + "itself, such as repo.git) or one of its worktrees."
        case .inconsistentRepository:
            "This repository's Git settings point outside the folder you chose (for example core.worktree, or a .git "
                + "file that points into another repository), so Overgrove will not add it."
        case .git(let error):
            error.message
        }
    }
}

/// The result of checking a folder: the repository to register and, if it differs from what was picked, a note.
struct RepositoryRegistration: Equatable, Sendable {
    let entry: RegisteredRepository
    /// The folder the user picked.
    let chosenPath: String
    /// The picked path goes through a symbolic link (SEC-T14-01).
    let isThroughSymlink: Bool

    /// overview.md §9: tell the user when the registered path is not the one they picked (a symbolic link, a
    /// subfolder, or a linked worktree of the repository).
    var notice: String? {
        guard PathValidator.lexicallyNormalized(chosenPath) != entry.locationPath else { return nil }
        let reason = isThroughSymlink ? "The folder you chose is a symbolic link. " : ""
        return reason + "Overgrove added the repository at \(entry.displayRootPath)."
    }
}

/// The two registration probes (git-command-catalog.md §3, parsing-spec.md §11.2). Both run before inspection.
enum RegistrationProbe: Sendable, Equatable {
    /// `probeGitDirectory`: works everywhere, including bare repositories.
    case gitDirectory
    /// `probeRepository`: the worktree's top level. Only run inside a work tree.
    case worktree

    var command: ReadOnlyGitCommand {
        switch self {
        case .gitDirectory: .probeGitDirectory
        case .worktree: .probeRepository
        }
    }
}

/// Turns a folder the user picked into a registered repository (overview.md §3.2, §9; security-review.md T14).
///
/// Order: `PathValidator` (refuses control characters and missing folders before git runs), then the probes, the
/// only git commands here: `probeGitDirectory` in the picked folder; inside a work tree, `probeRepository` there;
/// for a linked worktree, `probeGitDirectory` again in the shared git directory to learn whether the repository is
/// bare (#222). Nothing else runs until `RepoConfigInspector` has inspected the repository when it is opened.
struct RepositoryRegistrar: Sendable {
    /// Runs a probe in the given (validated, resolved) folder and returns its stdout.
    typealias Probe = @Sendable (RegistrationProbe, URL) async throws -> Data

    private let probe: Probe

    init(probe: @escaping Probe) {
        self.probe = probe
    }

    func register(_ chosen: URL) async throws(RegistrationError) -> RepositoryRegistration {
        let checked: PathValidator.Registration
        do {
            checked = try PathValidator.checkRegistration(chosen)
        } catch let failure as PathValidator.Failure {
            throw .invalidPath(failure)
        } catch {
            throw .invalidPath(.doesNotExist)
        }

        let folder = checked.resolved
        let location = try await run(.gitDirectory, in: folder, parse: GitDirectoryProbeParser.parse)
        let entry: RegisteredRepository
        if location.isBare {
            entry = try Self.bareRepository(probe: location, chosen: folder)
        } else if location.isInsideWorkTree {
            entry = try await worktreeRepository(location: location, chosen: folder)
        } else if case .inside = PathValidator.containment(of: folder, in: location.gitDirectory) {
            throw .insideGitDirectory
        } else {
            // A repository whose work tree is configured elsewhere (`core.worktree`), SEC-T14-04.
            throw .inconsistentRepository
        }
        return RepositoryRegistration(entry: entry, chosenPath: chosen.path, isThroughSymlink: checked.isThroughSymlink)
    }

    // MARK: - Bare repositories (#222)

    /// SEC-T14-04 for a bare repository: the picked folder must be the shared git directory itself, or a folder
    /// whose `.git` entry leads to it on disk (a bare repository kept in `repo/.git` or `repo/.bare`). Its own git
    /// directory must be the shared one, so neither a subfolder nor an administrative `worktrees/<id>` folder (which
    /// git also reports as bare) is registered.
    private static func bareRepository(probe: GitDirectoryProbe, chosen: URL) throws(RegistrationError)
        -> RegisteredRepository
    {
        let common = probe.commonDirectory
        guard PathValidator.canonical(common)?.path == common.path else { throw .inconsistentRepository }
        // `worktrees/<id>`, or a folder whose `commondir` names another repository.
        guard PathValidator.canonical(probe.gitDirectory)?.path == common.path else { throw .insideGitDirectory }
        guard chosen.path == common.path || PathValidator.gitDirectory(of: chosen)?.path == common.path else {
            throw .insideGitDirectory
        }
        return RegisteredRepository(rootPath: nil, commonDirectoryPath: common.path)
    }

    /// Whether `common` is a bare repository's git directory, asked in that directory and checked to describe itself.
    private func isBareRepository(_ common: URL) async throws(RegistrationError) -> Bool {
        let probe = try await run(.gitDirectory, in: common, parse: GitDirectoryProbeParser.parse)
        return probe.isBare && probe.commonDirectory.path == common.path && probe.gitDirectory.path == common.path
    }

    // MARK: - Worktrees

    private func worktreeRepository(location: GitDirectoryProbe, chosen: URL) async throws(RegistrationError)
        -> RegisteredRepository
    {
        let result = try await run(.worktree, in: chosen, parse: ProbeParser.parse)
        // Both probes ran in the same folder; a repository that changes in between is not registered.
        guard !result.isBare, result.commonDirectory.path == location.commonDirectory.path else {
            throw .inconsistentRepository
        }
        let common = result.commonDirectory
        switch try Self.mainWorktree(probe: result, gitDirectory: location.gitDirectory, chosen: chosen) {
        case .main(let root):
            return RegisteredRepository(rootPath: root.path, commonDirectoryPath: common.path)
        case .linked(let standIn):
            if try await isBareRepository(common) {
                return RegisteredRepository(rootPath: nil, commonDirectoryPath: common.path)
            }
            let parent = common.deletingLastPathComponent()
            if common.lastPathComponent == ".git", PathValidator.gitDirectory(of: parent)?.path == common.path {
                return RegisteredRepository(rootPath: parent.path, commonDirectoryPath: common.path)
            }
            return RegisteredRepository(rootPath: standIn.path, commonDirectoryPath: common.path)
        }
    }

    private enum Worktree {
        /// The probed worktree's `.git` leads straight to the shared directory (main worktree, `--separate-git-dir`).
        case main(URL)
        /// A verified linked worktree; it stands in as the root if no main worktree is found.
        case linked(URL)
    }

    /// Checks the probe against the disk (security review of #84, T14).
    ///
    /// git's answers follow repository files (`core.worktree`, `.git` files, `commondir`), so they are not trusted
    /// on their own. The picked folder must lie inside the reported worktree, that worktree's `.git` must lead to the
    /// git directory the first probe reported, and that must be the shared git directory either directly (main
    /// worktree, `--separate-git-dir`) or as a linked worktree whose administrative entry points back to it.
    private static func mainWorktree(probe: RepositoryProbe, gitDirectory: URL, chosen: URL) throws(RegistrationError)
        -> Worktree
    {
        let topLevel = probe.topLevel
        let common = probe.commonDirectory
        guard PathValidator.canonical(topLevel)?.path == topLevel.path,
            PathValidator.canonical(common)?.path == common.path,
            case .inside = PathValidator.containment(of: chosen, in: topLevel),
            let ownGitDirectory = PathValidator.gitDirectory(of: topLevel),
            ownGitDirectory.path == PathValidator.canonical(gitDirectory)?.path
        else { throw .inconsistentRepository }

        if ownGitDirectory.path == common.path {
            return .main(topLevel)
        }
        guard case .linked = PathValidator.checkLinkedWorktree(root: topLevel, commonGitDirectory: common) else {
            throw .inconsistentRepository
        }
        return .linked(topLevel)
    }

    // MARK: - Running probes

    private func run<T>(
        _ kind: RegistrationProbe,
        in folder: URL,
        parse: (Data) throws -> T
    ) async throws(RegistrationError) -> T {
        do {
            return try parse(try await probe(kind, folder))
        } catch let error as GitError {
            throw Self.classify(error)
        } catch let error as ParseError {
            throw .git(.parseFailed(parser: error.parser, offset: error.offset))
        } catch is CancellationError {
            throw .git(.cancelled)
        } catch {
            // GitClient throws only GitError; anything else means git could not be run.
            throw .git(.launchFailed(errno: -1))
        }
    }

    /// `--show-toplevel` says "this operation must be run in a work tree" outside one. The first probe rules that
    /// out, so this only happens if the folder changed between the probes.
    private static func classify(_ error: GitError) -> RegistrationError {
        if case .nonZeroExit(_, let detail) = error, detail.text.lowercased().contains("must be run in a work tree") {
            return .insideGitDirectory
        }
        return .git(error)
    }
}

extension RepositoryRegistrar {
    /// The app's registrar: the probes go through `GitClient` with `.preInspection`.
    static let live = RepositoryRegistrar(probe: { kind, folder in
        try await LiveGitClient.shared.client()
            .run(kind.command, in: folder, safety: .preInspection).stdout
    })
}

/// One `GitClient` for the app, created on first use (`GitEnvironment.discover` runs `git version`).
actor LiveGitClient {
    static let shared = LiveGitClient()

    private var cached: GitClient?

    func client() async throws -> GitClient {
        if let cached { return cached }
        let client = GitClient(environment: try await GitEnvironment.discover())
        cached = client
        return client
    }
}
