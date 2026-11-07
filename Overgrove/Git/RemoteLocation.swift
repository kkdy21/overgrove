import Foundation

/// Where a remote URL points, by git's own rule (#107).
enum RemoteLocation {
    /// Whether fetching `url` runs git on this Mac in another repository: a local path or a `file://` URL. Follows
    /// git's `url_is_local_not_ssh`: a URL without `://` is local unless it reads as `host:path` (a colon with no slash
    /// before it). Remote helpers (`name::address`) and other schemes are not local. `FILE://` counts as local too,
    /// which only refuses more in untrusted mode.
    static func isLocal(_ url: String) -> Bool {
        guard !url.isEmpty else { return false }
        if let scheme = url.range(of: "://") {
            return url[..<scheme.lowerBound].lowercased() == "file"
        }
        guard let colon = url.firstIndex(of: ":") else { return true }
        if let slash = url.firstIndex(of: "/"), slash < colon { return true }
        return false
    }
}
