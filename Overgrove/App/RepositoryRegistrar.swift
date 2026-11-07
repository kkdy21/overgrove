import Foundation

/// Why a folder could not be added.
enum RegistrationError: Error, Equatable, Sendable {
    case invalidPath(PathValidator.Failure)
    /// Bare repositories, and the inside of a `.git` directory, have no worktree to probe (the probe's
    /// `--show-toplevel` fails there).
    case bareRepository
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
        case .bareRepository:
            "This folder is a bare repository or the inside of a .git folder. Choose a worktree folder instead."
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
        guard PathValidator.lexicallyNormalized(chosenPath) != entry.rootPath else { return nil }
        let reason = isThroughSymlink ? "The folder you chose is a symbolic link. " : ""
        return reason + "Overgrove added the repository at \(entry.displayRootPath)."
    }
}

/// Turns a folder the user picked into a registered repository (overview.md §3.2, §9; security-review.md T14).
///
/// Order: `PathValidator` (refuses control characters and missing folders before git runs), then the probe
/// `rev-parse --show-toplevel --git-common-dir --is-bare-repository`, the only git command here. Nothing else runs
/// until `RepoConfigInspector` has inspected the repository when it is opened.
struct RepositoryRegistrar: Sendable {
    /// Runs the probe in the given (validated, resolved) folder and returns its stdout.
    typealias Probe = @Sendable (URL) async throws -> Data

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

        let result: RepositoryProbe
        do {
            result = try ProbeParser.parse(try await probe(checked.resolved))
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
        guard !result.isBare else { throw .bareRepository }

        let common = result.commonDirectory
        let root = try Self.mainWorktree(probe: result, chosen: checked.resolved)
        return RepositoryRegistration(
            entry: RegisteredRepository(rootPath: root.path, commonDirectoryPath: common.path),
            chosenPath: chosen.path,
            isThroughSymlink: checked.isThroughSymlink)
    }

    /// The folder to register, after checking the probe against the disk (security review of #84, T14).
    ///
    /// git's answers follow repository files (`core.worktree`, `.git` files, `commondir`), so they are not trusted
    /// on their own. The picked folder must lie inside the reported worktree, and that worktree's `.git` must lead
    /// to the reported shared git directory, either directly (main worktree, `--separate-git-dir`) or as a linked
    /// worktree whose administrative entry points back to it. A linked worktree registers its main worktree when
    /// that is the parent of a `.git` directory leading to the same place; otherwise the linked worktree stands in.
    private static func mainWorktree(probe: RepositoryProbe, chosen: URL) throws(RegistrationError) -> URL {
        let topLevel = probe.topLevel
        let common = probe.commonDirectory
        guard PathValidator.canonical(topLevel)?.path == topLevel.path,
            PathValidator.canonical(common)?.path == common.path,
            case .inside = PathValidator.containment(of: chosen, in: topLevel)
        else { throw .inconsistentRepository }

        if PathValidator.gitDirectory(of: topLevel)?.path == common.path {
            return topLevel
        }
        guard case .linked = PathValidator.checkLinkedWorktree(root: topLevel, commonGitDirectory: common) else {
            throw .inconsistentRepository
        }
        let parent = common.deletingLastPathComponent()
        if common.lastPathComponent == ".git", PathValidator.gitDirectory(of: parent)?.path == common.path {
            return parent
        }
        return topLevel
    }

    /// git says "this operation must be run in a work tree" for `--show-toplevel` in a bare repository or inside
    /// a `.git` directory.
    private static func classify(_ error: GitError) -> RegistrationError {
        if case .nonZeroExit(_, let detail) = error, detail.text.lowercased().contains("must be run in a work tree") {
            return .bareRepository
        }
        return .git(error)
    }
}

extension RepositoryRegistrar {
    /// The app's registrar: the probe goes through `GitClient` with `.preInspection`.
    static let live = RepositoryRegistrar(probe: { folder in
        try await LiveGitClient.shared.client()
            .run(.probeRepository, in: folder, safety: .preInspection).stdout
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
