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
    /// The git chosen in Settings (ADR-0019, #106); absent or empty means the default git. Read off the main actor by
    /// `LiveGitClient`, which checks it on every discovery.
    nonisolated static let gitExecutablePathKey = "settings.gitExecutablePath"
    static let graphZoomStepKey = "settings.graphZoomStep"
    static let showsGraphStashesKey = "settings.showsGraphStashes"

    /// The auto fetch section is shown (the scheduler exists since #79).
    static let isAutoFetchAvailable = true
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

    /// The git chosen in Settings, as entered; `nil` for the default git. Saved only after it passed ADR-0019's
    /// checks (`GitExecutableChoice`). A stored value is untrusted and is checked again on every discovery.
    var gitExecutablePath: String? {
        didSet {
            if let gitExecutablePath, !gitExecutablePath.isEmpty {
                defaults.set(gitExecutablePath, forKey: Self.gitExecutablePathKey)
            } else {
                defaults.removeObject(forKey: Self.gitExecutablePathKey)
            }
        }
    }

    /// The graph zoom step (#121, `GraphZoom.scales`), one for every window. A stored value outside the steps falls
    /// back to the nearest one.
    var graphZoomStep: Int {
        didSet {
            let step = GraphZoom(step: graphZoomStep).step
            guard step == graphZoomStep else {
                graphZoomStep = step
                return
            }
            defaults.set(graphZoomStep, forKey: Self.graphZoomStepKey)
        }
    }

    var graphZoom: GraphZoom { GraphZoom(step: graphZoomStep) }

    /// Stashes drawn in the graph above their base commits (#384); on by default, one value for every window.
    var showsGraphStashes: Bool {
        didSet { defaults.set(showsGraphStashes, forKey: Self.showsGraphStashesKey) }
    }

    /// View › Zoom In `⌘+`, Zoom Out `⌘−`, Actual Size `⌘0`.
    func zoomGraphIn() { graphZoomStep = graphZoom.zoomedIn.step }
    func zoomGraphOut() { graphZoomStep = graphZoom.zoomedOut.step }
    func resetGraphZoom() { graphZoomStep = GraphZoom.actualSizeStep }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoFetch = defaults.bool(forKey: Self.autoFetchKey)
        let interval = defaults.integer(forKey: Self.autoFetchIntervalKey)
        autoFetchIntervalMinutes =
            Self.autoFetchIntervals.contains(interval) ? interval : Self.defaultAutoFetchInterval
        showsFullRemoteURLs = defaults.bool(forKey: Self.showsFullRemoteURLsKey)
        gitExecutablePath = defaults.string(forKey: Self.gitExecutablePathKey).flatMap { $0.isEmpty ? nil : $0 }
        showsGraphStashes =
            defaults.object(forKey: Self.showsGraphStashesKey) == nil
            ? true : defaults.bool(forKey: Self.showsGraphStashesKey)
        graphZoomStep =
            defaults.object(forKey: Self.graphZoomStepKey) == nil
            ? GraphZoom.actualSizeStep : GraphZoom(step: defaults.integer(forKey: Self.graphZoomStepKey)).step
    }
}
