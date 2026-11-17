import Foundation

/// Relative times outside the fetch wording (#686). The status bar's and S-05's `Fetched 2 d ago`
/// (`StatusBarItem.relative`, interaction.md §4.2) never rounds up past days, so lists of old refs do not use it.
enum RelativeTime {
    /// `now`, `5m`, `2h`, `3d`, `4w`, `5mo`, `2y`: the graph's Date column (screens.md S-01), and the TAGS and REMOTE
    /// rows (information-architecture.md §4.5).
    static func compact(_ date: Date, now: Date) -> String {
        GraphCommitText.compact(date, now: now)
    }

    /// `just now`, `5m ago`, `3d ago`, `2y ago`: S-04's head and the issue detail's `updated 3h ago` (screens.md S-04,
    /// S-06).
    static func ago(_ date: Date, now: Date) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return String(localized: "just now") }
        return String(
            localized: "\(compact(date, now: now)) ago", comment: "A short relative time (3d, 2h, 5mo) before now")
    }

    /// `3 days ago`, `3 years ago` for VoiceOver (interaction.md §6), in the app's language.
    /// - Parameter locale: The language to speak; the app's own (`Bundle.main.preferredLocalizations`) if `nil`.
    static func spoken(_ date: Date, now: Date, locale: Locale? = nil) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return String(localized: "just now") }
        let formatter = locale.map(Self.formatter(for:)) ?? appFormatter
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private static func formatter(for locale: Locale) -> RelativeDateTimeFormatter {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = locale
        formatter.unitsStyle = .full
        return formatter
    }

    /// The UI's language rather than the system's, so a label is never half in another language. Dates that are read
    /// out or shown in words use it too (`GraphRowAccessibility.hint`, #710).
    static let appLocale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")

    nonisolated(unsafe) private static let appFormatter = formatter(for: appLocale)
}
