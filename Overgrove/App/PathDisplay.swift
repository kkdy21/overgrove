import Foundation

/// How a file system path is shown: the home folder as `~` (information-architecture.md §4.4, #713).
///
/// The one place that shortens the home folder, so the sidebar, the detail panel, S-07, the registration notices, the
/// alerts, the repository menu, and Settings show a path the same way. Display only: stored paths, git arguments, and
/// `Copy Path` stay absolute. Escape the result with `PathValidator.displayable` before showing it.
enum PathDisplay {
    /// `/Users/user/dev/api` → `~/dev/api`, the home folder itself → `~`, anything else unchanged.
    ///
    /// `/Users/username/x` stays whole for the home `/Users/user`: only whole path components match. An empty or `/`
    /// home shortens nothing, or every path would read `~/…`.
    static func abbreviated(_ path: String, home: String = NSHomeDirectory()) -> String {
        let home = home.count > 1 && home.hasSuffix("/") ? String(home.dropLast()) : home
        guard home.count > 1 else { return path }
        if path == home { return "~" }
        let prefix = home + "/"
        return path.hasPrefix(prefix) ? "~/" + path.dropFirst(prefix.count) : path
    }
}
