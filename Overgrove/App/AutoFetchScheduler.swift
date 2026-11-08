import Foundation

/// Auto fetch (#79, S-08): fetches the window's repository every `AppSettings.autoFetchIntervalMinutes` while
/// `AppSettings.autoFetch` is on. Off by default.
///
/// Policy (interaction.md §4.2):
/// - Only while the window is active (key). Ticks while it is inactive, or while the app is in the background, are
///   skipped: nothing runs in the background.
/// - When the window becomes active again and the last fetch is at least one interval old, it fetches then, but at
///   most once per interval (a remote that keeps failing is not retried on every window switch).
/// - Never while a fetch runs (a manual one, or the previous auto fetch); never without an open repository.
/// - A failure shows in the status bar only: no alert, no notification, no announcement.
@MainActor
final class AutoFetchScheduler {
    private let settings: AppSettings
    private let fetch: FetchController
    private let sleep: @Sendable (Duration) async throws -> Void
    private let now: () -> Date
    private var loop: Task<Void, Never>?
    private var loopInterval: Int?
    private(set) var isWindowActive = false
    /// When auto fetch last started one for the open repository (ticks and catch-ups both count).
    private var lastAutomaticStart: Date?

    /// - Parameters:
    ///   - sleep: Waits one interval; tests pass a gate instead of real time.
    ///   - now: The clock for "at least one interval old".
    init(
        settings: AppSettings, fetch: FetchController,
        sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
        now: @escaping () -> Date = Date.init
    ) {
        self.settings = settings
        self.fetch = fetch
        self.sleep = sleep
        self.now = now
    }

    private var interval: Duration { .seconds(settings.autoFetchIntervalMinutes * 60) }
    private var intervalSeconds: TimeInterval { TimeInterval(settings.autoFetchIntervalMinutes * 60) }

    /// Starts, restarts, or stops the timer to match the settings. Call it when they change.
    func update() {
        guard settings.autoFetch else { return stop() }
        // Already ticking at this interval.
        if loop != nil, loopInterval == settings.autoFetchIntervalMinutes { return }
        loop?.cancel()
        loopInterval = settings.autoFetchIntervalMinutes
        let interval = interval
        let sleep = sleep
        loop = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(interval) } catch { return }
                // The window's state is gone (closed without `stop`): end instead of sleeping forever.
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
    }

    /// Another repository opened in the window (#479): the catch-up bound belongs to the repository it was fetched for,
    /// so the new one may catch up on the next activation if its last fetch is old enough.
    func repositoryChanged() {
        lastAutomaticStart = nil
    }

    /// The window was closed: no more auto fetches.
    func stop() {
        loop?.cancel()
        loop = nil
        loopInterval = nil
    }

    /// The window became key, or stopped being key.
    func windowActivityChanged(isActive: Bool) {
        isWindowActive = isActive
        guard isActive, settings.autoFetch else { return }
        let current = now()
        let lastFetched = fetch.status.lastFetched ?? .distantPast
        let lastAttempt = lastAutomaticStart ?? .distantPast
        guard current.timeIntervalSince(lastFetched) >= intervalSeconds,
            current.timeIntervalSince(lastAttempt) >= intervalSeconds
        else { return }
        start()
    }

    private func tick() {
        guard settings.autoFetch, isWindowActive else { return }
        start()
    }

    private func start() {
        guard fetch.canFetch, !fetch.status.isFetching else { return }
        lastAutomaticStart = now()
        fetch.fetchAutomatically()
    }
}
