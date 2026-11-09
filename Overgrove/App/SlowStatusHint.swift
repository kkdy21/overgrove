import Foundation

/// Explains a slow `git status` (#168). Overgrove never writes the index (`--no-optional-locks`, ADR-0011), so after a
/// formatter, generator, or build rewrites files outside git, every status re-hashes them until someone runs git in
/// Terminal. This only says so; it never refreshes the index itself.
struct SlowStatusHint: Equatable, Sendable {
    /// A status that took longer than this gets the hint (performance-budget.md PB-5 is 300 ms; 1 s leaves room for
    /// a busy machine, issue #168).
    static let threshold: Duration = .seconds(1)

    let duration: Duration
    /// `Status 5.2 s` for the status bar.
    let short: String
    let message: String
    /// `git status` to copy, offered only when the configuration report is clean **and** the repository has no hook
    /// executables: Terminal git runs the repository's settings, and refreshing the index runs its
    /// `post-index-change` hook, which the configuration report does not show (security reviews of #200, #168).
    let command: String?

    /// `nil` below the threshold or without a measurement.
    /// - Parameter isConfigurationClean: The report has no findings and the hooks folder was checked and has no
    ///   executables. Without that knowledge (no inspection yet) pass `false`.
    init?(duration: Duration?, isConfigurationClean: Bool) {
        guard let duration, duration > Self.threshold else { return nil }
        self.duration = duration
        let seconds = Self.seconds(duration)
        short = String(localized: "Status \(seconds) s")
        let cause = String(
            localized:
                "Status took \(seconds) s. If files were rewritten outside git (a formatter or a build), git re-reads them every time until its index is refreshed. Overgrove does not write the index."
        )
        if isConfigurationClean {
            message =
                cause + " "
                + String(
                    localized:
                        "Running \"git status\" once in Terminal refreshes it and makes this fast again. Terminal git also runs the repository's own hooks and settings, so do this only for a repository you trust."
                )
            command = "git status"
        } else {
            message =
                cause + " "
                + String(
                    localized:
                        "Overgrove does not suggest running git in Terminal for this repository: its configuration or hooks are not known to be safe."
                )
            command = nil
        }
    }

    /// `5.2`: one decimal place.
    static func seconds(_ duration: Duration) -> String {
        let value = Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
        return String(format: "%.1f", value)
    }

    /// The shortest gap before an automatic status refresh of a worktree whose last status took `duration`: ten
    /// times as long, at least 2 s, so a slow worktree is not re-hashed back to back (#168, for auto refresh #119).
    static func minimumRefreshInterval(after duration: Duration?) -> Duration {
        max(.seconds(2), (duration ?? .zero) * 10)
    }
}
