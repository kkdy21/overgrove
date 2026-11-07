import Foundation
import Observation

/// The app's preferences (S-08, #86), kept in `UserDefaults` (overview.md §8). Only options are stored: no tokens,
/// passwords, or remote URLs.
@MainActor
@Observable
final class AppSettings {
    static let autoFetchKey = "settings.autoFetch"
    static let autoFetchIntervalKey = "settings.autoFetchIntervalMinutes"
    static let showsFullRemoteURLsKey = "settings.showsFullRemoteURLs"

    /// The auto fetch section appears once the scheduler exists (#79); the setting is stored already.
    static let isAutoFetchAvailable = false
    /// Minutes offered for the auto fetch interval (S-08: default 10).
    static let autoFetchIntervals = [5, 10, 15, 30, 60]
    static let defaultAutoFetchInterval = 10

    @ObservationIgnored private let defaults: UserDefaults

    /// Fetch in the background every `autoFetchIntervalMinutes` (S-08: off by default).
    var autoFetch: Bool {
        didSet { defaults.set(autoFetch, forKey: Self.autoFetchKey) }
    }

    var autoFetchIntervalMinutes: Int {
        didSet {
            // Only the offered values; anything else (an edited preference file) falls back to the default.
            guard Self.autoFetchIntervals.contains(autoFetchIntervalMinutes) else {
                autoFetchIntervalMinutes = Self.defaultAutoFetchInterval
                return
            }
            defaults.set(autoFetchIntervalMinutes, forKey: Self.autoFetchIntervalKey)
        }
    }

    /// Show whole remote URLs instead of host and path. Credentials stay masked either way (T11).
    var showsFullRemoteURLs: Bool {
        didSet { defaults.set(showsFullRemoteURLs, forKey: Self.showsFullRemoteURLsKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoFetch = defaults.bool(forKey: Self.autoFetchKey)
        let interval = defaults.integer(forKey: Self.autoFetchIntervalKey)
        autoFetchIntervalMinutes =
            Self.autoFetchIntervals.contains(interval) ? interval : Self.defaultAutoFetchInterval
        showsFullRemoteURLs = defaults.bool(forKey: Self.showsFullRemoteURLsKey)
    }
}
