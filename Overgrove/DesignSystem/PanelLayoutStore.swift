import CryptoKit
import Foundation

/// Remembers each repository's panel widths and collapse state (#174) and its graph column widths and visibility
/// (#255, interaction.md §2.1).
///
/// Keys are a digest of `Repository.id` (the shared git directory path), so repository paths do not appear in the
/// preferences file's key list. Values are JSON; anything unreadable falls back to the default layout, and stored
/// widths are clamped to the current limits on load.
struct PanelLayoutStore: @unchecked Sendable {
    // `UserDefaults` is documented as thread-safe; it is not marked `Sendable` in the SDK.

    static let keyPrefix = "panelLayout."
    static let columnsKeyPrefix = "graphColumns."

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func key(for repositoryID: String, prefix: String = Self.keyPrefix) -> String {
        let digest = SHA256.hash(data: Data(repositoryID.utf8))
        return prefix + digest.map { String(format: "%02x", $0) }.joined()
    }

    func layout(for repositoryID: String) -> PanelLayout {
        guard let data = defaults.data(forKey: key(for: repositoryID)),
            let layout = try? JSONDecoder().decode(PanelLayout.self, from: data)
        else { return .default }
        return layout.sanitized()
    }

    func save(_ layout: PanelLayout, for repositoryID: String) {
        guard let data = try? JSONEncoder().encode(layout) else { return }
        defaults.set(data, forKey: key(for: repositoryID))
    }

    /// The graph's columns; anything unreadable gives the default columns.
    func columns(for repositoryID: String) -> GraphColumnLayout {
        guard let data = defaults.data(forKey: key(for: repositoryID, prefix: Self.columnsKeyPrefix)),
            let columns = try? JSONDecoder().decode(GraphColumnLayout.self, from: data)
        else { return .default }
        return columns
    }

    func save(_ columns: GraphColumnLayout, for repositoryID: String) {
        guard let data = try? JSONEncoder().encode(columns) else { return }
        defaults.set(data, forKey: key(for: repositoryID, prefix: Self.columnsKeyPrefix))
    }
}
