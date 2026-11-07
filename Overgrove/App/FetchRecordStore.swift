import Foundation

/// The last fetch of each repository, kept in `UserDefaults` (overview.md §8, G5, #77): the last attempt and the last
/// success, so a failed attempt can still say when the repository was last fetched. Only times, the outcome, and the
/// app-written summary are stored (it may name the validated remote name and host, never credentials); never a URL
/// or stderr.
final class FetchRecordStore: @unchecked Sendable {
    struct Entry: Equatable, Sendable {
        let last: FetchRecord
        /// When a fetch last succeeded; `nil` if none has.
        let lastSucceededAt: Date?
    }

    private let defaults: UserDefaults
    private let lock = NSLock()

    static let key = "io.github.kkdy21.overgrove.fetchRecords"
    /// Summaries come from `FetchFailureGuidance.summary` (app-written, a validated remote name at most); longer text
    /// is not expected and is cut.
    static let maximumSummaryLength = 200

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func entry(for repositoryID: String) -> Entry? {
        lock.withLock { load()[repositoryID] }.flatMap { $0.entry(repositoryID: repositoryID) }
    }

    /// Stores `record` as the repository's last attempt; a success also becomes its last success.
    func save(_ record: FetchRecord) {
        lock.withLock {
            var all = load()
            let previous = all[record.repositoryID]
            all[record.repositoryID] = Stored(
                finishedAt: record.finishedAt,
                succeeded: record.succeeded,
                summary: record.summary.map { String($0.prefix(Self.maximumSummaryLength)) },
                lastSucceededAt: record.succeeded ? record.finishedAt : previous?.lastSucceededAt)
            store(all)
        }
    }

    /// Forgets a repository removed from Overgrove.
    func remove(_ repositoryID: String) {
        lock.withLock {
            var all = load()
            guard all.removeValue(forKey: repositoryID) != nil else { return }
            store(all)
        }
    }

    // MARK: Storage

    private struct Stored: Codable {
        let finishedAt: Date
        let succeeded: Bool
        let summary: String?
        let lastSucceededAt: Date?

        func entry(repositoryID: String) -> Entry {
            Entry(
                last: FetchRecord(
                    repositoryID: repositoryID, finishedAt: finishedAt, succeeded: succeeded, summary: summary),
                lastSucceededAt: lastSucceededAt)
        }
    }

    /// Unreadable data (an older or edited format) is treated as no records rather than failing.
    private func load() -> [String: Stored] {
        guard let data = defaults.data(forKey: Self.key) else { return [:] }
        return (try? JSONDecoder().decode([String: Stored].self, from: data)) ?? [:]
    }

    private func store(_ all: [String: Stored]) {
        guard let data = try? JSONEncoder().encode(all) else { return }
        defaults.set(data, forKey: Self.key)
    }
}

extension FetchRecordStore {
    /// `<common dir>/FETCH_HEAD`'s modification time, standing in for a fetch Overgrove has no record of (overview.md
    /// §8, §9: one of the two files read directly). Only a regular file counts; a symbolic link is not followed
    /// (`attributesOfItem` describes the link itself). The repository controls this time, so it is shown as an
    /// estimate only.
    static func estimatedLastFetch(commonDirectory: URL) -> Date? {
        let path = commonDirectory.appendingPathComponent("FETCH_HEAD").path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
            attributes[.type] as? FileAttributeType == .typeRegular
        else { return nil }
        return attributes[.modificationDate] as? Date
    }

    /// What the status bar shows for a repository before any fetch in this window.
    func status(for repository: Repository) -> FetchStatus {
        if let entry = entry(for: repository.id) {
            if entry.last.succeeded { return .idle(lastFetched: entry.last.finishedAt) }
            return .failed(lastFetched: entry.lastSucceededAt)
        }
        if let estimate = Self.estimatedLastFetch(commonDirectory: repository.commonGitDirectoryURL) {
            return .estimated(lastFetched: estimate)
        }
        return .never
    }
}
