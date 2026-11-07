import Foundation
import Observation

/// A repository the user added. Only paths are stored (overview.md §8): no bookmarks, remote URLs, or credentials.
struct RegisteredRepository: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// The main worktree, where repository-wide commands run. `nil` for a bare repository (#222), whose
    /// repository-wide commands run in `commonDirectoryPath` and worktree commands in its linked worktrees.
    let rootPath: String?
    /// The shared git directory. Worktrees of one repository share it, so it is the identity.
    let commonDirectoryPath: String

    var id: String { repository.id }
    var isBare: Bool { rootPath == nil }
    /// The folder that stands for the repository: the main worktree, or the bare repository's git directory.
    var locationPath: String { rootPath ?? commonDirectoryPath }
    /// The folder name, safe to show (`PathValidator.displayable`).
    var name: String { PathValidator.displayable((locationPath as NSString).lastPathComponent) }
    /// `locationPath`, safe to show.
    var displayRootPath: String { PathValidator.displayable(locationPath) }

    var repository: Repository {
        Repository(
            rootURL: rootPath.map { URL(fileURLWithPath: $0, isDirectory: true) },
            commonGitDirectoryURL: URL(fileURLWithPath: commonDirectoryPath, isDirectory: true),
            isBare: isBare)
    }

    /// Stored values are untrusted (another process can write the defaults): absolute paths without control
    /// characters only.
    var isWellFormed: Bool {
        [rootPath, commonDirectoryPath].compactMap { $0 }
            .allSatisfy { $0.hasPrefix("/") && !PathValidator.containsControlCharacters($0) }
    }
}

/// The registered repositories, shared by every window, in the order they were added.
@MainActor
@Observable
final class RepositoryRegistry {
    static let repositoriesKey = "registeredRepositories"
    static let lastSelectedKey = "lastSelectedRepository"

    private let defaults: UserDefaults
    private(set) var repositories: [RegisteredRepository]

    /// The repository shown last, opened again at launch.
    var lastSelected: RegisteredRepository.ID? {
        didSet { defaults.set(lastSelected, forKey: Self.lastSelectedKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        repositories = Self.load(from: defaults)
        let selected = defaults.string(forKey: Self.lastSelectedKey)
        lastSelected = repositories.contains { $0.id == selected } ? selected : nil
    }

    func repository(withID id: RegisteredRepository.ID) -> RegisteredRepository? {
        repositories.first { $0.id == id }
    }

    enum AddResult: Equatable {
        case added
        /// A repository with the same shared git directory is already registered.
        case alreadyRegistered
        /// Not an absolute path, or contains control characters.
        case rejected
    }

    /// Adds `entry` unless a repository with the same shared git directory is already registered.
    @discardableResult
    func add(_ entry: RegisteredRepository) -> AddResult {
        guard entry.isWellFormed else { return .rejected }
        guard repository(withID: entry.id) == nil else { return .alreadyRegistered }
        repositories = repositories + [entry]
        save()
        return .added
    }

    /// Forgets a repository. Its folder is not touched.
    func remove(_ id: RegisteredRepository.ID) {
        repositories = repositories.filter { $0.id != id }
        if lastSelected == id { lastSelected = nil }
        save()
    }

    private func save() {
        // Encoding an array of two-string structs cannot fail.
        if let data = try? JSONEncoder().encode(repositories) {
            defaults.set(data, forKey: Self.repositoriesKey)
        }
    }

    /// Corrupt data loads as empty; malformed or duplicate entries are skipped.
    private static func load(from defaults: UserDefaults) -> [RegisteredRepository] {
        guard let data = defaults.data(forKey: repositoriesKey),
            let stored = try? JSONDecoder().decode([RegisteredRepository].self, from: data)
        else { return [] }
        var seen = Set<RegisteredRepository.ID>()
        return stored.filter { $0.isWellFormed && seen.insert($0.id).inserted }
    }
}
