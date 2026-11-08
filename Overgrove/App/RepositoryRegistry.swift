import Foundation
import Observation

/// A repository the user added. Only paths and the untrusted flag are stored (overview.md §8): no bookmarks, remote
/// URLs, or credentials.
struct RegisteredRepository: Codable, Equatable, Hashable, Identifiable, Sendable {
    /// The main worktree, where repository-wide commands run. `nil` for a bare repository (#222), whose
    /// repository-wide commands run in `commonDirectoryPath` and worktree commands in its linked worktrees.
    let rootPath: String?
    /// The shared git directory. Worktrees of one repository share it, so it is the identity.
    let commonDirectoryPath: String
    /// Untrusted mode (#107, ADR-0009): no fetch from a remote on this Mac, and Open in Terminal always asks first.
    /// Off by default.
    var isUntrusted: Bool

    init(rootPath: String?, commonDirectoryPath: String, isUntrusted: Bool = false) {
        self.rootPath = rootPath
        self.commonDirectoryPath = commonDirectoryPath
        self.isUntrusted = isUntrusted
    }

    private enum CodingKeys: String, CodingKey {
        case rootPath, commonDirectoryPath, isUntrusted
    }

    /// Entries saved before #107 have no flag and read as trusted. A flag that is present but not a boolean reads as
    /// untrusted: stored values are untrusted, and the entry still loads.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        rootPath = try container.decodeIfPresent(String.self, forKey: .rootPath)
        commonDirectoryPath = try container.decode(String.self, forKey: .commonDirectoryPath)
        if container.contains(.isUntrusted) {
            isUntrusted = (try? container.decode(Bool.self, forKey: .isUntrusted)) ?? true
        } else {
            isUntrusted = false
        }
    }

    /// Paths, plus the flag only when set: a trusted entry stays exactly as before #107 (overview.md §8).
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(rootPath, forKey: .rootPath)
        try container.encode(commonDirectoryPath, forKey: .commonDirectoryPath)
        if isUntrusted { try container.encode(true, forKey: .isUntrusted) }
    }

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
    nonisolated static let repositoriesKey = "registeredRepositories"
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

    /// Marks a repository untrusted, or trusted again (#107).
    func setUntrusted(_ isUntrusted: Bool, for id: RegisteredRepository.ID) {
        guard let index = repositories.firstIndex(where: { $0.id == id }),
            repositories[index].isUntrusted != isUntrusted
        else { return }
        repositories[index].isUntrusted = isUntrusted
        save()
    }

    /// Forgets a repository. Its folder is not touched.
    func remove(_ id: RegisteredRepository.ID) {
        repositories = repositories.filter { $0.id != id }
        if lastSelected == id { lastSelected = nil }
        save()
    }

    private func save() {
        // Encoding an array of path strings and a flag cannot fail.
        if let data = try? JSONEncoder().encode(repositories) {
            defaults.set(data, forKey: Self.repositoriesKey)
        }
    }

    /// Corrupt data loads as empty; malformed or duplicate entries are skipped. Also read off the main actor, for the
    /// directories a chosen git may not be inside (ADR-0019, `LiveGitClient`).
    nonisolated static func load(from defaults: UserDefaults) -> [RegisteredRepository] {
        // Each entry decodes on its own, so one damaged entry drops only itself, not the others and their flags
        // (#107).
        guard let data = defaults.data(forKey: repositoriesKey),
            let entries = try? JSONDecoder().decode([Lossy<RegisteredRepository>].self, from: data)
        else { return [] }
        let stored = entries.compactMap(\.value)
        var seen = Set<RegisteredRepository.ID>()
        return stored.filter { $0.isWellFormed && seen.insert($0.id).inserted }
    }
}

/// An array element that decodes to `nil` instead of failing the whole array.
private struct Lossy<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}
